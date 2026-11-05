#!/usr/bin/env bash
# Remove only this workflow run's owned controller files.
set -euo pipefail
runtime_directory="$RUNNER_TEMP/tassadar-ansible"
if [[ -f "$runtime_directory/.owned-by-tassadar" ]]; then
  rm -f -- "$runtime_directory/identity" "$runtime_directory/known_hosts" \
    "$runtime_directory/identity.pub" "$runtime_directory/expected.pub" \
    "$runtime_directory/inventory.yml" "$runtime_directory/ssh_config" \
    "$runtime_directory/inventory-vars.json" "$runtime_directory/connectivity.json" \
    "$runtime_directory/pxc-deployment.json" \
    "$runtime_directory/.owned-by-tassadar"
  rmdir -- "$runtime_directory"
fi
