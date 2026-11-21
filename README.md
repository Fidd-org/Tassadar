# Tassadar

DigitalOcean infrastructure managed with OpenTofu and Ansible.
GitHub Actions manages infrastructure with monitoring and deploys PXC separately.


## What is included

- Seven VMs: bastion, three PXC nodes, FlowerCA, Prometheus and Grafana.
- A separate data volume for each PXC node.
- Private VPC networking and Cloud Firewalls.
- Node Exporter on every VM, Prometheus and a provisioned Grafana dashboard.
- Remote OpenTofu state in DigitalOcean Spaces.

Ansible connects to private VM addresses through the bastion. Inventory is
generated from state automatically. Grafana, Prometheus and exporters use
private addresses; access the UI through an SSH tunnel.

PXC uses native VM packages. Its deploy operation initializes three new nodes or verifies an
already healthy cluster without bootstrapping it again. A partial cluster or
existing inactive data stops deployment for diagnosis/recovery. A fresh deploy
can also test single-node recovery when test_recovery is enabled. MySQL Exporter, manual recovery and the FlowerCA
application remain separate steps.

## Configuration

Before running the workflow:

1. Register your automation SSH public key in DigitalOcean.
2. Ensure the existing Spaces backend is available. Its bucket, endpoint and
   state path are configured in [tofu/backend.tf](tofu/backend.tf).
3. Push the workflow to the repository's default branch.
4. Open **Settings → Secrets and variables → Actions** and add the following.

### Secrets

| Name | Value |
| --- | --- |
| `DIGITALOCEAN_TOKEN` | DigitalOcean API token |
| `SPACES_ACCESS_KEY_ID` | Spaces access key |
| `SPACES_SECRET_ACCESS_KEY` | Spaces secret key |
| `ANSIBLE_SSH_PRIVATE_KEY` | Full automation private key, including BEGIN/END lines |
| `GRAFANA_ADMIN_PASSWORD` | Current Grafana admin password, at least 20 characters |
| `PXC_ROOT_PASSWORD` | Current MySQL root password, at least 20 characters |
| `MYSQL_EXPORTER_PASSWORD` | Separate stable exporter password, 24–128 alphanumeric characters; needed for monitor and recover |

