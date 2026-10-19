> Legacy optional module: the agreed architecture runs OpenTofu and Ansible
> directly on GitHub-hosted runners through the existing bastion. This manager
> module and its workflows are not required. See [the current architecture](../README.md#infrastructure-management).

# Management VM bootstrap

This standalone OpenTofu root creates a management VM from a GitHub-hosted
runner. It reuses the default fra1 VPC and existing DigitalOcean SSH key and
creates one Ubuntu 24.04 Droplet, one tag, and one SSH firewall.

It uses tassadar/bootstrap.tfstate in the existing tassadar-s3 Spaces bucket.
The main root remains in tofu/ with its existing tassadar/production.tfstate;
this workflow does not deploy or change PXC, FlowerCA, the bastion, or their disks.

## GitHub configuration

Enable GitHub Actions and add repository Secrets under
Settings > Secrets and variables > Actions:

| Secret | Value |
| --- | --- |
| DIGITALOCEAN_TOKEN | API token authorized to read VPCs and SSH keys and manage Droplets, tags, and firewalls |
| SPACES_ACCESS_KEY_ID | Existing Spaces access key ID |
| SPACES_SECRET_ACCESS_KEY | Existing Spaces secret access key |

Spaces credentials need access to the bucket and bootstrap state and lock
objects, including reading, writing, and deleting the lock object.

Add the required repository Variable in the same settings:

| Variable | Value |
| --- | --- |
| BOOTSTRAP_SSH_KEY_ID | Numeric ID of an existing SSH key in DigitalOcean |

BOOTSTRAP_ADMIN_CIDR is optional. Set it to an administrator's public IPv4 /32
or trusted IPv4 CIDR to restrict SSH by source address. Without it, port 22 is
open to all IPv4 addresses (0.0.0.0/0); SSH password authentication is disabled
and access requires the matching private key.

The SSH key must already exist in DigitalOcean. Keep its private key on the
administrator's machine. No private SSH key, MySQL password, or Vault password
is required by this workflow.

## Run

Commit and publish the bootstrap files and workflow to the repository's default
branch. In Actions, choose **Bootstrap management VM** > **Run workflow**:

1. Select plan to inspect the proposed resources.
2. Select apply to generate and apply a fresh plan in one job.

Only the default branch is permitted to run the job. It runs manually, with
one bootstrap job at a time, and uses S3 state locking. Credentials are passed
through environment variables, never through Droplet user data. No state or
plan artifacts are uploaded.

The first run proposes creation; subsequent runs use the same state to plan
updates. Errors accessing Spaces stop the job rather than being treated as
"no infrastructure exists". A missing state is not proof that no VM exists:
if an existing state was lost, restore it or import the existing resources
before applying another creation plan.

The workflow reports Droplet provisioning and addresses, not completion of
cloud-init. After apply, connect with the matching private SSH key from the
configured CIDR (any IPv4 by default), verify the SSH host fingerprint using the DigitalOcean console,
and check:

    ssh -i /path/to/private-key -o IdentitiesOnly=yes root@<manager-public-ip>
    cloud-init status --wait
    test -f /var/lib/tassadar/bootstrap-complete
    tofu version
    ansible-playbook --version

Use the private key file without the .pub suffix. Run SSH in the environment
where that file exists; a key stored in WSL is not automatically selected by
Windows SSH. IdentitiesOnly=yes selects the explicitly supplied identity.

Cloud-init installs OpenTofu 1.12.3, Ansible core 2.18.6 in a Python virtual
environment, and Git. Installation failures must be resolved before using the VM.
Changes to creation settings or cloud-init may require VM replacement; inspect
the plan before applying updates.

The old automated management VM readiness workflow has been retired.
Use the manual SSH checks above if running this optional legacy module.
The current architecture runs OpenTofu and Ansible directly on hosted runners
through the bastion; see [the main README](../README.md#infrastructure-management).

Ansible Vault integration is deferred. For this stage, only the DigitalOcean
and Spaces credentials in GitHub Secrets are needed.

## Local validation without credentials

From this directory:

    tofu init -backend=false
    tofu fmt -check -recursive
    tofu validate

These checks do not create resources or validate Spaces access, provider
permissions, cloud-init execution, or GitHub workflow execution.
