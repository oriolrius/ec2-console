#!/usr/bin/env bash
#
# secret-sentinel (RECOVERY-02, RECOVERY-R009): fail if any PRIVATE key material
# or obvious credential value appears in Git-tracked files, or in extra files
# passed as arguments (e.g. a rendered cloud-init or an environment manifest).
# Only PUBLIC keys and controller-local key PATHS are allowed.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

# Private-key / credential markers. Public keys (ssh-ed25519/ssh-rsa) are fine.
PATTERNS=(
  'BEGIN [A-Z ]*PRIVATE KEY'
  'aws_secret_access_key[[:space:]]*[:=]'
  'AWS_SECRET_ACCESS_KEY[[:space:]]*='
  'ASIA[0-9A-Z]{16}'          # temporary access key id
  'AKIA[0-9A-Z]{16}'          # long-lived access key id
)

fail=0
scan() { # label file/dir
  local label="$1" target="$2" p
  for p in "${PATTERNS[@]}"; do
    if grep -RInE --binary-files=without-match "$p" "$target" 2>/dev/null; then
      echo "  ^ SENTINEL: private/credential material in ${label}" >&2
      fail=1
    fi
  done
}

echo "[sentinel] scanning Git-tracked dbai/ files..."
# Tracked files only (never scan .terraform/ or local state).
while IFS= read -r f; do
  [ -f "$f" ] || continue
  scan "tracked:$f" "$f"
done < <(git ls-files dbai/)

# Extra targets (rendered cloud-init, manifest, logs) passed as args.
for extra in "$@"; do
  [ -e "$extra" ] && scan "arg:$extra" "$extra"
done

if [ "$fail" = 0 ]; then
  echo "[sentinel] PASS — no private keys or credential values found."
else
  echo "[sentinel] FAIL — see matches above." >&2
fi
exit "$fail"
