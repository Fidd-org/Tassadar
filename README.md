# Tassadar infrastructure

OpenTofu provisions a three-node Percona XtraDB Cluster in DigitalOcean. Ansible installs and bootstraps PXC 8.0 on the created Droplets.

## Architecture

- the region's default DigitalOcean VPC, reused and kept after `tofu destroy`;
- one public bastion Droplet;
- one FlowerCA application Droplet connected to PXC over the private VPC;
- three PXC Droplets connected through private VPC addresses;
- one dedicated ext4 Block Storage volume per PXC node;
- Cloud Firewalls allowing SSH to FlowerCA only from the bastion, public HTTPS to FlowerCA, MySQL from FlowerCA to PXC, and Galera traffic only between PXC nodes.

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

ansible pxc -b -m shell -a \
  "MYSQL_PWD='$(cat .generated/pxc_root_password)' mysql --user=root --batch --skip-column-names --execute=\"SHOW STATUS LIKE 'wsrep_cluster_size';\""
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
are available. PXC deployment/recovery workflows and monitoring remain
planned. No cloud resources are created by inventory preparation.

The older [bootstrap project](bootstrap/README.md) and its provisioning
workflow are retained as legacy tools. The manager readiness workflow has
been removed. A management VM is not required by this architecture.

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
registered DigitalOcean key. The bootstrap variable `BOOTSTRAP_SSH_KEY_ID`
belongs to the legacy manager module and is not used here. No private SSH key
or MySQL password is required by this workflow.

Choose **Actions > Manage infrastructure > Run workflow**:

- `plan` (default): initialize the existing S3 backend, validate configuration,
  and preview changes without applying them;
- `apply`: generate a fresh plan and apply that saved plan in the same run.
  This mode changes real cloud resources, including any replacements shown
  by the plan. It does not reuse a plan from an earlier workflow run.

The workflow operates on the main `tofu/` configuration: bastion, PXC and
FlowerCA Droplets, PXC data volumes, firewalls, and related resources. It does
not create a manager VM, install MySQL, bootstrap PXC, or deploy the FlowerCA
application. Infrastructure apply completion does not mean services are ready.

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

Workflow code is locally validated. A real GitHub/DigitalOcean/Spaces run
remains unverified until it is published, configured, and executed.
