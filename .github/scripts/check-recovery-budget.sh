#!/usr/bin/env bash
set -euo pipefail

recovery_deadline="${RECOVERY_DEADLINE_EPOCH:-}"
if [[ ! "$recovery_deadline" =~ ^[1-9][0-9]{9}$ ]]; then
  echo '::error::A valid recovery deadline is required before stopping MySQL'
  exit 1
fi

# The join wait alone can take 30 minutes. Keep 75 minutes for outage checks,
# synchronization, write/read verification and controller cleanup.
remaining_seconds=$((recovery_deadline - $(date +%s)))
if (( remaining_seconds < 75 * 60 )); then
  echo '::error::Not enough job time remains for recovery; MySQL was not stopped by this operation'
  exit 1
fi
printf 'Recovery time budget checked: %s minutes remain.\n' "$((remaining_seconds / 60))"
