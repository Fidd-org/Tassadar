#!/usr/bin/env bash
# A partial destroy can leave stale computed volume references in the provider.
# Re-plan once from live state; never reuse the failed plan or ignore errors.
set -euo pipefail
umask 077

script_directory="$(cd -- "$(dirname -- "$0")" && pwd)"
plan_path="$RUNNER_TEMP/tassadar-infra/plan.tfplan"

for attempt in 1 2; do
  echo "attempts=$attempt" >> "$GITHUB_OUTPUT"
  if tofu apply -input=false -no-color -lock-timeout=5m "$plan_path"; then
    exit 0
  else
    apply_exit=$?
  fi

  # Do not retry a second failure or a process interrupted by a signal.
  if [[ "$attempt" == 2 || "$apply_exit" -ge 128 ]]; then
    exit "$apply_exit"
  fi

  echo '::warning::Destroy failed or was partial. Refreshing state and creating one new destroy plan before retrying.'
  sleep 5
  OPERATION=destroy bash "$script_directory/plan-infrastructure.sh"
done
