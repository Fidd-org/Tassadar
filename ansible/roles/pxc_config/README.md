# pxc_config

Shared, lazy PXC defaults for deployment, verification and recovery. Official
playbooks import this role publicly before other tasks, including when the
inventory is outside the repository. Role defaults have lower precedence than
inventory/group_vars/host_vars and extra-vars. The role runs no remote actions
and generates no password until a task actually resolves pxc_root_password.
