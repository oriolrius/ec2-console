package recorder

import (
	"os"
	"path/filepath"
	"testing"
)

func TestDerive(t *testing.T) {
	cases := []struct {
		active, sub string
		ffmpeg      bool
		want        State
	}{
		{"active", "running", true, Recording},
		{"active", "running", false, Waiting},
		{"activating", "auto-restart", false, Restarting},
		{"activating", "start", false, Waiting},
		{"deactivating", "stop-sigterm", true, Stopping},
		{"inactive", "dead", false, Stopped},
		{"failed", "failed", false, Error},
		{"", "", false, Unknown},
	}
	for _, c := range cases {
		if got := derive(c.active, c.sub, c.ffmpeg); got != c.want {
			t.Errorf("derive(%q, %q, %v) = %v, want %v", c.active, c.sub, c.ffmpeg, got, c.want)
		}
	}
}

func TestEnvFileValue(t *testing.T) {
	path := filepath.Join(t.TempDir(), "crd-recorder")
	content := "# comment\nCRD_RECORDER_FPS=1\nCRD_RECORDER_DIR=\"/data/recordings\"\n"
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
	if got := envFileValue(path, "CRD_RECORDER_DIR"); got != "/data/recordings" {
		t.Fatalf("got %q", got)
	}
	if got := envFileValue(path, "MISSING"); got != "" {
		t.Fatalf("got %q", got)
	}
	if got := envFileValue(filepath.Join(t.TempDir(), "none"), "CRD_RECORDER_DIR"); got != "" {
		t.Fatalf("got %q", got)
	}
}
