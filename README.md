# Tassadar infrastructure

OpenTofu provisions a three-node Percona XtraDB Cluster in DigitalOcean. Ansible installs and bootstraps PXC 8.0 on the created Droplets.

## Architecture

- the region's default DigitalOcean VPC, reused and kept after `tofu destroy`;
- one public bastion Droplet;
- one FlowerCA application Droplet connected to PXC over the private VPC;
- three PXC Droplets connected through private VPC addresses;
- one dedicated ext4 Block Storage volume per PXC node;
- separate Prometheus and Grafana Droplets in the same VPC and state;
- Cloud Firewalls allowing SSH to FlowerCA only from the bastion, public HTTPS to FlowerCA, MySQL from FlowerCA to PXC, and Galera traffic only between PXC nodes.

## Monitoring infrastructure

The main OpenTofu root includes `pxc-prometheus` and `pxc-grafana` (names
follow `name_prefix`). Each uses Ubuntu 24.04, 1 vCPU and 2 GB RAM, configured
in `tofu/node-configs.tf`. These are starting sizes for the test environment;
retention, scrape load, and storage sizing are part of service configuration.
Data uses the VM root disks for now; no persistent monitoring volumes or
backup policy are provisioned. Full destroy deletes both VM disks and their data.

The VMs share the existing VPC and main state with PXC. A full destroy removes
monitoring along with the cluster. The current state may be empty: a plan then
creates the whole environment, not just the two monitoring VMs.

Each monitoring VM has its own role tag and Cloud Firewall. Inbound rules
use `source_tags`, so IPs do not need to be known in advance:

| Destination | TCP port | Allowed source |
| --- | --- | --- |
| Prometheus/Grafana SSH | 22 | Bastion |
| Grafana UI | 3000 | Bastion |
| Prometheus API/UI | 9090 | Grafana, bastion |
| Node Exporter on every VM | 9100 | Prometheus |
| MySQL Exporter on PXC | 9104 | Prometheus |

There is no public UI or exporter ingress. Existing public bastion SSH and
FlowerCA HTTPS rules are unchanged. Outbound rules follow the existing
configuration and allow internet access for package installation.

Tags identify permitted Droplets; they do not select a network interface or
authenticate applications. Future Ansible roles must bind service/exporter
listeners and configure scrape/datasource URLs to private VPC addresses.
The future MySQL exporter will connect to MySQL locally; Prometheus is not
granted direct port 3306 access. [Ansible playbooks](ansible/monitoring.md)
install Node Exporter, Prometheus and Grafana separately from infrastructure
apply. MySQL Exporter service automation remains planned.

After apply, `monitoring_private_ips` and `monitoring_instance_ids` describe
both nodes. Regenerate inventory after verifying their host keys. Groups
`prometheus` and `grafana` are children of `monitoring` and use SSH ProxyJump
through the bastion.

Once Grafana is installed, access it through a tunnel from the controller
using the generated SSH configuration (run from `ansible/`):

```bash
ssh -F .generated/ssh_config -N -o ExitOnForwardFailure=yes \
  -L 127.0.0.1:3000:<grafana-private-ip>:3000 tassadar-bastion
```

Open `http://127.0.0.1:3000` while the tunnel runs. Replace the placeholder
with `monitoring_private_ips["grafana-1"]`. A future public HTTPS endpoint
requires a separate TLS and authentication configuration.

## Configuration

1. Create the local OpenTofu variables file:

```bash
cp tofu/secrets.auto.tfvars.example tofu/secrets.auto.tfvars
```

Edit `tofu/secrets.auto.tfvars` and replace the placeholders. OpenTofu loads this file automatically.

2. Store the DigitalOcean Spaces credentials in the standard AWS credentials file:

```bash
mkdir -p ~/.aws
chmod 700 ~/.aws
```

Create or update `~/.aws/credentials`:

```ini
[tassadar-spaces]
aws_access_key_id = <spaces-access-key-id>
aws_secret_access_key = <spaces-secret-access-key>
```

Protect the credentials file:

```bash
chmod 600 ~/.aws/credentials
```

Select this profile for local commands with `export AWS_PROFILE=tassadar-spaces`.
GitHub runners will use credentials supplied through environment variables.

Neither local file should be committed. `project_id` can be set to `null` to keep resources in the DigitalOcean default project.

## OpenTofu

Run from `tofu/`:

```bash
tofu init -reconfigure
tofu fmt -recursive
tofu validate
tofu plan
tofu apply
```

OpenTofu stores remote state in the private `tassadar-s3` DigitalOcean Spaces bucket at `tassadar/production.tfstate`. The backend accepts standard AWS environment credentials or the profile selected with `AWS_PROFILE`.

Ansible generates `ansible/inventory.yml` from selected OpenTofu outputs on
each controller. The PXC hosts are reached by private VPC addresses through
the bastion, with verified SSH host keys.

## Ansible

Run from `ansible/`:

