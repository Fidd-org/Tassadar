#!/usr/bin/env bash
# Shared by initial planning and bounded destroy recovery.
set -euo pipefail
umask 077
runtime_directory="$RUNNER_TEMP/tassadar-infra"
plan_options=()
case "$OPERATION" in
  plan|apply) ;;
  destroy-plan|destroy) plan_options+=(-destroy) ;;
  *) echo '::error::Unknown plan operation'; exit 1 ;;
esac
set +e
tofu plan "${plan_options[@]}" -input=false -no-color -detailed-exitcode -lock-timeout=5m \
  -var-file="$runtime_directory/variables.tfvars.json" \
  -out="$runtime_directory/plan.tfplan"
plan_exit=$?
set -e
if [[ "$plan_exit" != 0 && "$plan_exit" != 2 ]]; then
  exit "$plan_exit"
fi

# Only aggregate action counts leave this pipe; plan JSON can contain secrets.
tofu show -json "$runtime_directory/plan.tfplan" |
  jq -er --arg operation "$OPERATION" '
    [.resource_changes[]? | select(.mode == "managed")] as $changes |
    if ($operation == "destroy" or $operation == "destroy-plan") and
       any($changes[]; .change.actions != ["delete"] and .change.actions != ["no-op"])
    then error("Destroy plan must contain only delete or no-op actions")
    elif ($operation == "plan" or $operation == "apply") and
         any($changes[];
           ((.type == "digitalocean_volume" and .name == "pxc_data") or
            (.address | test("(^|\\.)digitalocean_volume\\.pxc_data(\\[|$)"))) and
           any(.change.actions[]; . == "delete" or . == "forget"))
    then error("Ordinary deploy cannot delete, replace or forget PXC data volumes; use a separate reviewed maintenance operation or explicit full destroy")
    else $changes end |
    [.[].change.actions[]] as $actions |
    "create=\($actions | map(select(. == "create")) | length)",
    "update=\($actions | map(select(. == "update")) | length)",
    "delete=\($actions | map(select(. == "delete")) | length)",
    "forget=\($actions | map(select(. == "forget")) | length)"
  ' >> "$GITHUB_OUTPUT"
