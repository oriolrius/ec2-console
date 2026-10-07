package gui

import (
	"reflect"
	"testing"

	"github.com/oriolrius/ec2-console/crd-recorder-gui/internal/recorder"
)

type step struct {
	journal []string // recorder lines seen before this status
	status  recorder.Status
	want    []string
}

func run(t *testing.T, steps []step) {
	t.Helper()
	var e events
	var prev recorder.Status
	for i, s := range steps {
		for _, j := range s.journal {
			e.journalLine(j)
		}
		var got []string
		for _, l := range e.status(prev, s.status, i > 0) {
			got = append(got, l.msg)
		}
		if !reflect.DeepEqual(got, s.want) {
			t.Fatalf("step %d: got %q, want %q", i, got, s.want)
		}
		prev = s.status
	}
}

func TestStopIsLoggedOnceFfmpegIsDone(t *testing.T) {
	run(t, []step{
		{status: recorder.Status{State: recorder.Recording, Enabled: true}, want: []string{"Recording started"}},
		{status: recorder.Status{State: recorder.Stopping}, want: []string{"Recorder stopping; ffmpeg is finalizing the current file"}},
		{status: recorder.Status{State: recorder.Stopped}, want: []string{"Recording stopped", "Recorder stopped (recording disabled)"}},
	})
}

func TestResizeRestartIsNotAFailure(t *testing.T) {
	run(t, []step{
		{status: recorder.Status{State: recorder.Recording, Enabled: true}, want: []string{"Recording started"}},
		{journal: []string{"Resolution changed: 1600x1200 -> 1357x1064; finalizing the recording"},
			status: recorder.Status{State: recorder.Restarting, Enabled: true},
			want:   []string{"Recording stopped", "Recorder restarting for the new recording (systemd starts it again in a few seconds)"}},
		{status: recorder.Status{State: recorder.Recording, Enabled: true, Restarts: 1},
			want: []string{"Recording started", "Recorder restarted by systemd for the new recording"}},
	})
}

func TestCrashRestartIsAFailure(t *testing.T) {
	run(t, []step{
		{status: recorder.Status{State: recorder.Recording, Enabled: true}, want: []string{"Recording started"}},
		{journal: []string{"ffmpeg exited with status 137; systemd will restart the recorder"},
			status: recorder.Status{State: recorder.Restarting, Enabled: true},
			want:   []string{"Recording stopped", "Recorder restarting after a failure (systemd starts it again in a few seconds)"}},
		{status: recorder.Status{State: recorder.Recording, Enabled: true, Restarts: 1},
			want: []string{"Recording started", "Recorder restarted by systemd after a failure"}},
	})
}

func TestX11grabTeardownHidden(t *testing.T) {
	var e events
	for _, l := range []string{
		"[x11grab @ 0x5b939146c100] Cannot get the image data event_error: response_type:0 error_code:8",
		"[x11grab @ 0x5b939146c100] Continuing without shared memory.",
		"[in#0/x11grab @ 0x5b939146c000] Error during demuxing: Permission denied",
		"[in#0/x11grab @ 0x5b939146c000] Error retrieving a packet from demuxer: Permission denied",
	} {
		if e.journalLine(l) {
			t.Errorf("shown: %s", l)
		}
	}
	for _, l := range []string{
		"[libx264 @ 0x55] some real encoder error",
		"Recording stopped",
	} {
		if !e.journalLine(l) {
			t.Errorf("hidden: %s", l)
		}
	}
}
