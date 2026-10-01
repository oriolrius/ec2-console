// Package recorder observes and toggles crd-recorder.service. The recording
// itself (wrapper + ffmpeg) is run by systemd; nothing here starts or kills
// ffmpeg.
package recorder

import (
	"bufio"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/oriolrius/ec2-console/crd-recorder-gui/internal/systemd"
)

// Unit is the systemd service that records the CRD session.
const Unit = "crd-recorder.service"

// EnvFile holds the recorder settings (CRD_RECORDER_DIR, ...).
const EnvFile = "/etc/default/crd-recorder"

// State is what the recorder is doing, derived from systemd and the unit's
// processes.
type State int

const (
	Unknown    State = iota
	Stopped          // service inactive (recording disabled or CRD down)
	Waiting          // service running, no ffmpeg: waiting for the CRD X display
	Recording        // ffmpeg is running in the service
	Restarting       // systemd will start the service again shortly
	Stopping         // service is stopping; ffmpeg is finalizing the file
	Error            // service failed, or its state cannot be read
)

func (s State) String() string {
	switch s {
	case Stopped:
		return "Stopped"
	case Waiting:
		return "Waiting for CRD session"
	case Recording:
		return "Recording"
	case Restarting:
		return "Restarting"
	case Stopping:
		return "Stopping"
	case Error:
		return "Error"
	}
	return "Unknown"
}

// Active reports whether the recorder is (or is about to be) running, i.e.
// whether the toggle should offer "Stop".
func (s State) Active() bool {
	return s == Waiting || s == Recording || s == Restarting
}

// Status is a snapshot of the recorder.
type Status struct {
	State       State
	Enabled     bool   // starts with every CRD session
	ActiveState string // systemd ActiveState/SubState, e.g. "active/running"
	Restarts    int    // NRestarts: automatic restarts since the unit was started
	Files       []string
	Err         error
}

// Query reads the current status from systemd and /proc.
func Query() Status {
	p, err := systemd.Show(Unit, "ActiveState", "SubState", "UnitFileState", "NRestarts", "ControlGroup", "Result", "LoadState")
	if err != nil {
		return Status{State: Error, Err: err}
	}
	if p["LoadState"] == "not-found" {
		return Status{State: Error, Err: fmt.Errorf("%s is not installed", Unit)}
	}
	st := Status{
		Enabled:     p["UnitFileState"] == "enabled",
		ActiveState: p["ActiveState"] + "/" + p["SubState"],
	}
	st.Restarts, _ = strconv.Atoi(p["NRestarts"])
	ffmpeg := false
	pids, _ := systemd.CgroupPIDs(p["ControlGroup"])
	for _, pid := range pids {
		if comm(pid) == "ffmpeg" {
			ffmpeg = true
			st.Files = append(st.Files, openRecordings(pid)...)
		}
	}
	st.State = derive(p["ActiveState"], p["SubState"], ffmpeg)
	if st.State == Error {
		st.Err = fmt.Errorf("%s %s (result: %s)", Unit, st.ActiveState, p["Result"])
	}
	return st
}

func derive(active, sub string, ffmpeg bool) State {
	switch active {
	case "active", "reloading":
		if ffmpeg {
			return Recording
		}
		return Waiting
	case "activating":
		if sub == "auto-restart" {
			return Restarting
		}
		return Waiting
	case "deactivating":
		return Stopping
	case "inactive":
		return Stopped
	case "failed":
		return Error
	}
	return Unknown
}

func comm(pid int) string {
	b, _ := os.ReadFile(fmt.Sprintf("/proc/%d/comm", pid))
	return strings.TrimSpace(string(b))
}

// openRecordings lists the .mkv files a process has open.
func openRecordings(pid int) []string {
	fdDir := fmt.Sprintf("/proc/%d/fd", pid)
	fds, _ := os.ReadDir(fdDir)
	var files []string
	for _, fd := range fds {
		if target, err := os.Readlink(filepath.Join(fdDir, fd.Name())); err == nil && strings.HasSuffix(target, ".mkv") {
			files = append(files, target)
		}
	}
	return files
}

// Enable turns recording on: `systemctl enable --now crd-recorder`.
func Enable() error { return systemd.Enable(Unit) }

// Disable turns recording off: `systemctl disable --now crd-recorder`.
func Disable() error { return systemd.Disable(Unit) }

// RecordingsDir is where the recorder writes: CRD_RECORDER_DIR from
// /etc/default/crd-recorder, else ~/recordings (the wrapper's default).
func RecordingsDir() string {
	if dir := envFileValue(EnvFile, "CRD_RECORDER_DIR"); dir != "" {
		return dir
	}
	home, _ := os.UserHomeDir()
	return filepath.Join(home, "recordings")
}

// envFileValue reads KEY=value from a systemd EnvironmentFile.
func envFileValue(path, key string) string {
	f, err := os.Open(path)
	if err != nil {
		return ""
	}
	defer f.Close()
	value := ""
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		k, v, ok := strings.Cut(line, "=")
		if !ok || strings.HasPrefix(line, "#") || strings.TrimSpace(k) != key {
			continue
		}
		value = strings.Trim(strings.TrimSpace(v), `"'`)
	}
	return value
}
