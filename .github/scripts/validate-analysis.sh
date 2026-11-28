#!/usr/bin/env bash
# Analyze repository source only; scripts and workflows are never executed here.
set -euo pipefail
umask 077

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

[[ "$#" == 1 ]] || fail 'Usage: validate-analysis.sh shellcheck|actionlint|zizmor'
tool="$1"
case "$tool" in shellcheck|actionlint|zizmor) ;; *) fail 'Unknown analysis tool' ;; esac
: "${RUNNER_TEMP:?Install the pinned tools with RUNNER_TEMP set first}"
tools_bin="$RUNNER_TEMP/tassadar-analysis/bin"
require_tool() {
  [[ -x "$tools_bin/$1" && ! -L "$tools_bin/$1" ]] || fail "Install the pinned $1 executable first"
}
require_tool "$tool"
if [[ "$tool" == actionlint ]]; then
  require_tool shellcheck
fi
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
cd -- "$repo_root"
validation_temp="$(mktemp -d "$RUNNER_TEMP/tassadar-analysis-check.XXXXXX")"
trap 'rm -rf -- "$validation_temp"' EXIT
if [[ "$tool" == shellcheck ]]; then
  git ls-files --cached --others --exclude-standard -z -- '*.sh' > "$validation_temp/files"
else
  git ls-files --cached --others --exclude-standard -z -- \
    ':(glob).github/workflows/*.yml' ':(glob).github/workflows/*.yaml' > "$validation_temp/files"
fi
mapfile -d '' -t files < "$validation_temp/files"
[[ "${#files[@]}" -gt 0 ]] || fail 'No source files found for analysis'
for file in "${files[@]}"; do
  [[ -f "$file" && ! -L "$file" ]] || fail "Refusing a missing or symlink source: $file"
done
printf 'Running %s on %s source files.\n' "$tool" "${#files[@]}"
case "$tool" in
  shellcheck) "$tools_bin/shellcheck" --norc --format=gcc -- "${files[@]}" ;;
  actionlint) "$tools_bin/actionlint" -shellcheck "$tools_bin/shellcheck" -pyflakes '' "${files[@]}" ;;
  zizmor)
    regular_exit=0
    "$tools_bin/zizmor" --offline --persona regular --strict-collection --no-progress --color never "${files[@]}" || regular_exit=$?
    printf '\nAdditional auditor findings (report only; regular findings above are blocking):\n'
    audit_exit=0
    "$tools_bin/zizmor" --offline --persona auditor --strict-collection --no-progress --color never "${files[@]}" || audit_exit=$?

    report_error() {
      if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
        printf '## Zizmor analysis\n\n**Report unavailable:** %s. Inspect the full step log.\n' "$1" >> "$GITHUB_STEP_SUMMARY"
      fi
      printf '%s\n' "$1" >&2
    }
    # Findings are expected exit codes; parsing/execution failures always fail the job.
    for scan_exit in "$regular_exit" "$audit_exit"; do
      case "$scan_exit" in
        0|11|12|13|14) ;;
        *) report_error 'Zizmor could not complete the analysis'; exit "$scan_exit" ;;
      esac
    done
    if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
      # Keep native diagnostics in the log; collect versioned JSON only for the Summary.
      report_exit=0
      "$tools_bin/zizmor" --offline --persona auditor --strict-collection --no-progress --color never \
        --format=json-v1 "${files[@]}" > "$validation_temp/findings.json" || report_exit=$?
      if [[ "$report_exit" != "$audit_exit" ]]; then
        report_error 'The Summary scan did not match the diagnostic scan'
        exit 1
      fi
      source_base=''
      if [[ "${GITHUB_SERVER_URL:-}" =~ ^https://[a-zA-Z0-9.-]+(:[0-9]+)?$ &&
            "${GITHUB_REPOSITORY:-}" =~ ^[a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+$ &&
            "${GITHUB_SHA:-}" =~ ^[a-fA-F0-9]{40}$ ]]; then
        source_base="$GITHUB_SERVER_URL/$GITHUB_REPOSITORY/blob/$GITHUB_SHA"
      fi
      if ! jq -r --arg source_base "$source_base" --argjson regular_exit "$regular_exit" \
        --argjson audit_exit "$audit_exit" -f "$repo_root/.github/scripts/zizmor-summary.jq" \
        "$validation_temp/findings.json" > "$validation_temp/summary.md"; then
        report_error 'Cannot build the Zizmor Summary from its findings'
        exit 1
      fi
      cat -- "$validation_temp/summary.md" >> "$GITHUB_STEP_SUMMARY"
    fi
    if [[ "$regular_exit" != 0 ]]; then
      exit "$regular_exit"
    fi
    if [[ "$audit_exit" != 0 ]]; then
      printf '::warning::Additional Zizmor auditor findings require review; regular findings remain blocking.\n'
    fi
    ;;
esac
