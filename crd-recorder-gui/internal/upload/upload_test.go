package upload

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/oriolrius/ec2-console/crd-recorder-gui/internal/config"
)

type memLedger struct {
	mu   sync.Mutex
	done map[string]config.Upload
}

func (l *memLedger) IsUploaded(name string, size int64) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	u, ok := l.done[name]
	return ok && u.Size == size
}

func (l *memLedger) RecordUpload(u config.Upload) error {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.done[u.File] = u
	return nil
}

func writeFile(t *testing.T, dir, name, content string, age time.Duration) string {
	t.Helper()
	path := filepath.Join(dir, name)
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
	mt := time.Now().Add(-age)
	if err := os.Chtimes(path, mt, mt); err != nil {
		t.Fatal(err)
	}
	return path
}

// holdOpen keeps path open in a child process, like ffmpeg with the current
// segment (our own process is deliberately ignored by OpenFiles).
func holdOpen(t *testing.T, path string) {
	t.Helper()
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_APPEND, 0)
	if err != nil {
		t.Fatal(err)
	}
	cmd := exec.Command("sleep", "60")
	cmd.ExtraFiles = []*os.File{f}
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	f.Close()
	t.Cleanup(func() { cmd.Process.Kill(); cmd.Wait() })
}

func TestPending(t *testing.T) {
	dir := t.TempDir()
	writeFile(t, dir, "crd_2026-09-30T10-00-00Z.mkv", "old", time.Hour)
	writeFile(t, dir, "crd_2026-09-30T09-00-00Z.mkv", "older", 2*time.Hour)
	writeFile(t, dir, "crd_2026-09-30T08-00-00Z.mkv", "uploaded", 3*time.Hour)
	holdOpen(t, writeFile(t, dir, "crd_2026-09-30T11-00-00Z.mkv", "active", time.Hour))
	writeFile(t, dir, "crd_2026-09-30T12-00-00Z.mkv", "fresh", 0)
	writeFile(t, dir, "notes.txt", "x", time.Hour)
	writeFile(t, dir, "crd_2026-09-30T07-00-00Z.mkv", "", 4*time.Hour) // killed before any write

	uploaded := func(name string, _ int64) bool { return name == "crd_2026-09-30T08-00-00Z.mkv" }
	ready, skipped, err := Pending(dir, uploaded, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	var names []string
	for _, f := range ready {
		names = append(names, f.Name)
	}
	if got := strings.Join(names, ","); got != "crd_2026-09-30T09-00-00Z.mkv,crd_2026-09-30T10-00-00Z.mkv" {
		t.Fatalf("ready = %s (want oldest first, no active/fresh/uploaded)", got)
	}
	reasons := map[string]string{}
	for _, s := range skipped {
		reasons[s.Name] = s.Reason
	}
	if reasons["crd_2026-09-30T11-00-00Z.mkv"] != ReasonWriting {
		t.Fatalf("open file not skipped as being written: %v", reasons)
	}
	if reasons["crd_2026-09-30T12-00-00Z.mkv"] != ReasonRecent {
		t.Fatalf("fresh file not skipped: %v", reasons)
	}
	if reasons["crd_2026-09-30T07-00-00Z.mkv"] != ReasonEmpty {
		t.Fatalf("empty file not skipped: %v", reasons)
	}
}

func TestRunUploadsOldestFirstAndKeepsFailuresPending(t *testing.T) {
	dir := t.TempDir()
	writeFile(t, dir, "a.mkv", "first", 3*time.Hour)
	writeFile(t, dir, "b.mkv", "second-fails", 2*time.Hour)
	writeFile(t, dir, "c.mkv", "third", time.Hour)

	var mu sync.Mutex
	var order []string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		name := strings.TrimPrefix(r.URL.Path, "/")
		mu.Lock()
		order = append(order, name)
		mu.Unlock()
		if r.Method != http.MethodPut || string(body) == "" {
			http.Error(w, "bad request", http.StatusBadRequest)
			return
		}
		if name == "b.mkv" {
			http.Error(w, "disk full", http.StatusInternalServerError)
			return
		}
		w.Header().Set("X-Url-Delete", "http://"+r.Host+"/del/"+name)
		fmt.Fprintf(w, "http://%s/abc123/%s\n", r.Host, name)
	}))
	defer srv.Close()

	ledger := &memLedger{done: map[string]config.Upload{}}
	var logs []string
	logf := func(format string, args ...any) { logs = append(logs, fmt.Sprintf(format, args...)) }
	sum, err := Run(context.Background(), dir, ledger, NewClient(srv.URL), logf)
	if err != nil {
		t.Fatal(err)
	}
	if got := strings.Join(order, ","); got != "a.mkv,b.mkv,c.mkv" {
		t.Fatalf("upload order = %s", got)
	}
	if sum.Uploaded != 2 || sum.Failed != 1 {
		t.Fatalf("summary = %+v\n%s", sum, strings.Join(logs, "\n"))
	}
	if ledger.IsUploaded("b.mkv", 12) {
		t.Fatal("failed upload recorded as uploaded")
	}
	if u := ledger.done["c.mkv"]; u.URL != srv.URL+"/abc123/c.mkv" || u.DeleteURL == "" || u.Size != 5 {
		t.Fatalf("recorded upload = %+v", u)
	}

	// A second run retries only the failed file.
	order = nil
	sum, _ = Run(context.Background(), dir, ledger, NewClient(srv.URL), logf)
	if got := strings.Join(order, ","); got != "b.mkv" || sum.Failed != 1 {
		t.Fatalf("retry order = %s, summary %+v", got, sum)
	}
}

func TestUploadRejectsNonURLReply(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		io.Copy(io.Discard, r.Body)
		fmt.Fprint(w, "<html>oops</html>")
	}))
	defer srv.Close()
	path := writeFile(t, t.TempDir(), "x.mkv", "data", time.Hour)
	_, err := NewClient(srv.URL).Upload(context.Background(), File{Path: path, Name: "x.mkv", Size: 4})
	if err == nil {
		t.Fatal("HTML reply accepted as URL")
	}
}

func TestUploadAbortsWhenStalled(t *testing.T) {
	release := make(chan struct{})
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		<-release // never read the body: the client's socket buffers fill up
	}))
	defer func() { close(release); srv.Close() }()
	path := filepath.Join(t.TempDir(), "big.mkv")
	if err := os.WriteFile(path, make([]byte, 64<<20), 0o644); err != nil {
		t.Fatal(err)
	}
	c := NewClient(srv.URL)
	c.StallTimeout = time.Second
	start := time.Now()
	_, err := c.Upload(context.Background(), File{Path: path, Name: "big.mkv", Size: 64 << 20})
	if err == nil || !strings.Contains(err.Error(), "no data could be sent") {
		t.Fatalf("err = %v, want stall abort", err)
	}
	if d := time.Since(start); d > 10*time.Second {
		t.Fatalf("abort took %s", d)
	}
}
