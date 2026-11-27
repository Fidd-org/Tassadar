#!/usr/bin/env bash
# Parse source YAML, including dynamic role tasks, without running remote plays.
set -euo pipefail
umask 077
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
validation_temp="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/tassadar-ansible-validation.XXXXXX")"
trap 'rm -rf -- "$validation_temp"' EXIT
export ANSIBLE_CONFIG="$repo_root/ansible/ansible.cfg"
export ANSIBLE_ROLES_PATH="$repo_root/ansible/roles"
export ANSIBLE_LOCAL_TEMP="$validation_temp/local"
export ANSIBLE_HOME="$validation_temp/home"
export ANSIBLE_NOCOLOR=true

python3 - "$repo_root" "$validation_temp/playbooks" <<'PYTHON'
from pathlib import Path
import json
import os
import subprocess
import sys

from ansible.parsing.dataloader import DataLoader

root = Path(sys.argv[1]).resolve()
# Include new source files during local development, but never ignored inventory or credentials.
names = subprocess.check_output([
    "git", "-C", str(root), "ls-files", "--cached", "--others", "--exclude-standard", "-z", "--", "ansible/"
]).split(b"\0")
files = sorted({Path(os.fsdecode(name)) for name in names if name and Path(os.fsdecode(name)).suffix.lower() in {".yml", ".yaml"}})
if not files:
    sys.exit("No Ansible source YAML found")
loader = DataLoader()
failed = False
playbooks = []
for relative in files:
    path = root / relative
    if path.is_symlink() or not path.is_file() or not path.resolve().is_relative_to(root):
        print(f"Invalid Ansible source path: {json.dumps(str(relative))}", file=sys.stderr)
        failed = True
        continue
    try:
        loader.load_from_file(str(path))
    except Exception as error:
        # Do not echo YAML contents, which might contain accidentally committed credentials.
        print(f"Invalid Ansible YAML: {json.dumps(str(relative))} ({type(error).__name__})", file=sys.stderr)
        failed = True
    if "playbooks" in relative.parts or relative == Path("ansible/tests/pxc-release.yml"):
        playbooks.append(relative)
loader.cleanup_all_tmp_files()
if failed:
    sys.exit(1)
if not playbooks:
    sys.exit("No Ansible playbooks found")
Path(sys.argv[2]).write_bytes(b"\0".join(os.fsencode(str(path)) for path in playbooks) + b"\0")
print(f"Parsed {len(files)} Ansible YAML files; syntax-checking {len(playbooks)} playbooks.")
PYTHON

while IFS= read -r -d '' playbook; do
  ansible-playbook --syntax-check -i localhost, "$repo_root/$playbook"
done < "$validation_temp/playbooks"
