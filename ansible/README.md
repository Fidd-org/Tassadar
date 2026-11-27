# Ansible playbooks

- [connectivity/](playbooks/connectivity/) generates inventory and checks SSH connectivity.
- [monitoring/](playbooks/monitoring/) installs and verifies Node Exporter, Prometheus and Grafana.
- [pxc/](playbooks/pxc/) deploys and verifies PXC and contains the recovery playbooks.

## Controller inventory

Before deployment, verification, or recovery, initialize the OpenTofu backend
and run from `ansible/`:

```bash
ansible-playbook -i localhost, playbooks/connectivity/prepare-inventory.yml \
  -e inventory_ssh_private_key_path="$HOME/.ssh/id_tassadar" \
  -e inventory_known_hosts_path="$HOME/.ssh/known_hosts"
```

The local-only playbook reads selected outputs from state and creates
`inventory.yml` and `.generated/ssh_config` for this controller. It does not
run plan/apply. Supply a private key with mode 0600 (or stricter) and verified
known_hosts entries for the bastion public IP and all managed private IPs.
SSH checks host keys on both hops and keeps private keys on the controller.

Both hops use the `ansible` account created by OpenTofu cloud-init. Remote service
playbooks escalate with `become: true`; direct root SSH is disabled. The current
account has `NOPASSWD:ALL` sudo for provisioning, not a restricted command list.
Temporary modules and SSH control sockets use the current user's `~/.ansible/`
directories rather than shared fixed paths in `/tmp`.

Existing root-only VMs are not migrated by generating a new inventory. Changing
Droplet user data requires VM replacement; review the infrastructure plan and
preserve the PXC data volumes. Do not bypass this by enabling root SSH fallback.

The local default is inventory_host_key_checking=yes with pinned keys.
CI explicitly sets inventory_host_key_checking=accept-new and uses a fresh,
empty controller file; SSH learns the first key automatically. Changed keys
are rejected while that file exists. Trust does not persist across runners.
There is no ANSIBLE_KNOWN_HOSTS GitHub Secret. For the same local policy,
supply -e inventory_host_key_checking=accept-new and an existing writable
known_hosts file; its entries remain usable between local runs.
Only yes and accept-new are allowed; unchecked no/off modes are rejected.

Required outputs are `bastion_public_ip`, `bastion_private_ip`,
`pxc_private_ips`, `flowerca_private_ip`, and `monitoring_private_ips`. Apply the monitoring
infrastructure before regenerating inventory from an older state. The
monitoring map must contain exactly `prometheus-1` and `grafana-1`; verified
host keys are required for both private IPs. The resulting groups are
`prometheus` and `grafana` under `monitoring`. Both use the same
ProxyJump configuration as PXC. Node Exporter, Prometheus and Grafana playbooks are
covered in [monitoring.md](monitoring.md).

