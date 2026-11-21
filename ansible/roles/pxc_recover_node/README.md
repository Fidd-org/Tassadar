# pxc_recover_node

Recovers one unavailable PXC member by joining it to the healthy two-node
Primary component.

The role refuses recovery unless both survivor nodes report a two-node
`Primary`, `Synced`, and ready cluster. It also refuses to overwrite a recovery
target that currently reports itself as a Primary component.

Before preparing or stopping the target, preflight checks TCP connectivity
from the recovery node to port 4567 on both survivors over their inventory
addresses. SSH connectivity through the bastion does not establish that Galera
traffic can pass between nodes. The timeout defaults to 30 seconds per survivor
and can be changed with `pxc_recovery_network_timeout`.

This probe checks only joiner-to-survivor TCP access on the Galera port. It does
not prove reverse connectivity, UDP access, or SST/IST reachability. Ports 4444
(SST) and 4568 (IST) may not listen outside a transfer, so a preflight TCP probe
to these ports would not be a reliable health check. The actual join and final
synchronization checks remain required.

Starting the node may use IST or may fall back to SST. SST replaces the target
node's MySQL data, so the playbook requires explicit acknowledgement through
`pxc_recovery_allow_sst=true`.

After joining, the role runs `pxc_verify`: it checks all five wsrep health
conditions on every node, writes one test row from each node, and requires every
node to read all three rows. This is the same verification used after initial
bootstrap. No health or replication assertions were dropped during extraction.

The shared check creates `percona.example` if needed and deletes that table's
existing rows before writing its test records. Reserve this table for checks;
do not run concurrent verification or recovery tests against the same cluster.

This role does not recover a complete cluster outage. Full-cluster crash
recovery requires selecting the most advanced node from Galera state before
bootstrapping a new Primary component.

See `../../README.md` for the opt-in outage/recovery test and local regression
checks. Percona documents the network ports at:
https://docs.percona.com/percona-xtradb-cluster/8.0/install-index.html


The complete pxc-recover-node.yml playbook additionally repairs Node Exporter
and MySQL Exporter, refreshes Prometheus targets from current inventory, and
verifies the PXC dashboard. That integration requires monitoring hosts and
exporter/Grafana credentials; these are validated before DB changes. The role
itself stays focused on the DB rejoin so the existing-VM outage test can reuse it.