```bash
ansible-playbook -i localhost, playbooks/prepare-inventory.yml \
  -e inventory_ssh_private_key_path="$HOME/.ssh/id_tassadar" \
  -e inventory_known_hosts_path="$HOME/.ssh/known_hosts"

ansible bastion -m ping
ansible pxc -m ping
ansible-playbook playbooks/pxc.yml
```

The playbook:

1. installs Percona XtraDB Cluster 8.0;
2. mounts each DigitalOcean volume at `/var/lib/mysql`;
3. bootstraps `pxc-1`;
4. joins `pxc-2` and `pxc-3`;
5. verifies cluster health and replication.

Generated MySQL passwords stay in `ansible/.generated/` and must not be committed.

Useful checks:

```bash
ansible-playbook playbooks/pxc.yml --tags verify
```

The expected cluster size is `3` on every PXC node.

To recover one unavailable PXC member while the other two nodes remain a
healthy Primary component, run from `ansible/`:

```bash
ansible-playbook playbooks/pxc-recover-node.yml \
  -e pxc_recovery_node=pxc-3 \
  -e pxc_recovery_allow_sst=true
```

OpenTofu is needed before this playbook only when the Droplet itself must be
recreated. MySQL/PXC recovery on an SSH-reachable node is handled by Ansible.


## Infrastructure management

OpenTofu and Ansible run on GitHub-hosted runners. OpenTofu accesses
DigitalOcean/Spaces, and Ansible connects through the bastion. See the
[controller inventory instructions](ansible/README.md#controller-inventory).
Inventory preparation and the manual main-infrastructure plan/apply workflow
are available. Monitoring VM definitions and local Node Exporter/Prometheus
service playbooks plus Grafana provisioning are included. MySQL Exporter and service workflows
remain planned. No cloud resources are created by inventory preparation.

Use **Manage infrastructure** to provision the environment. OpenTofu and
Ansible run on GitHub-hosted runners; no management VM is required.

## GitHub Actions

Publish the workflow to the repository's default branch. In
Settings > Secrets and variables > Actions, configure:

| Type | Name | Value |
| --- | --- | --- |
| Secret | DIGITALOCEAN_TOKEN | DigitalOcean API token for the main infrastructure |
| Secret | SPACES_ACCESS_KEY_ID | Access key for the existing state backend |
| Secret | SPACES_SECRET_ACCESS_KEY | Matching Spaces secret key |
| Variable | INFRA_SSH_PUBLIC_KEY | Complete single-line OpenSSH public key already registered in DigitalOcean |
| Variable | INFRA_ADMIN_CIDR | Optional SSH source IPv4 CIDR; defaults to `0.0.0.0/0` with key-only login |
| Variable | INFRA_PROJECT_ID | Optional existing DigitalOcean project UUID; empty uses the default project |
| Variable | INFRA_REGION | Optional region; defaults to `fra1` |

Use the contents of the matching `.pub` file for `INFRA_SSH_PUBLIC_KEY`, for
example `~/.ssh/id_tassadar.pub`. Keep the full key line consistent with the
registered DigitalOcean key. No private SSH key or MySQL password is required
by this workflow.

Choose **Actions > Manage infrastructure > Run workflow**:

- `plan` (default): initialize the existing S3 backend, validate configuration,
  and preview changes without applying them;
- `apply`: generate a fresh plan and apply that saved plan in the same run.
  This mode changes real cloud resources, including any replacements shown
  by the plan. It does not reuse a plan from an earlier workflow run.

The workflow operates on the main `tofu/` configuration: bastion, PXC and
FlowerCA/Prometheus/Grafana Droplets, PXC data volumes, firewalls, and related resources. It does
not create a manager VM, install MySQL/Prometheus/Grafana, bootstrap PXC, or
deploy the FlowerCA application. Infrastructure apply completion does not mean services are ready.

Deployment credentials are scoped to runtime configuration checks, backend
initialization, planning, and apply. Checkout, tool installation, formatting, validation,
Summary, and cleanup do not receive deployment secrets.

In this public repository, workflow logs and Summary are publicly readable.
The ordinary plan/apply output can include IPs, resource IDs, firewall rules,
and public SSH keys. Credentials must be stored as Secrets, not Variables.
GitHub masks known secret values in logs, but transformed values are not
guaranteed to be masked. Do not enable shell tracing or print environment
variables, state, or raw plan JSON. The saved plan may contain secrets and
must remain a temporary local file rather than a published artifact.

Only the default branch can run the job. A shared `tassadar-production`
concurrency group prevents overlap with other operations using that group;
S3 state locking remains enabled. A failed backend initialization is an error,
not evidence of an empty environment.

The Summary reports step outcomes and planned create/update/delete/forget
counts. Replacements count as both create and delete. Temporary runtime
configuration and the saved plan are removed after the operation; they are
not uploaded as artifacts. Canceling or failing an apply does not undo cloud
changes. Inspect the state and resources before retrying or deleting anything.

A successful workflow confirms the requested infrastructure operation.
Service readiness requires the Ansible cluster health and data checks.
