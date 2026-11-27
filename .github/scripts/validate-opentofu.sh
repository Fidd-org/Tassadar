#!/usr/bin/env bash
# Validate source configuration with fresh plugin data and no state backend.
set -euo pipefail
umask 077
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
validation_temp="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/tassadar-tofu-validation.XXXXXX")"
trap 'rm -rf -- "$validation_temp"' EXIT
export TF_DATA_DIR="$validation_temp/data"
export TF_IN_AUTOMATION=true
export TF_INPUT=false

tofu -chdir="$repo_root/tofu" fmt -check -diff -recursive
tofu -chdir="$repo_root/tofu" init -backend=false -input=false -lockfile=readonly
tofu -chdir="$repo_root/tofu" validate -no-color
