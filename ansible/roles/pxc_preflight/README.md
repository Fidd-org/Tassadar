# pxc_preflight

Classifies a complete Ubuntu 24.04 amd64/systemd PXC inventory before deployment.

- Requires pxc-1..3, full host selection and a valid protected credential.
- Requires the OpenTofu-created ext4 block volumes and expected device identity and filesystem root.
  Bind-mounted subdirectories and masking child mounts are rejected.
- Inspects clean unmounted disks through private read-only/noload mounts.
- Also inspects the known DigitalOcean /mnt/pxc_N_data mount without moving it.
  Unknown/multiple mounts, wrong devices, subdirectory binds and hidden child
  mounts are rejected. Existing data never qualifies for a fresh deployment.
- Does not treat failed probes, nonempty lost+found or existing data as empty.
- Allows fresh only when all three disks are empty and MySQL binaries/processes
  are absent; allows healthy only when all three nodes are ready/synced members
  of one named Primary cluster using the expected data directory.
- Other states require diagnosis/recovery, without installing or bootstrapping.

Inspection mount cleanup is attempted in always; directory deletion requires a
confirmed unmount. A killed controller cannot guarantee remote cleanup; inspect
/run/tassadar-pxc-inspect-* and mount state after interruption.
Preflight expects the Ubuntu image to provide util-linux, procps and e2fsprogs.
It does not install missing probe tools or repair dirty filesystems.

The controller first validates the invocation without resolving a fallback
password. Credentials are validated on each PXC host so group/host overrides
are respected. CI validates the required environment password separately
before infrastructure changes.

After successful classification, an optional controller report records the
selected mode with verified=false before installation. The final play marks
it verified=true only after health and replication checks succeed.
