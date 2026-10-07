package gui

import (
	"regexp"
	"strings"

	"github.com/oriolrius/ec2-console/crd-recorder-gui/internal/recorder"
)

// logLine is one line for the log view.
type logLine struct {
	priority int // journald levels: 3 error, 4 warning, 6 info
	msg      string
}

// events turns recorder status changes and recorder journal lines into log
// lines, so the log tells what happened in the order it happened. Main
// thread only.
type events struct {
	recording bool // "Recording started" was logged, "Recording stopped" not yet
	planned   bool // the recorder announced it is ending on purpose
}

// Lines in which the wrapper announces a planned end of the current recording
// (systemd then restarts it for the new size or session).
var plannedPrefixes = []string{"Resolution changed:", "CRD X session on ", "X display "}

// x11grab's complaints when the screen it captures changes size or goes away.
// They come right before the wrapper's own explanation (resize, session end,
// or ffmpeg's exit status), so they are hidden from the log view; journald
// keeps them.
var x11grabTeardown = regexp.MustCompile(`^\[(x11grab|in#\d+/x11grab) @ 0x[0-9a-f]+\] (Cannot get the image data|Continuing without shared memory|Error during demuxing|Error retrieving a packet from demuxer|Failed to query xcb pointer)`)

// journalLine notes a line from the recorder and reports whether to show it.
func (e *events) journalLine(msg string) bool {
	for _, p := range plannedPrefixes {
		if strings.HasPrefix(msg, p) {
			e.planned = true
		}
	}
	return !x11grabTeardown.MatchString(msg)
}

// status returns the lines for a new status. had is false for the first one.
func (e *events) status(prev, cur recorder.Status, had bool) []logLine {
	var out []logLine
	info := func(msg string) { out = append(out, logLine{6, msg}) }

	if !had || cur.State != prev.State {
		// "Stopped" only once ffmpeg is done: Stopping still finalizes the file.
		if e.recording && cur.State != recorder.Recording && cur.State != recorder.Stopping {
			info("Recording stopped")
			e.recording = false
		}
		switch cur.State {
		case recorder.Recording:
			if !e.recording {
				info("Recording started")
				e.recording = true
			}
		case recorder.Waiting:
			info("Recorder waiting for the CRD session (X display)")
		case recorder.Restarting:
			if e.planned {
				info("Recorder restarting for the new recording (systemd starts it again in a few seconds)")
			} else {
				out = append(out, logLine{4, "Recorder restarting after a failure (systemd starts it again in a few seconds)"})
			}
		case recorder.Stopping:
			info("Recorder stopping; ffmpeg is finalizing the current file")
		case recorder.Stopped:
			if cur.Enabled {
				info("Recorder stopped")
			} else {
				info("Recorder stopped (recording disabled)")
			}
		case recorder.Error:
			msg := "Recorder error"
			if cur.Err != nil {
				msg += ": " + cur.Err.Error()
			}
			out = append(out, logLine{3, msg})
		default:
			info("Recorder state: " + cur.State.String())
		}
	}
	if had && cur.Restarts > prev.Restarts {
		if e.planned {
			info("Recorder restarted by systemd for the new recording")
		} else {
			out = append(out, logLine{4, "Recorder restarted by systemd after a failure"})
		}
		e.planned = false
	}
	return out
}
