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
(up to 300 seconds per host), then runs Ansible ping on every VM. Empty/partial inventory, partial host selection, unavailable SSH
or missing Python fail the check. No services or packages are installed.
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
cluster, including test writes to percona.example. Deploy includes verification.
Both operations run tofu init for the existing S3 backend and prepare-inventory.yml
from named outputs, then connect through the bastion. They never run infrastructure
plan/apply/destroy, nor install/reconfigure monitoring. Spaces credentials, SSH
identity/public-key Variable and PXC_ROOT_PASSWORD are required; DigitalOcean
API and Grafana credentials are not passed. Empty/missing outputs fail before
remote actions. Both workflows share concurrency group tassadar-production.
Recovery and the outage test remain separate manual playbooks.

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
- installs `percona-release` and enables the `pxc80` repository;
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
the other two nodes form a healthy two-node Primary component:

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

CI/CD can run the same deployment and recovery playbooks. The outage scenario
in `pxc-test-recovery.yml` is a separate, explicitly enabled test for a dedicated
test cluster; it deliberately stops MySQL and should not run on every deployment.

There is no local simulated regression suite. Negative cases such as missing
replica rows, Non-Primary status, and unreachable Galera ports are enforced by
the Ansible tasks but are not covered by separate automated regression tests.