The private SSH key must match `INFRA_SSH_PUBLIC_KEY` and have no passphrase.
Enter values without surrounding quotes. Passwords must have no line breaks
or leading/trailing whitespace. Keep them stable between runs; changing a
Secret does not reset an existing Grafana/MySQL password. PXC passwords must
also contain no single quotes (`'`) or backslashes (`\`): the Percona package
installer does not safely escape these characters during initialization.

### Variables

| Name | Value |
| --- | --- |
| `INFRA_SSH_PUBLIC_KEY` | Full single-line public key registered in DigitalOcean |
| `INFRA_REGION` | Optional; defaults to `fra1` |
| `INFRA_PROJECT_ID` | Optional existing project UUID; empty uses the default project |
| `INFRA_ADMIN_CIDR` | Optional SSH source CIDR; defaults to `0.0.0.0/0` with key-only login |

CI accepts SSH server keys on first connection in each run (`accept-new`).
No manual IP addresses or `ANSIBLE_KNOWN_HOSTS` Secret are required.

## Deploy from GitHub

Open **Actions → Manage infrastructure → Run workflow** on the default branch.

| Operation | Result |
| --- | --- |
| `plan` | Preview infrastructure changes without applying them |
| `apply` | Apply a fresh plan; optionally run Ansible and monitoring (enabled by default) |
| `check` | Check SSH/Python access to all seven existing VMs |
| `destroy-plan` | Preview full infrastructure deletion without applying it |
| `destroy` | Apply a fresh destroy plan and verify the remote state is empty |

Start with `plan`, review its output, then run `apply`. Before creating VMs,
both check the planned sizes against DigitalOcean region availability and show
available alternatives with the same CPU/RAM and their prices. An unavailable
size fails before apply. This check cannot reserve capacity or prevent it from
changing between the check and VM creation. Both reject deletion,
replacement or removal from state of PXC data volumes. Full deletion is only
available through the explicit destroy operations; this guard does not cover
manual OpenTofu commands outside the workflow.
Plan needs no private SSH key or service passwords; check needs no service
passwords or DigitalOcean token. Both destroy operations use the DigitalOcean
token, Spaces credentials and public-key Variable; no private SSH key or
service passwords are needed.

For resources only, uncheck **deploy_monitoring** when running apply. This
skips all Ansible commands, SSH key preparation and monitoring/password checks.
Run Ansible yourself afterwards; a successful resources-only apply does not
verify SSH, the database or monitoring. The `check` operation still runs Ansible
regardless of this checkbox.

By default, apply runs this sequence:

`OpenTofu → inventory → SSH check → Node Exporter → Prometheus → Grafana → verification`

Check the run's **Summary** for each stage. With monitoring enabled, apply succeeds after host metrics
and the Grafana datasource/dashboard are verified. It does not install PXC
or require `PXC_ROOT_PASSWORD`. A failed or canceled deploy does not roll back
changes or delete resources automatically.

## Deploy or verify PXC

After infrastructure apply, open **Actions → Manage PXC → Run workflow**:

| Operation | Result |
| --- | --- |
| `deploy` | Install/bootstrap three new nodes and verify replication; optionally test recovery. An existing healthy cluster is only verified |
| `verify` | Check Galera health, cluster identity and cross-node writes/reads |

Both initialize the existing S3 backend, read named state outputs, generate
inventory and connect through the bastion. They never run infrastructure
plan/apply/destroy. Required settings: Spaces credentials, `ANSIBLE_SSH_PRIVATE_KEY`,
`INFRA_SSH_PUBLIC_KEY` and `PXC_ROOT_PASSWORD`; no DigitalOcean API token or
Grafana password. Missing/empty state fails before remote service operations.
Verify uses the dedicated `percona.example` test table and writes test records.
For a fresh deploy, optionally enable **test_recovery** (off by default).
After installation and replication checks, this selects a random PXC node,
stops its MySQL service, checks writes through the other two nodes, recovers
the selected node and verifies records on all three. The choice and result
appear in the log and Summary. This checkbox allows a MySQL stop and possible
SST; the manual recovery checkboxes are not required. A failed test fails the
deploy. With the checkbox off, only health and replication are checked.
A repeated deploy of an already healthy cluster skips the outage test even
when test_recovery is enabled.

For later recovery checks, use Manage PXC / test-recovery; to recover one
unavailable node, use recover. Select recovery_node and acknowledge allow_sst;
test-recovery also requires allow_node_stop. Recover restores Node Exporter and
MySQL Exporter, refreshes Prometheus targets from the new inventory and verifies
the PXC dashboard. It also needs MYSQL_EXPORTER_PASSWORD and
GRAFANA_ADMIN_PASSWORD; monitoring VMs must be reachable.

Manage PXC has a 180-minute job limit. Before starting recovery or its outage
test, it requires at least 75 minutes of remaining recovery budget. If a slow
deploy leaves less, the test fails before stopping MySQL. Cancellation and
runner failure can still interrupt recovery; inspect the cluster before retrying.

## Delete from GitHub

Run `destroy-plan` and review its output. Then run `destroy` with
`destroy_confirmation` set to `DESTROY`. Destroy creates a fresh plan in its
own run; it does not reuse the earlier preview. Operations use the same
concurrency group across both workflows, so infrastructure changes, PXC
operations and destroy cannot run together.

Full destroy deletes the VMs, PXC data volumes and monitoring data.
The existing Spaces bucket and default VPC are retained. A failed or canceled
destroy can leave partial deletion. On failure, the workflow makes one retry
with a fresh destroy plan; a second failure remains an error. Check the Summary
for attempts and the final state verification.

## Local commands

Local use requires OpenTofu, Ansible and OpenSSH.
Copy [tofu/secrets.auto.tfvars.example](tofu/secrets.auto.tfvars.example) to
`tofu/secrets.auto.tfvars`, fill in the values, and use `project_id = null`
for the default project. Supply Spaces credentials through
`AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` or a configured `AWS_PROFILE`.
Keep credentials and generated files out of Git.

Local deletion is also available:

```bash
cd tofu
tofu init
tofu plan -destroy
tofu destroy
```

## Detailed instructions

- [Inventory, PXC deployment, verification and recovery](ansible/README.md)
- [Monitoring playbooks and Grafana/Prometheus access through SSH tunnels](ansible/monitoring.md)
