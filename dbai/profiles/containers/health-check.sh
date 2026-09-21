#!/usr/bin/env bash
#
# Containers profile health verification (PROFILE-03). Runs ON the VM. Reports
# the installed tool versions (proving the container platform is PREPARED, not an
# empty box), asserts the still-excluded orchestration tooling is ABSENT, and
# checks that no student Dockerfile/Compose/release solution was baked into the
# profile.
set -u
fail=0

echo "== dbai containers health =="
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
    printf 'FAIL %-10s present but must be ABSENT from the containers profile\n' "$1"; fail=1
  else
    printf 'OK   %-10s absent\n' "$1"
  fi
}

echo "-- required (foundations tools + containers) --"
present git
present uv
present ssh
present docker

echo "-- docker compose plugin --"
if docker compose version >/dev/null 2>&1; then
  printf 'OK   %-8s %s\n' "compose" "$(docker compose version 2>&1 | head -1)"
else
  printf 'FAIL %-8s docker compose plugin missing\n' "compose"; fail=1
fi

echo "-- docker daemon --"
if docker info >/dev/null 2>&1; then
  echo "OK   daemon reachable"
else
  echo "FAIL daemon not reachable (service down, or docker group not applied to this login yet)"; fail=1
fi

echo "-- excluded (must be absent) --"
for t in k3s kubectl eksctl kind micromamba conda; do absent "$t"; done

echo "-- no baked student work --"
if [ -e "$HOME/app" ] || [ -e "$HOME/hello-world" ] \
   || ls "$HOME"/Dockerfile "$HOME"/*/Dockerfile >/dev/null 2>&1 \
   || ls "$HOME"/compose.y*ml "$HOME"/docker-compose.y*ml >/dev/null 2>&1 \
   || ls "$HOME"/.github/workflows/*.y*ml >/dev/null 2>&1; then
  echo "FAIL student Dockerfile/Compose/release-workflow appears baked into the profile"; fail=1
else
  echo "OK   no student Dockerfile/Compose/release workflow or S6 evidence baked in"
fi

[ "$fail" = 0 ] && echo "HEALTH: PASS" || echo "HEALTH: FAIL"
exit "$fail"
