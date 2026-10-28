# Node Exporter, Prometheus and Grafana

Infrastructure is defined in ../tofu/. These playbooks install services only;
they do not create Droplets, register GitHub jobs, bootstrap PXC, or install
MySQL Exporter.

## Run

Apply the infrastructure first, verify its SSH host keys, and prepare inventory
as described in [README.md](README.md#controller-inventory). From ansible/:

```bash
ansible-playbook playbooks/node-exporter.yml
ansible-playbook playbooks/prometheus.yml
```

The first playbook installs Node Exporter on all seven managed VMs, including
bastion, FlowerCA and both monitoring VMs. It does not need a running database.
The second installs Prometheus on the single prometheus inventory host and
fails unless every expected exporter is UP and host metrics are queryable.

Recheck without installing or restarting services:

```bash
ansible-playbook playbooks/prometheus-verify.yml
```

Use the complete generated inventory. A deployment limited to one exporter
does not remove the other expected scrape targets. After replacing a VM,
verify its new SSH key, regenerate inventory, install its exporter, and rerun
the Prometheus playbook to update scrape addresses.

## Inventory and private access

The node_exporter inventory group includes bastion, pxc, flowerca and monitoring.
Targets use inventory names as the instance label, so addresses can change
without renaming the monitored node.

SSH reaches bastion through its public IP. Its separate node_exporter_address
comes from the bastion_private_ip OpenTofu output. All other exporters default
to ansible_host, which is already a private IP. The generator reads five named
outputs and validates the extra bastion address without requiring a second
known_hosts entry for it: SSH still connects to the public address.

Both roles require Ubuntu 24.04 amd64, systemd and an assigned RFC1918 bind IP.
Node Exporter listens on that address at 9100; Prometheus listens on its
private IP at 9090. Sources are restricted by the existing Cloud Firewalls.
Traffic currently uses HTTP within the VPC; no public endpoint is configured.
Prometheus admin and HTTP lifecycle APIs remain disabled.

Once installed, open the Prometheus UI through the generated SSH configuration:

```bash
ssh -F .generated/ssh_config -N -o ExitOnForwardFailure=yes \
  -L 127.0.0.1:9090:<prometheus-private-ip>:9090 tassadar-bastion
```

Replace the placeholder with monitoring_private_ips["prometheus-1"] and open
http://127.0.0.1:9090 while the tunnel runs.

## Installation and updates

| Component | Pinned version | Configuration |
| --- | --- | --- |
| Node Exporter | 1.12.1 | roles/node_exporter/defaults/main.yml |
| Prometheus | 3.15.0 | roles/prometheus/defaults/main.yml |
| Grafana OSS | 13.2.4 | roles/grafana/defaults/main.yml |

Official linux-amd64 archives are verified against fixed SHA-256 values before
extraction. An update requires reviewing both the version and checksum; runs
do not follow latest automatically. Sources:
[Node Exporter releases](https://github.com/prometheus/node_exporter/releases),
[Prometheus releases](https://github.com/prometheus/prometheus/releases).

Roles wait for cloud-init, install ca-certificates/tar, and run services as
separate non-login system users. Binaries are root-owned in /usr/local/bin;
services cannot rewrite them. Node Exporter does not remount host data
filesystems read-only in a service namespace, which could distort filesystem
metrics; it remains an unprivileged user with no capabilities. systemd restarts
are notified only by changed binaries, units or configuration. A stopped service is started on a repeated
run; changed Prometheus config is validated by promtool before replacement.
No MySQL credentials are needed for this stage.

Prometheus data is in /var/lib/prometheus, preserved across playbook reruns.
Defaults: 15-second scrapes, 10-second timeout, 7-day time retention and 5 GB
block retention. Size retention is not a hard limit on the entire directory:
WAL/head data also needs space. The unit sets a 1 GiB Go soft memory limit.
VM sizing, backup and retention adjustments remain operational decisions.
Full infrastructure destroy deletes the monitoring root disks and their data.

Override scrape/retention settings in Ansible variables; invalid configuration
is rejected by promtool. A cold-install --check run is not a substitute for
deployment verification: downloaded binaries and promtool are not installed
during check mode.

## Verification and limits

Each exporter is checked locally for HTTP 200 and real host metrics.
Prometheus verification uses its /-/ready, /api/v1/targets and /api/v1/query:
the exact expected node inventory set must be present, every target including
Prometheus itself must be UP, and node_uname_info must be stored for every node.
Retries allow the first scrape to complete. prometheus_verify_retries and
prometheus_verify_delay tune the default 30 attempts / 5-second delay.

This verifies Prometheus-to-exporter scraping after a real deployment. It does
not test Grafana-to-Prometheus access or the SSH tunnel from an operator.
Local component checks use temporary processes on loopback; they do not prove
cloud firewall reachability, service installation, systemd sandbox execution,
or repeated-run idempotence on Ubuntu Droplets.

The next database step is a dedicated MySQL Exporter on every PXC node plus
a least-privilege database account, after PXC is healthy. Database dashboards,
notifications and GitHub service workflows remain separate tasks.

## Grafana

After Node Exporter and Prometheus, install Grafana on its own VM:

```bash
read -r -s -p "Grafana admin password: " GRAFANA_ADMIN_PASSWORD
export GRAFANA_ADMIN_PASSWORD
ansible-playbook playbooks/grafana.yml
unset GRAFANA_ADMIN_PASSWORD
```

Use a strong password of at least 20 characters, without leading/trailing
whitespace or line breaks. The role also accepts grafana_admin_password from
a protected Ansible variable (for example, an encrypted extra-vars file).
Do not put a literal password in a shell command, inventory or committed file.
Future CI must supply GRAFANA_ADMIN_PASSWORD from GitHub Secrets only to the
needed Ansible step. No GitHub service workflow is implemented yet.

The Grafana role installs pinned Grafana OSS 13.2.4 with SHA-256 verification,
creates an unprivileged service user, and configures systemd. The archive URL,
version and checksum are pinned together in roles/grafana/defaults/main.yml.

Grafana listens only on its private IP at port 3000. Open its UI using:

```bash
ssh -F .generated/ssh_config -N -o ExitOnForwardFailure=yes \
  -L 127.0.0.1:3000:<grafana-private-ip>:3000 tassadar-bastion
```

Replace the placeholder with monitoring_private_ips["grafana-1"], open
http://localhost:3000 and log in as admin with the supplied password.
Anonymous access and self-registration are disabled. The HTTP URL is for the
existing SSH tunnel; a public TLS endpoint is outside this configuration.

Provisioning installs Prometheus as the default, managed datasource with UID
tassadar-prometheus. Its private address comes from the prometheus inventory
group, so the Grafana server, not the browser, talks to Prometheus. After an IP
change, regenerate inventory and rerun Grafana. The Tassadar — Nodes dashboard
is provisioned from roles/grafana/files/tassadar-nodes.json: online nodes, CPU,
memory and filesystem usage. It is managed in Git, so edit the JSON rather
than the UI. CPU rate panels need multiple scrapes before displaying values.
Database-specific panels and alert notifications remain future work.

### Credentials and persistence

Only initialization needs the plaintext admin password on the VM. It is
temporarily written to /run/tassadar-grafana/admin-password with mode 0640,
read through Grafana's file provider, and removed in an always block.
The final INI disables automatic initial-admin creation and no longer
references the temporary file. Administrator authentication is verified
before writing an initialization marker. Repeated runs verify the existing
password and do not reset it; update the supplied secret after a UI password
change. If the controller is killed, always cleanup cannot be guaranteed:
rerun the role and inspect the runtime file before leaving the VM idle.

Grafana stores its SQLite database and state in /var/lib/grafana; reruns do
not delete them. Its separate encryption key is generated once in memory
and stored in /etc/grafana/secret-key (root:grafana, 0640), never overwritten
by ordinary reruns. This application key must remain stable and be backed up
with the database; cloud deployment tokens are not copied to Grafana.
Full infrastructure destroy deletes the VM disk, database and key.

### Verification

With GRAFANA_ADMIN_PASSWORD supplied as above:

```bash
ansible-playbook playbooks/grafana-verify.yml
```

The same verification runs at the end of installation. It checks database
health, the exact provisioned datasource URL/type/default/read-only settings,
datasource connectivity, live exporter values and per-node host metrics
through Grafana's data proxy, and the provisioned dashboard. The complete
node_exporter group is required. It fails if Prometheus is unreachable or
expected nodes/metrics are missing. Authenticated tasks use no_log.

These API checks verify Grafana provisioning and server-to-Prometheus access.
They do not replace browser visual checks, real VM installation/restart/
idempotence checks, or testing the operator's SSH tunnel.

Grafana references: [release metadata and checksum](https://grafana.com/api/grafana/versions/13.2.4),
[provisioning](https://grafana.com/docs/grafana/latest/administration/provisioning/).
