#!/usr/bin/env bash
#
# Foundations profile health verification (PROFILE-02). Runs ON the VM. Reports
# the installed tool versions (proving the VM is PREPARED, not an empty box) and
# asserts the excluded heavy tooling is ABSENT from the minimum profile.
set -u
fail=0

echo "== dbai foundations health =="
echo "profile marker: $(cat /etc/dbai-profile 2>/dev/null || echo MISSING)"

present() { # tool
  if command -v "$1" >/dev/null 2>&1; then
    printf 'OK   %-8s %s\n' "$1" "$($1 --version 2>&1 | head -1)"
  else
    printf 'FAIL %-8s missing (profile not prepared)\n' "$1"; fail=1
  fi
}
absent() { # tool
  if command -v "$1" >/dev/null 2>&1; then
    printf 'FAIL %-10s present but must be ABSENT from the minimum profile\n' "$1"; fail=1
  else
    printf 'OK   %-10s absent\n' "$1"
  fi
}

echo "-- required --"
present git
present uv
present ssh

echo "-- excluded (must be absent) --"
for t in docker k3s kubectl eksctl kind micromamba conda; do absent "$t"; done

echo "-- no baked student work --"
if [ -e "$HOME/hello-world" ] || [ -e "$HOME/app" ]; then
  echo "FAIL student app appears baked into the profile"; fail=1
else
  echo "OK   no repaired app / solution / CI baked in"
fi

[ "$fail" = 0 ] && echo "HEALTH: PASS" || echo "HEALTH: FAIL"
exit "$fail"
