#!/usr/bin/env bash
# crd-sim — TEST ONLY. Stands in for Chrome Remote Desktop's session handling
# on a host that is not registered with Google, so the recorder can be tested
# end to end. It runs as a drop-in of chrome-remote-desktop@<user>.service
# (crd-sim.conf), which keeps the real unit (User=, PAM session, environment),
# and mimics /opt/google/chrome-remote-desktop/chrome-remote-desktop:
#   - Xorg with CRD's own dummy-driver config (gen_xorg_config() of the real
#     script) on the first free display from :20, parented by this process;
#   - the user's ~/.chrome-remote-desktop-session (XFCE) as the session;
#   - the session or Xorg exits (e.g. XFCE logout) -> tear down, relaunch;
#   - SIGTERM (systemctl stop/restart) -> tear down and exit.
# Tear-down order is CRD's: session first, then Xorg, SIGTERM + 10 s grace.
# The real script's path must be in our argv (see crd-sim.conf): the recorder
# recognizes CRD's X server by its parent's command line, as with real CRD.
set -u

CRD=/opt/google/chrome-remote-desktop/chrome-remote-desktop
XAUTH="$HOME/.Xauthority"
session_pid="" xorg_pid="" confdir=""

launch() {
  local n=20
  while [ -e "/tmp/.X11-unix/X$n" ]; do n=$((n + 1)); done
  export DISPLAY=":$n" XAUTHORITY="$XAUTH" CHROME_REMOTE_DESKTOP_SESSION=1
  touch "$XAUTH"
  xauth -f "$XAUTH" add "$DISPLAY" . "$(mcookie)"
  confdir=$(mktemp -d /tmp/chrome_remote_desktop_XXXXXXXX)
  python3 -c 'import importlib.machinery, sys
m = importlib.machinery.SourceFileLoader("crd", sys.argv[1]).load_module()
print(m.gen_xorg_config())' "$CRD" >"$confdir/xorg.conf"
  /usr/lib/xorg/Xorg "$DISPLAY" -auth "$XAUTH" -nolisten tcp -noreset \
    -logfile /dev/null -verbose 3 -configdir "$confdir" -config "$confdir/none" &
  xorg_pid=$!
  for _ in $(seq 50); do
    xdpyinfo >/dev/null 2>&1 && break
    sleep 0.2
  done
  crd-sim-resize 1600x1200 # CRD's default initial size
  echo "crd-sim: Xorg on $DISPLAY (pid $xorg_pid); starting the session"
  /bin/sh -c "$HOME/.chrome-remote-desktop-session" &
  session_pid=$!
}

teardown() {
  local pid
  for pid in $session_pid $xorg_pid; do
    kill -TERM "$pid" 2>/dev/null
    for _ in $(seq 100); do
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.1
    done
    kill -KILL "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
  done
  rm -rf "$confdir"
  session_pid="" xorg_pid=""
}

trap 'echo "crd-sim: stopping"; teardown; exit 0' TERM INT

while :; do
  launch
  wait -n "$session_pid" "$xorg_pid"
  echo "crd-sim: session or X server exited; tearing down and relaunching"
  teardown
  sleep 1
done
