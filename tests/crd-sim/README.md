# crd-sim — test the recorder without a Google registration

**Test machines only.** Chrome Remote Desktop needs a one-time registration with a Google account before it starts a session. `crd-sim` stands in for CRD's session handling so that `crd-recorder.service` and the CRD Recorder app can be tested end to end on an unregistered machine.

It runs inside the real `chrome-remote-desktop@ubuntu` unit, keeping its user, PAM session and environment. Like the CRD script, it:

- starts Xorg with CRD's own dummy-driver configuration on the first free display from `:20`;
- runs `~/.chrome-remote-desktop-session` (XFCE);
- when the session or Xorg exits (e.g. XFCE logout), tears everything down and relaunches;
- when stopped, tears down the session first, then Xorg.

Install on a provisioned machine:

```bash
sudo install -m 0755 crd-sim.sh /usr/local/bin/crd-sim
sudo install -m 0755 crd-sim-resize.sh /usr/local/bin/crd-sim-resize
sudo install -D -m 0644 crd-sim.conf /etc/systemd/system/chrome-remote-desktop@ubuntu.service.d/crd-sim.conf
sudo systemctl daemon-reload
sudo systemctl restart chrome-remote-desktop@ubuntu
```

Then exercise the recorder:

```bash
export DISPLAY=:20 XAUTHORITY=~/.Xauthority
crd-sim-resize 1280x720                                # resize like a CRD client does
sudo systemctl restart chrome-remote-desktop@ubuntu    # CRD restart: the recorder stops first
kill -9 "$(pgrep -x ffmpeg)"                           # crash: systemd restarts the recorder
journalctl -u crd-recorder -f
```

Remove it with `sudo rm /etc/systemd/system/chrome-remote-desktop@ubuntu.service.d/crd-sim.conf && sudo systemctl daemon-reload`, before registering the machine with Google.
