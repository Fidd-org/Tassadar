#!/usr/bin/env bash
# Install one reviewed analyzer in this runner's private temporary directory.
set -euo pipefail
umask 077

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

[[ "$#" == 1 ]] || fail 'Usage: install-analysis-tool.sh shellcheck|actionlint|zizmor'
tool="$1"
case "$tool" in shellcheck|actionlint|zizmor) ;; *) fail 'Unknown analysis tool' ;; esac
[[ "$(uname -s)" == Linux && "$(uname -m)" == x86_64 ]] || fail 'Analysis tools require Linux x86_64'

require_owned_directory() {
  [[ -d "$1" && ! -L "$1" ]] || fail 'Analysis runtime must use real directories'
  [[ "$(stat -c '%u' -- "$1")" == "$(id -u)" ]] || fail 'Analysis runtime must belong to the current user'
  [[ "$(stat -c '%a' -- "$1")" =~ ^[0-7]?[0-7][0145][0145]$ ]] ||
    fail 'Analysis runtime must not allow group or other writes'
}

: "${RUNNER_TEMP:?Set RUNNER_TEMP to an owned temporary directory}"
[[ "$RUNNER_TEMP" == /* && "$RUNNER_TEMP" != / ]] || fail 'RUNNER_TEMP must be an absolute task directory'
require_owned_directory "$RUNNER_TEMP"
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
manifest="$repo_root/.github/analysis-tools.json"
[[ "$(jq -er '.platform' "$manifest")" == linux-x86_64 ]] || fail 'Unsupported analyzer platform'
record="$(jq -ce --arg tool "$tool" '.tools[$tool] // error("Unknown analysis tool")' "$manifest")"
version="$(jq -er '.version' <<< "$record")"
url="$(jq -er '.url' <<< "$record")"
checksum="$(jq -er '.sha256' <<< "$record")"
member="$(jq -er '.archive_member' <<< "$record")"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail 'Invalid pinned analyzer version'
[[ "$checksum" =~ ^[a-f0-9]{64}$ ]] || fail 'Invalid analyzer SHA256'
[[ "$url" == https://github.com/*/releases/download/* ]] || fail 'Use an official HTTPS release URL'
[[ "$member" != /* && "${member##*/}" == "$tool" ]] || fail 'Invalid analyzer archive member'

install_temp="$(mktemp -d "$RUNNER_TEMP/tassadar-analysis-install.XXXXXX")"
trap 'rm -rf -- "$install_temp"' EXIT
curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
  --connect-timeout 15 --max-time 120 --retry 3 --retry-delay 2 \
  --output "$install_temp/archive" "$url"
(
  cd -- "$install_temp"
  printf '%s  archive\n' "$checksum" | sha256sum --check --status
) || fail 'Analyzer archive SHA256 mismatch'
# Stream only the selected executable; never extract archive paths into the filesystem.
tar -xOf "$install_temp/archive" -- "$member" > "$install_temp/tool"
[[ -s "$install_temp/tool" ]] || fail 'Analyzer executable is empty'
chmod 0755 -- "$install_temp/tool"
case "$tool" in actionlint) version_flag=-version ;; *) version_flag=--version ;; esac
output="$("$install_temp/tool" "$version_flag")" || fail 'Analyzer version command failed'
case "$tool" in
  shellcheck) [[ $'\n'"$output"$'\n' == *$'\n'"version: $version"$'\n'* ]] ;;
  actionlint) [[ "${output%%$'\n'*}" == "$version" ]] ;;
  zizmor) [[ "$output" == "zizmor $version" ]] ;;
esac || fail 'Analyzer executable version differs from the manifest'

tools_root="$RUNNER_TEMP/tassadar-analysis"
for directory in "$tools_root" "$tools_root/bin"; do
  if [[ ! -e "$directory" && ! -L "$directory" ]]; then
    mkdir -m 700 -- "$directory"
  fi
  require_owned_directory "$directory"
done
[[ ! -L "$tools_root/bin/$tool" ]] || fail 'Refusing to overwrite an analyzer symlink'
install -m 0755 -- "$install_temp/tool" "$tools_root/bin/$tool"
printf 'Installed %s %s; archive SHA256 verified.\n' "$tool" "$version"
