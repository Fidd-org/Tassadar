#!/usr/bin/env bash
# Run from ansible/: read named state outputs and generate controller-only files.
set -euo pipefail
umask 077
runtime_directory="$RUNNER_TEMP/tassadar-ansible"
if [[ ! -f "$runtime_directory/.owned-by-tassadar" ]]; then
  echo '::error::Prepare the controller SSH identity before generating inventory'
  exit 1
fi
jq -n \
  --arg key "$runtime_directory/identity" \
  --arg hosts "$runtime_directory/known_hosts" \
  --arg inventory "$runtime_directory/inventory.yml" \
  --arg config "$runtime_directory/ssh_config" \
  --arg summary "$runtime_directory/connectivity.json" \
  --arg pxc "$runtime_directory/pxc-deployment.json" \
  '{inventory_ssh_private_key_path: $key, inventory_known_hosts_path: $hosts,
    inventory_output_path: $inventory, inventory_ssh_config_path: $config,
    connectivity_summary_path: $summary, pxc_summary_path: $pxc, inventory_host_key_checking: "accept-new"}' > "$runtime_directory/inventory-vars.json"
ansible-playbook -i localhost, playbooks/prepare-inventory.yml \
  -e "@$runtime_directory/inventory-vars.json"
