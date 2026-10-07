package config

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestOpenCreatesDefaults(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "app")
	s, err := Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	if got := s.Config().TransferURL; got != DefaultTransferURL {
		t.Fatalf("TransferURL = %q, want default", got)
	}
	b, err := os.ReadFile(filepath.Join(dir, "config.json"))
	if err != nil {
		t.Fatalf("config.json not written on first use: %v", err)
	}
	if !strings.Contains(string(b), DefaultTransferURL) {
		t.Fatalf("config.json = %s", b)
	}
	if fi, _ := os.Stat(filepath.Join(dir, "config.json")); fi.Mode().Perm() != 0o600 {
		t.Fatalf("config.json mode = %v, want 0600", fi.Mode().Perm())
	}
}

func TestSaveConfigValidatesAndPersists(t *testing.T) {
	dir := t.TempDir()
	s, _ := Open(dir)
	if err := s.SaveConfig(Config{TransferURL: "ftp://nope"}); err == nil {
		t.Fatal("ftp URL accepted")
	}
	if err := s.SaveConfig(Config{Email: "not-an-email"}); err == nil {
		t.Fatal("bad email accepted")
	}
	if err := s.SaveConfig(Config{Email: " someone@example.com ", TransferURL: "https://transfer.example.com/ "}); err != nil {
		t.Fatal(err)
	}
	s2, err := Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	c := s2.Config()
	if c.Email != "someone@example.com" || c.TransferURL != "https://transfer.example.com" {
		t.Fatalf("reloaded config = %+v", c)
	}
}

func TestRecordUploadRoundTrip(t *testing.T) {
	dir := t.TempDir()
	s, _ := Open(dir)
	older := Upload{File: "a.mkv", Status: StatusUploaded, URL: "https://x/1/a.mkv", Size: 10, UploadedAt: time.Now().Add(-time.Hour)}
	newer := Upload{File: "b.mkv", Status: StatusUploaded, URL: "https://x/2/b.mkv", Size: 20, UploadedAt: time.Now()}
	for _, u := range []Upload{older, newer} {
		if err := s.RecordUpload(u); err != nil {
			t.Fatal(err)
		}
	}
	s2, _ := Open(dir)
	if !s2.IsUploaded("a.mkv", 10) || !s2.IsUploaded("b.mkv", 20) || s2.IsUploaded("c.mkv", 0) {
		t.Fatal("IsUploaded wrong after reload")
	}
	if s2.IsUploaded("a.mkv", 11) {
		t.Fatal("a different file under an uploaded name counts as uploaded")
	}
	got := s2.Uploads(0)
	if len(got) != 2 || got[0].File != "b.mkv" {
		t.Fatalf("Uploads = %+v, want newest first", got)
	}
	if s2.state.LastUploaded != "b.mkv" {
		t.Fatalf("LastUploaded = %q", s2.state.LastUploaded)
	}
}

func TestRecordUploadFailureKeepsFilePending(t *testing.T) {
	dir := t.TempDir()
	s, _ := Open(dir)
	// A directory where state.json should be makes the rename fail.
	if err := os.Mkdir(filepath.Join(dir, "state.json"), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := s.RecordUpload(Upload{File: "a.mkv", Status: StatusUploaded}); err == nil {
		t.Fatal("expected write error")
	}
	if s.IsUploaded("a.mkv", 0) {
		t.Fatal("file marked uploaded although the state was not saved")
	}
}

func TestCorruptConfigFallsBackToDefaults(t *testing.T) {
	dir := t.TempDir()
	// Valid JSON, wrong type: decoding fails half-way through.
	if err := os.WriteFile(filepath.Join(dir, "config.json"), []byte(`{"email":"a@b.c","transfer_url":123}`), 0o600); err != nil {
		t.Fatal(err)
	}
	s, err := Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	if c := s.Config(); c.Email != "" || c.TransferURL != DefaultTransferURL {
		t.Fatalf("config = %+v, want pure defaults", c)
	}
}

func TestCorruptStateMovedAside(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "state.json"), []byte("{nope"), 0o600); err != nil {
		t.Fatal(err)
	}
	s, err := Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	if len(s.Warnings()) != 1 {
		t.Fatalf("warnings = %v", s.Warnings())
	}
	if _, err := os.Stat(filepath.Join(dir, "state.json.corrupt")); err != nil {
		t.Fatal("corrupt file not kept aside")
	}
}
