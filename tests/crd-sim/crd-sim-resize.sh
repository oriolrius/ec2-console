#!/usr/bin/env bash
# crd-sim-resize WIDTHxHEIGHT — TEST ONLY. Resizes the CRD dummy display the
# way the CRD host does when the client window changes size (new mode on
# DUMMY0, then switch to it). Needs DISPLAY/XAUTHORITY of the session.
set -eu
size=$1
label="${size}_60"
xrandr --newmode "$label" 60 "${size%x*}" 0 0 1000 "${size#*x}" 0 0 1000 2>/dev/null || true
xrandr --addmode DUMMY0 "$label" 2>/dev/null || true
xrandr -s "$size"