Run this before each Ansible operation on a fresh GitHub runner, and again
after a Droplet replacement and verification of the replacement's host key.
An empty or invalid state cannot supply inventory. See the root
[configuration instructions](../README.md#configuration) for backend credentials.
After switching from the formerly hard-coded AWS profile, select a local
profile with `AWS_PROFILE=tassadar-spaces` and run `tofu init -reconfigure`;
CI can instead use standard AWS environment credentials.

The former Terraform-generated `inventory.ini` is no longer selected by
default. On the next approved apply, a `removed` block forgets the old
`local_file.ansible_inventory` state entry without deleting the old local file.
The default inventory is now `inventory.yml`.

# Connectivity check

After preparing the complete inventory, run:

```bash
ansible-playbook playbooks/connectivity/check-connectivity.yml
```

It requires all seven expected hosts and role groups, waits for SSH/Python
(up to 300 seconds per host), then verifies Ansible ping, the `ansible` login,
noninteractive sudo and the key-only SSH/root-login policy on every VM, including
`Match` rules for `ansible` and `root` at the actual connection addresses.
Empty/partial inventory, partial host selection, unavailable SSH, missing Python
or invalid sudo/SSH policy fail the check. No services or packages are installed.
GitHub Actions exposes the same check operation with controller-only temporary
keys and inventory; the current CI version is pinned in requirements.txt.
Infrastructure apply runs the same check before mandatory monitoring deployment.
Manage PXC instead checks SSH/Python only on the three PXC nodes through the
bastion; it does not require the monitoring VMs to be reachable.
A separate check run is optional diagnostics. The local-only
check-monitoring-credentials.yml reuses Grafana password validation before
cloud changes. See [monitoring deployment](monitoring.md#github-deployment).
Local fixtures validate inventory/Ansible behaviour, not real SSH reachability.

# PXC from GitHub

Run Manage infrastructure / apply first for resources and monitoring, then
Manage PXC / deploy for the database. Manage PXC / verify checks an existing
cluster, including test writes to percona.example. Deploy always includes
verification. With test_recovery enabled (off by default), a successful fresh
deploy also randomly selects one of the three nodes and runs pxc-test-recovery.yml:
it stops MySQL, checks writes through both survivors, recovers the node and
verifies the test records on all three nodes. A failed test fails the deploy.
A repeated deploy classified as healthy skips the outage test, even if enabled.
Both operations run tofu init for the existing S3 backend and prepare-inventory.yml
from named outputs, then connect through the bastion. They never run infrastructure
plan/apply/destroy, nor install/reconfigure monitoring. Spaces credentials, SSH
identity/public-key Variable and PXC_ROOT_PASSWORD are required; DigitalOcean
API and Grafana credentials are not passed. Empty/missing outputs fail before
remote actions. Both workflows share concurrency group tassadar-production.
Manage PXC also provides manual recover and test-recovery operations for an explicitly selected node.

# playbooks/pxc/pxc.yml

This playbook installs and configures a three-node Percona XtraDB Cluster. It
expects the inventory group `pxc` to contain exactly `pxc-1`, `pxc-2`, and
`pxc-3`.

The complete playbook validates inputs, probes all nodes, installs/bootstrap
only for three empty new volumes, then runs shared health/replication checks.
A healthy existing cluster skips installation and bootstrap. Mixed, stopped,
wrong-password or ambiguous states fail before package/service changes.

`pxc_preflight` checks the expected ext4 block devices and mount identity.
Unmounted clean filesystems are inspected through temporary `ro,noload`
mounts, then unmounted before their temporary directories are removed.
Existing data and nonempty `lost+found` are never classified as fresh.
Partial or full-cluster recovery is a separate operation.


## Role `pxc`

The preparation role performs the same installation and configuration steps on
all three nodes:

- validates Ubuntu, the inventory host names, and the generated root password;
- waits until `cloud-init` has finished;
- installs the packages required by the official Percona apt repository;
- verifies a versioned `percona-release` DEB against its pinned SHA256 in a root-owned cache, then enables the `pxc80` repository;
- waits for the dedicated data device at `/dev/disk/by-id/scsi-0DO_Volume_<node>-data`;
- formats the device as `ext4` only when it does not already contain a
  filesystem;
- persists the stable by-id mount in `/etc/fstab`;
- preserves existing mount-point ownership during recovery;
- preseeds the MySQL root password for non-interactive package installation;
- installs the `percona-xtradb-cluster` package directly onto the mounted data
  disk without automatically starting MySQL;
- ensures the mounted MySQL data directory belongs to `mysql` after installation;
- calculates `server_id` from the inventory name (`pxc-1` becomes `1`);
- renders `/etc/mysql/mysql.conf.d/mysqld.cnf` from
  `roles/pxc/templates/pxc.cnf.j2`.

DigitalOcean may initially mount an empty volume at `/mnt/pxc_N_data`.
Preflight inspects that known location without changing it. Only after all
three nodes qualify as fresh does installation recheck emptiness and disable
that volume's provider mount unit, then mount it at `/var/lib/mysql` through
fstab. Unknown mounts, existing data or competing fstab entries stop deployment.
The provider unit is retained disabled; the volume is not reformatted.

The disk is mounted before the Percona package is installed, so MySQL creates
its data directory on the dedicated disk from the beginning. There is no
datadir migration or copy step. A disk with an unexpected filesystem causes
the role to fail instead of formatting it.

The rendered configuration contains the Galera provider, cluster name and
address, node name and private address, strict mode, SST method, and the MySQL
settings required by PXC. `wsrep_cluster_address` is built automatically from
the private `ansible_host` values of every host in the `pxc` group.

## Role `pxc_cluster`

The cluster role orchestrates the nodes in a strict order:

1. Starts `mysql@bootstrap.service` only on `pxc-1`.
2. Waits until `pxc-1` reports a one-node `Primary` cluster in the `Synced`
   state with `wsrep_connected=ON` and `wsrep_ready=ON`.
3. Reads the default PXC TLS files from `pxc-1` and copies them to each joining
   node.
4. Starts regular `mysql` on `pxc-2` and verifies a healthy two-node cluster.
5. Starts regular `mysql` on `pxc-3` and verifies a healthy three-node
   cluster.
The final play uses the shared `pxc_verify` role to check health, a common
cluster UUID, and write/read replication across all three nodes.

The orchestration tasks use `run_once` with `delegate_to`. Ansible still opens
each SSH connection from the local control machine through the bastion; the PXC
nodes do not connect to each other over SSH.

## Variables

Shared defaults are defined in `roles/pxc_config/defaults/main.yml` and loaded
explicitly by each PXC playbook. Inventory/group_vars/host_vars and extra-vars
can override them; play-level vars_files no longer overwrite node settings.
Cluster variables include:

- `pxc_repo` selects the Percona repository (`pxc80` by default);
- `pxc_cluster_name` sets the wsrep cluster name;
- `pxc_provider` points to the Galera provider library;
- `pxc_sst_method` selects the state snapshot transfer method;
- `pxc_mysql_datadir` points to the MySQL data directory;
- `pxc_data_device` and `pxc_data_filesystem` control the dedicated
  data-disk mount;
- `pxc_tls_files` and `pxc_tls_private_files` describe the TLS files copied
  from the bootstrap node;
- `pxc_cluster_address` is generated from all PXC private IP addresses;
- `pxc_root_password` resolves the protected runtime password or local override.

CI sets `PXC_ROOT_PASSWORD` only for credential validation, deployment and
verification, with `pxc_require_runtime_password=true`. This requires at
least 20 characters and never generates a fallback password file. It is not
passed in argv or stored in inventory/state. No password reset is performed.

PXC passwords must not contain single quotes or backslashes, which the
Percona package initializer cannot safely handle. Validation fails before
cloud changes in CI and before invoking the installer during recovery.

Local runs accept `PXC_ROOT_PASSWORD` or `pxc_root_password_override` from
protected Ansible variables. Without either, the existing local password file
is reused/generated; overrides do not evaluate that lookup. Local passwords
retain the existing 12-character minimum. Credentials must have no CR/LF or
leading/trailing whitespace. Playbooks explicitly load shared PXC variables
even when inventory is outside the repository.


## Tags and verification

Use the complete playbook for deployment. For a healthy running cluster:

```bash
ansible-playbook playbooks/pxc/pxc.yml --tags verify
# Or:
ansible-playbook playbooks/pxc/pxc-verify.yml
```

Partial `install`/`cluster` runs, `--skip-tags`, `--limit` and
`--check` are rejected by deployment preflight. They could bypass the
classification or verification needed for safe deployment. The standalone
verification playbook checks credentials/host selection and shared SQL checks.

The verifier writes only the dedicated `percona.example` test table.
It does not test database recovery or automatically restart an unhealthy cluster.
After an interrupted initial install/bootstrap, inspect the state before choosing
a recovery procedure; this version does not auto-resume a partial bootstrap.

## Recover one PXC node

Use the dedicated recovery playbook only when exactly one PXC node is down and
the other two nodes form a healthy two-node Primary component. The complete
playbook also restores monitoring after the join: Node Exporter on the target,
MySQL Exporter on PXC, refreshed host/MySQL targets in Prometheus and the current
PXC dashboard. Supply PXC_ROOT_PASSWORD, MYSQL_EXPORTER_PASSWORD and
GRAFANA_ADMIN_PASSWORD, and include the monitoring hosts in inventory.
Inventory/credential format checks run on the controller before recovery changes;
failed input validation stops subsequent plays.

```bash
ansible-playbook playbooks/pxc/pxc-recover-node.yml \
  -e pxc_recovery_node=pxc-3 \
  -e pxc_recovery_allow_sst=true
```

Optionally select either healthy survivor as the TLS source:

```bash
ansible-playbook playbooks/pxc/pxc-recover-node.yml \
  -e pxc_recovery_node=pxc-3 \
  -e pxc_recovery_donor=pxc-2 \
  -e pxc_recovery_allow_sst=true
```

The explicit SST acknowledgement is required because a joining node may need
a full State Snapshot Transfer, which replaces its local MySQL data. The role
uses IST automatically when Galera can obtain all missing writes from a
survivor's cache.

The recovery node must already be reachable over SSH. If the Droplet itself is
lost, use OpenTofu first to replace that Droplet, reattach its data volume, and
regenerate `inventory.yml`. Do not use this playbook for a full-cluster outage;
that procedure must select a safe bootstrap node from Galera recovery state.

For example, inspect the replacement plan before applying it:

```bash
cd ../tofu
tofu plan -replace='digitalocean_droplet.pxc["pxc-3"]'
tofu apply -replace='digitalocean_droplet.pxc["pxc-3"]'
```

The plan must replace the selected Droplet and its attachment without replacing
the corresponding `digitalocean_volume.pxc_data` resource. After apply,
verify the replacement host key, return to `ansible/`, prepare inventory,
and run the recovery playbook with the same node name.

Project-level run commands, connectivity checks, and basic MySQL commands are
documented in the root `README.md`.

## Recovery verification

Recovery checks TCP port 4567 on both survivors from the target node before
preparing it, and runs the shared `pxc_verify` health and write/read checks after
joining. The TCP check does not cover reverse traffic, UDP, or the SST/IST ports;
those transfers are validated by the real synchronization step. Shared
verification resets only the dedicated `percona.example` test table.
The complete recovery playbook then verifies monitoring with targets regenerated
from inventory; it does not finish successfully if exporter/Prometheus/dashboard
verification fails. The pxc_recover_node role alone remains responsible for DB
recovery, as used by the outage test on an already installed cluster.

## Test a node outage and recovery

On an already installed, healthy, dedicated test cluster, run from `ansible/`:

```bash
ansible-playbook playbooks/pxc/pxc-test-recovery.yml \
  -e pxc_recovery_node=pxc-3 \
  -e pxc_test_allow_node_stop=true \
  -e pxc_recovery_allow_sst=true
```

This test deliberately stops MySQL on the selected node. It requires explicit
acknowledgement before any database writes or service changes. It:

1. verifies the original three-node cluster;
2. writes a unique baseline record from the selected node and verifies it on
   both survivors;
3. stops both possible MySQL services on that node;
4. waits for a healthy two-node component, writes one record on each survivor,
   and verifies both writes while the selected node is still down;
5. invokes the production recovery role's preflight and orchestration;
6. verifies the baseline and outage records on every node, including the
   recovered node.

The test uses `percona.recovery_probe`, separate from `percona.example`, so
recovery's ordinary replication check cannot erase the outage evidence. Records
are isolated by a random run ID. Final verification attempts to delete only
that run's records, including when the final read check fails. Earlier failures
can leave those test records in place for diagnosis.

An `always` block attempts recovery even if the outage write/read check fails.
If recovery itself fails its safety or connectivity checks, fix that problem
and run `pxc-recover-node.yml` manually; the test cannot guarantee restoration
through a network failure. Do not interrupt the test while the node is down.
Run one such test at a time.

The test reuses the production recovery role on an already prepared node; it
does not exercise the recovery playbook's package installation or disk mount
step. It simulates MySQL unavailability with a controlled service stop, not a
hard crash, network partition, or Droplet loss. It does not force IST or SST;
coverage of both transfer paths requires separate real-cluster runs.

## Automation

Deployment and recovery automatically run the shared `pxc_verify` health and
replication checks. No separate local test command is required.

Manage PXC / deploy runs `pxc-test-recovery.yml` after a successful fresh
deployment only when **test_recovery** is enabled (off by default). This checkbox
authorizes the test on one randomly selected PXC node, including a MySQL stop
and possible SST. The selected node is recorded before the test in the workflow
log and Summary, including when the test fails. The manual recovery checkboxes
are not needed for this fresh-deployment test. Repeat deploys of a healthy
cluster skip it even when enabled. The workflow Summary reports the requested
option and test outcome separately from installation; an unchecked test is
skipped and does not affect deploy success.
If the fresh-deployment test fails, inspect the cluster and rerun test-recovery
explicitly: a later deploy of a healthy cluster does not repeat the outage test.

The workflow job limit is 180 minutes. It records a deadline at job startup,
with five minutes reserved for final reporting, and checks for at least 75
minutes remaining before either recovery invocation. An exhausted budget fails
before this operation stops MySQL. This avoids consuming recovery time in a
slow deploy; cancellation or runner failure still requires manual inspection.

Running `playbooks/pxc/pxc.yml` directly does not trigger the outage test.
The standalone test and its acknowledgement flags remain available for later
checks on a dedicated test cluster.

There is no local simulated regression suite. Negative cases such as missing
replica rows, Non-Primary status, and unreachable Galera ports are enforced by
the Ansible tasks but are not covered by separate automated regression tests.

## Recovery from GitHub Actions

In **Manage PXC**, choose **recover** to rejoin one unavailable member, or
**test-recovery** to stop MySQL on one node and test writes during its outage.
Select **recovery_node** and acknowledge **allow_sst**. The test also requires
**allow_node_stop** and is intended for a dedicated test cluster.

The test first verifies all three nodes, writes a baseline, stops the selected
MySQL service, writes through both survivors and runs the recovery role.
It then requires all three nodes to read the baseline and outage records.
The role checks that both survivors are ready, synced members of the same
two-node Primary component before it changes the target.

## Local package-security regression

From `ansible/`, with the pinned Ansible version installed:

```bash
sudo "$(command -v ansible-playbook)" -i localhost, tests/pxc-release.yml
```

This uses local root privileges to test ownership checks on isolated temporary
text files. It installs no packages, connects to no cloud hosts, and removes its
fixtures afterwards. Cases cover a valid download, unchanged repeat, corrupt
cache repair, an installation path outside the cache, checksum mismatch,
attacker-owned files and package/cache symlinks or writable directories. Negative
cases must fail at the expected guard with the expected reason; an unrelated
download error must fail the test instead of counting as checksum protection.
