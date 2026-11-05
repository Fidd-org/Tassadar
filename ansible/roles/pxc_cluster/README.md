# pxc_cluster

Bootstraps only a deployment classified as fresh by pxc_preflight:

- starts mysql@bootstrap on pxc-1;
- waits for the one-node Primary/Synced component;
- transfers the PXC TLS files;
- joins pxc-2 then pxc-3 in order;
- enables regular mysql startup for subsequent boots of pxc-1, without starting
  another MySQL instance while mysql@bootstrap is running.

The complete pxc.yml playbook calls shared pxc_verify afterwards.
Healthy existing clusters skip this role. Direct invocation without a fresh
preflight decision is rejected. This is not a full-cluster recovery procedure.
