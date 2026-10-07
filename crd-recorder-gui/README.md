# CRD Recorder (`crd-recorder-gui`)

A small desktop app for Ubuntu 24.04 + XFCE that shows whether the Chrome Remote Desktop (CRD) session is being recorded, turns recording on and off, and uploads finished recordings to a Transfer.sh-compatible server.

It **does not record anything itself.** Recording is done by `crd-recorder.service`, a systemd unit that runs ffmpeg. The app watches that service, controls it through `systemctl`, and handles uploads.

```text
Chrome Remote Desktop (Xorg :20 …)
        │  systemd: starts/stops with chrome-remote-desktop@ubuntu
        ▼
crd-recorder.service ── /usr/local/bin/crd-recorder (wrapper) ── ffmpeg ──▶ ~/recordings/*.mkv
        ▲                                                                       │
        │ systemctl show / enable|disable --now, journalctl -u                  │ finished files
        │                                                                       ▼
CRD Recorder (this app): tray icon · window · log · uploader ────────▶ https://x.joor.net
```

The recorder side (wrapper, unit, settings) is described in the repository [README](../README.md#session-recording) and in [`files/recorder/`](../files/recorder/).

## What it does

### Tray icon

The app starts hidden in the XFCE system tray with every session (XFCE autostart, `--hidden`) and keeps running while the window is closed.

| Icon | State | Meaning |
| --- | --- | --- |
| red dot, white ring | **Recording** | the service is running and ffmpeg is recording |
| grey ring | **Stopped** | the service is not running (recording turned off, or CRD is down) |
| amber dot | **Waiting for CRD session** | the service is running but ffmpeg isn't yet: the wrapper is waiting for CRD's X display |
| blue dot | **Restarting** | systemd will start the service again in a few seconds (after a resize, a session end or a crash) |
| grey ring | **Stopping** | the service is stopping and ffmpeg is finalizing the current file |
| red ring | **Error** | the unit failed, is not installed, or its state cannot be read |

The tooltip shows `CRD Recorder — <state>` with the running version on a second line.

- **Left click:** shows the window. A hidden window is shown, a minimized one restored, and one behind other windows raised.
- **Right click:** a menu with **Open**, **Start/Stop Recording** (whichever applies), **Upload Pending Files** and **Quit**.

The state is read from systemd every 2 seconds, not inferred from your last click, so the icon also follows changes made with `systemctl`, a CRD restart or a crash.

### Main window

The window title shows the running version, e.g. `CRD Recorder v1.9.0`. From top to bottom:

- **Status:** the state, the service details (`active/running`, whether it starts with every CRD session, how many automatic restarts) and the file being written.
- **Start recording / Stop recording:** a single control (see [Turning recording on and off](#turning-recording-on-and-off)).
- **Upload:** uploads every finished recording not uploaded yet, plus a live count ("N finished recording(s) pending upload · M being written", refreshed every 10 s).
- **Uploaded recordings:** the last 50 uploads, newest first. Each shows the file name, its URL (selectable) and a **Copy** button that puts the URL on the clipboard.
- **Log:** the recorder's journal (`[recorder]`, `[systemd]`) interleaved with the app's own events (`[app]`), in time order. Errors are red and warnings orange. It keeps the last 3,000 lines.
- **Settings:** the email, the Transfer URL, and where recordings and app files are.
- **Quit:** exits the app. Recording is not affected; it belongs to systemd.

Closing the window (×) only hides it.

### Turning recording on and off

The control runs, without a password prompt:

```bash
sudo -n /usr/bin/systemctl enable --now crd-recorder.service    # Start recording
sudo -n /usr/bin/systemctl disable --now crd-recorder.service   # Stop recording
```

The choice persists across reboots and CRD restarts. Provisioning installs `/etc/sudoers.d/crd-recorder`, which allows exactly these two commands; the app does not rely on any broader sudo rights. If the rule is missing, the log says so instead of prompting. Stopping waits until ffmpeg has finalized the current file.

The app never starts or kills ffmpeg directly.

### Uploading

**Upload** (or **Upload Pending Files** in the tray menu) scans the recordings directory and, **one file at a time, oldest first**:

1. Skips files already uploaded, matched by name **and** size.
2. Skips the file being written. A file counts as finished only if:
   - **no process has it open:** every process's `/proc/<pid>/fd` is checked; ffmpeg keeps the current segment open until it has written the end of the file;
   - **it has not changed for 10 s.**

   The directory is listed *before* open files are checked, so a segment created in between cannot be mistaken for a finished one. If ffmpeg's open files cannot be read, the scan fails instead of guessing.
3. Skips empty files (left by a recorder that was killed before writing anything).
4. Checks again, right before sending, that the file is still closed and unchanged.
5. Sends it: `PUT <transfer URL>/<file name>`, `Content-Type: video/x-matroska`. The server's reply body is the file's URL; the `X-Url-Delete` header, if present, is stored too.
6. Checks that the file did not change while it was being sent.
7. Records the upload in `state.json` (atomic write), then logs `Returned Transfer URL: <file> → <url>`.

A failure (network error, server error, a reply that is not a URL, a changed file) is logged and the file **stays pending** for the next Upload. Nothing is marked uploaded before the server has accepted it and the state has been saved. Only one upload run happens at a time.

Timeouts: connect 30 s; the server's reply after the last byte 10 min. An upload is aborted if no data can be sent for 2 min. The transfer itself has no time limit, so large files are fine.

The uploader (`internal/upload.Run`) does not depend on the GUI, so automatic or background uploads can be added later by calling it from a timer.

### Log events

Besides the recorder's own journal lines, the app logs:

| Event | When |
| --- | --- |
| `Recording started` / `Recording stopped` | ffmpeg starts / has finished the file |
| `Recorder waiting for the CRD session (X display)` | the service runs but no X display yet |
| `Recorder restarting for the new recording` | planned restart after a resize or session end (info) |
| `Recorder restarting after a failure` | unexpected restart, e.g. ffmpeg crashed (warning) |
| `Recorder stopping; ffmpeg is finalizing the current file` | the service is stopping |
| `Recording file detected: <file>` | ffmpeg opened a new file |
| `File still being written, skipped` / `Skipped <file>: <reason>` | during an upload run |
| `Upload started` / `Upload completed` / `Upload failed` / `Returned Transfer URL` | per file |
| `Settings saved` / `Settings not saved: <why>` | from the Settings form |

ffmpeg's `x11grab` errors when the captured screen changes size are hidden from the log view, because the recorder's next line explains what happened. They are still in `journalctl -u crd-recorder`.

### Single instance

Only one copy runs per user. The first takes a lock (`$XDG_RUNTIME_DIR/crd-recorder-gui.sock.lock`, released by the kernel if it crashes) and listens on `$XDG_RUNTIME_DIR/crd-recorder-gui.sock`. A later launch from the dock, the Applications menu or a shell sends it `show` and exits, so the existing window comes forward. A later `--hidden` launch (a second autostart) just exits.

## Files

| Path | Content |
| --- | --- |
| `~/.config/crd-recorder-gui/config.json` | your settings |
| `~/.config/crd-recorder-gui/state.json` | what has been uploaded |
| `~/recordings/` | recordings (`CRD_RECORDER_DIR` from `/etc/default/crd-recorder`, unless `recordings_dir` is set in `config.json`) |

Both JSON files are written atomically (temporary file, fsync, rename), with mode `0600` in a `0700` directory. A file that cannot be parsed is moved to `<name>.corrupt` and the app starts from defaults (logged as a warning).

`config.json` (created with defaults on first start):

```json
{
  "email": "",
  "transfer_url": "https://x.joor.net"
}
```

Optional: `"recordings_dir": "/path"`. Unknown fields are ignored, so new settings can be added without migrations.

`state.json`, one entry per uploaded file:

```json
{
  "version": 1,
  "last_uploaded": "crd_2026-10-01T05-05-02Z.mkv",
  "uploads": {
    "crd_2026-10-01T05-05-02Z.mkv": {
      "file": "crd_2026-10-01T05-05-02Z.mkv",
      "status": "uploaded",
      "url": "https://x.joor.net/7boHwsG6FE/crd_2026-10-01T05-05-02Z.mkv",
      "delete_url": "https://x.joor.net/7boHwsG6FE/crd_2026-10-01T05-05-02Z.mkv/…",
      "size": 998912,
      "uploaded_at": "2026-10-01T05:06:37Z"
    }
  }
}
```

To upload a file again, remove its entry (with the app closed).

## Command line

```bash
crd-recorder-gui            # start, or bring the running instance's window forward
crd-recorder-gui --hidden   # start in the tray only (used by XFCE autostart)
crd-recorder-gui --version  # print the version of the installed binary
```

`--version` reports the installed binary. The window title and tray tooltip report the running process; after an upgrade, **Quit** from the tray menu and reopen the app from the dock.

## Installation

Normally done by Ansible: `uv run ansible-playbook playbook.yml --tags recorder` from the repository root. It installs:

| Path | What |
| --- | --- |
| `/usr/local/bin/crd-recorder-gui` | the binary, from the GitHub release (`crd_recorder_gui_version`, default `latest`), checked against its `.sha256` |
| `/usr/share/pixmaps/crd-recorder-gui.svg` | the icon |
| `/usr/share/applications/crd-recorder-gui.desktop` | Applications-menu entry (`StartupWMClass=crd-recorder-gui`) |
| `/etc/xdg/autostart/crd-recorder-gui.desktop` | starts `crd-recorder-gui --hidden` with every XFCE session |
| `/etc/sudoers.d/crd-recorder` | the two `systemctl` commands, no password |

The `desktop` component adds the system tray to the top panel and a CRD Recorder launcher to the dock. To install a binary you built yourself: `-e crd_recorder_gui_src=/path/to/crd-recorder-gui`.

Runtime requirements: GTK 3 (`libgtk-3-0`, part of the XFCE desktop), `systemctl`, `journalctl`, `sudo`. The user must be able to read the system journal: on Ubuntu, `ubuntu` is in the `adm` group.

## Building

Requirements:

- Go (the version in [`go.mod`](go.mod), currently 1.26)
- a C compiler and the GTK 3 development files: `sudo apt-get install -y build-essential libgtk-3-dev`
- Linux; the binary is dynamically linked against GTK, so build on the same Ubuntu release as the target (24.04)

```bash
cd crd-recorder-gui
go build -trimpath -ldflags "-s -w -X main.version=v1.9.0-dev" -o crd-recorder-gui .
./crd-recorder-gui --version
```

The first build takes a few minutes: cgo compiles the gotk3 GTK bindings. Later builds use Go's build cache. `-X main.version=…` sets the version shown by `--version`, the window title and the tooltip (default `dev`). The stripped binary is about 9 MB.

Tests and checks (what CI runs):

```bash
go vet ./...
go test ./...
go test -race ./internal/config ./internal/instance ./internal/journal ./internal/recorder ./internal/systemd ./internal/upload
gofmt -l .
```

The race detector runs only on the packages without GTK: they hold the concurrent code, and `-race` would otherwise recompile all of gotk3.

### Notes on the GTK bindings

- **gotk3 version:** it is pinned to a master pseudo-version, because the v0.6.4 release does not compile.
- **Tray icon:** it uses `GtkStatusIcon` (XEmbed), which is what xfce4-panel's system tray shows and what reports plain left clicks. gotk3 exposes it only behind its `gtk_deprecated` build tag, which no longer compiles with current Go, so `internal/tray/statusicon.go` calls GTK directly through a small cgo shim. **Do not** build with `-tags gtk_deprecated`.
- **Threading:** GTK is driven only from the main OS thread. Background goroutines hand results over with `glib.IdleAdd`, and gotk3's finalizers are routed to the main loop as well (`glib.FinalizerStrategy` in `main.go`).

### Releases (CI)

[`.github/workflows/crd-recorder-gui.yml`](../.github/workflows/crd-recorder-gui.yml) runs vet, tests and a build on every PR and every push to `main` that touches this directory. On a `v*` tag it only builds, then attaches `crd-recorder-gui-linux-amd64` and `crd-recorder-gui-linux-amd64.sha256` to the GitHub release; Ansible downloads exactly these.

To release, from an up-to-date `main` at the repository root: run `cz bump`, then push the commit and the tag.

## Code layout

| Package | Responsibility |
| --- | --- |
| `main.go` | flags, single-instance check, GTK start-up |
| `internal/config` | `config.json` / `state.json`: load, validate, atomic save, upload records |
| `internal/systemd` | `systemctl show`, `enable/disable --now` through `sudo -n`, the unit's processes (cgroup) |
| `internal/journal` | the recorder's journal: recent history (`journalctl -n`) then live (`journalctl -f -o json`, resumed by cursor) |
| `internal/recorder` | the recorder state (systemd state + whether ffmpeg runs in the unit), the files ffmpeg has open, the recordings directory |
| `internal/upload` | finding finished recordings, the Transfer.sh client, the sequential upload run |
| `internal/instance` | single instance: lock + Unix socket, "show" message |
| `internal/tray` | the tray icon: state icons (drawn in Go), tooltip, click and menu |
| `internal/gui` | the window and the glue: status polling, log, Start/Stop, Upload, settings |

## Troubleshooting

| Symptom | Check |
| --- | --- |
| No tray icon | The top panel needs the **Status Tray** plugin; provisioning adds it. The app logs a warning if no tray shows up within 15 s. |
| State stays **Error** | `systemctl status crd-recorder`; is the unit installed (`--tags recorder`)? |
| Start/Stop says "not allowed" | `/etc/sudoers.d/crd-recorder` is missing: re-run `--tags recorder`. |
| Log is empty / "insufficient permissions" | The user must be allowed to read the system journal (`adm` or `systemd-journal` group). |
| Waiting for CRD session never ends | Is CRD running (`systemctl status chrome-remote-desktop@ubuntu`)? `journalctl -u crd-recorder` shows what the wrapper sees. |
| A file is never uploaded | The log shows why: still open, changed in the last 10 s, empty, or an upload error. |
| Window does not come forward from the dock | `pgrep -a crd-recorder-gui` should list one process; a stale socket is cleaned up automatically on the next start. |
