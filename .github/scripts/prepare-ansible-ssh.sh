#!/usr/bin/env bash
# Prepare controller-only SSH files. Never installs keys on remote machines.
set -euo pipefail
umask 077

fail() {
  echo "::error::$1" >&2
  exit 1
}

for required_name in RUNNER_TEMP ANSIBLE_SSH_PRIVATE_KEY INFRA_SSH_PUBLIC_KEY; do
  [[ -n "${!required_name:-}" ]] || fail "$required_name is required"
done
[[ "$RUNNER_TEMP" == /* && "$RUNNER_TEMP" != / ]] ||
  fail 'RUNNER_TEMP must be an absolute task directory'

runtime_directory="$RUNNER_TEMP/tassadar-ansible"
# Refuse reuse/symlinks instead of overwriting unrelated files.
mkdir -m 700 -- "$runtime_directory" 2>/dev/null ||
  fail 'The Ansible runtime directory must not already exist'

cleanup_failed_preparation() {
  local result=$?
  if [[ "$result" != 0 ]]; then
    rm -f -- "$runtime_directory/identity" "$runtime_directory/known_hosts" \
      "$runtime_directory/identity.pub" "$runtime_directory/expected.pub" \
      "$runtime_directory/.owned-by-tassadar"
    rmdir -- "$runtime_directory" 2>/dev/null || true
  fi
}
trap cleanup_failed_preparation EXIT
: > "$runtime_directory/.owned-by-tassadar"

printf '%s\n' "$ANSIBLE_SSH_PRIVATE_KEY" | tr -d '\r' > "$runtime_directory/identity"
: > "$runtime_directory/known_hosts"
printf '%s\n' "$INFRA_SSH_PUBLIC_KEY" | tr -d '\r' > "$runtime_directory/expected.pub"
chmod 600 -- "$runtime_directory/identity" "$runtime_directory/known_hosts" \
  "$runtime_directory/expected.pub"

[[ "$(awk 'NF { count++ } END { print count+0 }' "$runtime_directory/expected.pub")" == 1 ]] ||
  fail 'INFRA_SSH_PUBLIC_KEY must contain one public key'
ssh-keygen -lf "$runtime_directory/expected.pub" > /dev/null 2>&1 ||
  fail 'INFRA_SSH_PUBLIC_KEY is not a valid public key'
case "$(awk 'NF { print $1 }' "$runtime_directory/expected.pub")" in
  ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521) ;;
  *) fail 'Use a software SSH identity suitable for noninteractive automation' ;;
esac
ssh-keygen -y -P '' -f "$runtime_directory/identity" \
  > "$runtime_directory/identity.pub" 2>/dev/null < /dev/null ||
  fail 'The private key is invalid or requires interactive unlocking'

[[ "$(awk 'NF { print $1, $2 }' "$runtime_directory/identity.pub")" == \
   "$(awk 'NF { print $1, $2 }' "$runtime_directory/expected.pub")" ]] ||
  fail 'ANSIBLE_SSH_PRIVATE_KEY does not match INFRA_SSH_PUBLIC_KEY'

rm -f -- "$runtime_directory/identity.pub" "$runtime_directory/expected.pub"
echo 'Controller SSH files prepared; new host keys will be accepted on first connection for this run.'
