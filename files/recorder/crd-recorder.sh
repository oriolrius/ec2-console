#!/usr/bin/env bash
# crd-recorder — ExecStart of crd-recorder.service. Records the Chrome Remote
# Desktop X11 session with ffmpeg: 1 frame/s, UTC date/time burnt in (top-left),
# H.264 in MKV, one file per clock-aligned segment (default: each UTC hour).
#
# systemd owns the lifecycle: single instance, restarts (Restart=always),
# stopping, logging (journald) and priority. This script only handles what
# systemd cannot see, the X session:
#   - it waits until CRD's X display answers, then starts ffmpeg;
#   - when that display disappears or changes size (x11grab captures a fixed
#     area) it stops ffmpeg, waits for the file to be finalized and exits;
#     systemd starts it again for the next session or the new size;
#   - when ffmpeg dies it exits with an error, and systemd restarts it.
# ffmpeg must get exactly one SIGINT: a second one makes it abandon the MKV
# trailer. So the unit uses KillMode=mixed (systemd signals only this script),
# this script forwards the stop to ffmpeg once, and never exits before it.
set -uo pipefail

RECORDINGS_DIR="${CRD_RECORDER_DIR:-$HOME/recordings}"
FPS="${CRD_RECORDER_FPS:-1}"
SEGMENT_SECONDS="${CRD_RECORDER_SEGMENT_SECONDS:-3600}"
FONT="${CRD_RECORDER_FONT:-/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf}"
POLL_SECONDS=5
CRD_HOST=/opt/google/chrome-remote-desktop/chrome-remote-desktop

# Prints "<pid> <display> <xauthority>" of the X server CRD started for this
# user: an Xorg/Xvfb whose parent is the CRD host script. CRD takes the first
# free display from :20 on, so the number is detected, not assumed.
crd_display() {
  local pid ppid
  for pid in $(pgrep -u "$(id -u)" -x 'Xorg|Xvfb'); do
    ppid=$(ps -o ppid= -p "$pid" | tr -d ' ')
    grep -qaF "$CRD_HOST" "/proc/$ppid/cmdline" 2>/dev/null || continue
    tr '\0' '\n' <"/proc/$pid/cmdline" |
      awk -v pid="$pid" '/^:[0-9]+$/ && !d { d = $0 } prev == "-auth" { a = $0 } { prev = $0 } END { if (d) print pid, d, a }'
    return 0
  done
  return 1
}

screen_size() {
  xdpyinfo 2>/dev/null | awk '/dimensions:/ { print $2; exit }'
}

mkdir -p "$RECORDINGS_DIR"

ffmpeg_pid=""
stopping=0

# Sends ffmpeg its one SIGINT (if not sent yet) and waits up to 15 s for it to
# write the MKV trailer.
finalize() {
  [ -n "$ffmpeg_pid" ] || return 0
  if [ "$stopping" = 0 ]; then
    stopping=1
    kill -INT "$ffmpeg_pid" 2>/dev/null
  fi
  for _ in $(seq 30); do
    kill -0 "$ffmpeg_pid" 2>/dev/null || break
    sleep 0.5
  done
  if kill -0 "$ffmpeg_pid" 2>/dev/null; then
    echo "<4>ffmpeg did not finish within 15 s; leaving it to systemd"
    exit 1
  fi
  wait "$ffmpeg_pid"
  echo "Recording stopped"
}

# Sleeps in the background so a stop signal interrupts the wait at once.
sleep_pid=""
pause() {
  sleep "$1" &
  sleep_pid=$!
  wait "$sleep_pid"
}

# `systemctl stop` (KillMode=mixed) signals only this script. The pending
# sleep is ended here too, or systemd would have to SIGKILL it.
trap '[ -n "$sleep_pid" ] && kill "$sleep_pid" 2>/dev/null
echo "Stop requested; finalizing the recording"; finalize; exit 0' INT TERM

echo "Waiting for the CRD X display"
while :; do
  if read -r xorg_pid display xauth < <(crd_display); then
    export DISPLAY="$display" XAUTHORITY="${xauth:-$HOME/.Xauthority}"
    size=$(screen_size)
    [ -n "$size" ] && break
  fi
  pause 2
done
echo "CRD display detected: $DISPLAY ($size, Xorg pid $xorg_pid)"

# A keyframe on every clock boundary lets the segment muxer cut exactly on the
# hour; zerolatency avoids encoder delay that would shift cuts and file names.
# The crop keeps dimensions even: CRD sizes can be odd and yuv420p needs even.
# flush_packets (passed to the per-file muxer: at the segment level it has no
# effect) writes each finished MKV cluster (~5 s) to disk right away, so a
# hard kill or power loss costs seconds, not the last 256 KiB of output.
next_cut=$(( SEGMENT_SECONDS - $(date +%s) % SEGMENT_SECONDS ))
ffmpeg -hide_banner -nostdin -loglevel warning \
  -f x11grab -framerate "$FPS" -fpsprobesize 0 -video_size "$size" -i "$DISPLAY" \
  -vf "crop=trunc(iw/2)*2:trunc(ih/2)*2:0:0,drawtext=fontfile=${FONT}:text='%{gmtime\:%Y-%m-%d %T} UTC':x=8:y=8:fontsize=20:fontcolor=white:box=1:boxcolor=black@0.6:boxborderw=4" \
  -c:v libx264 -preset veryfast -tune stillimage,zerolatency -crf 30 -pix_fmt yuv420p -g 60 \
  -force_key_frames "expr:gte(t,${next_cut}+n_forced*${SEGMENT_SECONDS})" \
  -f segment -segment_time "$SEGMENT_SECONDS" -segment_atclocktime 1 \
  -segment_format matroska -segment_format_options flush_packets=1 \
  -reset_timestamps 1 -strftime 1 \
  "$RECORDINGS_DIR/crd_%Y-%m-%dT%H-%M-%SZ.mkv" &
ffmpeg_pid=$!
echo "Recording started: $DISPLAY at $size, $FPS fps, into $RECORDINGS_DIR"

# The loop's stderr is discarded: bash reports a background job killed by a
# signal there ("Killed  ffmpeg -hide_banner ..." with the whole command line).
# Our messages go to stdout, and ffmpeg keeps its own stderr (the journal).
while :; do
  pause "$POLL_SECONDS"
  # CRD ends a session (logout, restart) by killing its X server; it may start
  # a new one on the same display right away, so follow the process.
  if ! kill -0 "$xorg_pid" 2>/dev/null; then
    echo "CRD X session on $DISPLAY ended; finalizing the recording"
    finalize
    exit 0
  fi
  current=$(screen_size)
  if ! kill -0 "$ffmpeg_pid" 2>/dev/null; then
    # x11grab ends on its own (file finalized) when the screen shrinks.
    wait "$ffmpeg_pid"
    status=$?
    if [ -n "$current" ] && [ "$current" != "$size" ]; then
      echo "Resolution changed: $size -> $current; recording stopped"
      exit 0
    fi
    echo "<3>ffmpeg exited with status $status; systemd will restart the recorder"
    exit 1
  fi
  if [ -z "$current" ]; then
    echo "X display $DISPLAY is gone; finalizing the recording"
    finalize
    exit 0
  fi
  if [ "$current" != "$size" ]; then
    echo "Resolution changed: $size -> $current; finalizing the recording"
    finalize
    exit 0
  fi
done 2>/dev/null
