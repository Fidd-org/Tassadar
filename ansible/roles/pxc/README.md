# pxc

Prepares Ubuntu PXC nodes:

- installs packages required by the official Percona apt setup;
- installs and enables `percona-release`;
- enables the `pxc80` repository;
- formats a new dedicated data disk as `ext4`;
- mounts the data disk at `/var/lib/mysql` using its stable by-id path;
- installs Percona XtraDB Cluster packages onto the mounted disk;
- renders `/etc/mysql/mysql.conf.d/mysqld.cnf` with cluster settings.

Host names must be `pxc-1`, `pxc-2`, and `pxc-3`.

Traffic encryption uses the PXC 8.0 default `pxc-encrypt-cluster-traffic`
behavior. The role does not manage custom SSL certificates yet.

The disk is mounted before package installation, so no existing MySQL data
directory needs to be copied. The role leaves MySQL stopped for bootstrap.

For a validated fresh deployment, a volume may initially be mounted by
DigitalOcean at /mnt/pxc_N_data. Before changing it, the role rechecks that
MySQL is absent/stopped, the whole expected volume is empty (apart from empty
lost+found), and the root-disk MySQL directory is empty. It validates the
provider mount unit's device/path/fragment and rejects competing fstab entries.
Only then does it disable/stop that unit and persist the volume at /var/lib/mysql.
The provider unit file is retained, disabled. No data is copied or formatted.
A still-mounted/busy volume fails before creating a second mount or installing
MySQL. Recovery without a complete fresh decision cannot move an automount.
