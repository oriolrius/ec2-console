// Package config persists the app's settings and upload state under
// ~/.config/crd-recorder-gui/:
//
//	config.json — what the user sets (email, Transfer URL, ...)
//	state.json  — what the app has done (one entry per uploaded recording)
//
// Both are JSON objects, so new fields can be added without migrations.
package config

import (
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"net/url"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"
)

const (
	AppName            = "crd-recorder-gui"
	DefaultTransferURL = "https://x.joor.net"

	configFile   = "config.json"
	stateFile    = "state.json"
	stateVersion = 1
)

// Config holds the user settings.
type Config struct {
	Email       string `json:"email"`
	TransferURL string `json:"transfer_url"`
	// RecordingsDir overrides where recordings are read from. Empty means the
	// recorder's CRD_RECORDER_DIR (/etc/default/crd-recorder) or ~/recordings.
	RecordingsDir string `json:"recordings_dir,omitempty"`
}

// StatusUploaded marks a recording that reached the Transfer server.
const StatusUploaded = "uploaded"

// Upload is the state of one recording, keyed by its file name.
type Upload struct {
	File       string    `json:"file"`
	Status     string    `json:"status"`
	URL        string    `json:"url"`
	DeleteURL  string    `json:"delete_url,omitempty"`
	Size       int64     `json:"size"`
	UploadedAt time.Time `json:"uploaded_at"`
}

// State is what the app has done so far.
type State struct {
	Version int `json:"version"`
	// LastUploaded is the most recent successful upload (informational; the
	// Uploads map is what decides whether a file is pending).
	LastUploaded string            `json:"last_uploaded,omitempty"`
	Uploads      map[string]Upload `json:"uploads"`
}

// Store gives concurrency-safe access to Config and State and writes every
// change to disk atomically.
type Store struct {
	mu       sync.Mutex
	dir      string
	cfg      Config
	state    State
	warnings []string
}

// DefaultDir is ~/.config/crd-recorder-gui (honouring XDG_CONFIG_HOME).
func DefaultDir() (string, error) {
	base, err := os.UserConfigDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(base, AppName), nil
}

// Open loads config.json and state.json from dir, creating config.json with
// defaults on first use. A file that cannot be parsed is moved aside
// (<name>.corrupt) and replaced by defaults; see Warnings.
func Open(dir string) (*Store, error) {
	s := &Store{
		dir:   dir,
		cfg:   Config{TransferURL: DefaultTransferURL},
		state: State{Version: stateVersion, Uploads: map[string]Upload{}},
	}
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, err
	}
	cfg, state := s.cfg, s.state
	cfgExists, err := s.load(configFile, &cfg)
	if err != nil {
		return nil, err
	}
	if cfgExists {
		s.cfg = cfg
	}
	stateExists, err := s.load(stateFile, &state)
	if err != nil {
		return nil, err
	}
	if stateExists {
		s.state = state
	}
	if s.cfg.TransferURL == "" {
		s.cfg.TransferURL = DefaultTransferURL
	}
	if s.state.Uploads == nil {
		s.state.Uploads = map[string]Upload{}
	}
	s.state.Version = stateVersion
	if !cfgExists {
		if err := writeJSON(filepath.Join(dir, configFile), s.cfg); err != nil {
			return nil, err
		}
	}
	return s, nil
}

// load decodes name into v. It reports exists=false for a missing file and for
// one that could not be parsed (moved aside); v may then be partly filled and
// must be discarded.
func (s *Store) load(name string, v any) (exists bool, err error) {
	path := filepath.Join(s.dir, name)
	b, err := os.ReadFile(path)
	if errors.Is(err, fs.ErrNotExist) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	if err := json.Unmarshal(b, v); err != nil {
		aside := path + ".corrupt"
		if rerr := os.Rename(path, aside); rerr != nil {
			return false, fmt.Errorf("%s is not valid JSON (%v) and could not be moved aside: %w", path, err, rerr)
		}
		s.warnings = append(s.warnings, fmt.Sprintf("%s was not valid JSON (%v); moved to %s and started from defaults", path, err, aside))
		return false, nil
	}
	return true, nil
}

// Dir is the directory holding the files.
func (s *Store) Dir() string { return s.dir }

// Warnings are problems found while opening the store, for the log view.
func (s *Store) Warnings() []string { return s.warnings }

// Config returns a copy of the current settings.
func (s *Store) Config() Config {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.cfg
}

// SaveConfig validates, normalizes and persists new settings.
func (s *Store) SaveConfig(c Config) error {
	c.Email = strings.TrimSpace(c.Email)
	c.TransferURL = strings.TrimRight(strings.TrimSpace(c.TransferURL), "/")
	c.RecordingsDir = strings.TrimSpace(c.RecordingsDir)
	if c.TransferURL == "" {
		c.TransferURL = DefaultTransferURL
	}
	if err := ValidateTransferURL(c.TransferURL); err != nil {
		return err
	}
	if c.Email != "" && !strings.Contains(c.Email, "@") {
		return fmt.Errorf("%q is not an email address", c.Email)
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if err := writeJSON(filepath.Join(s.dir, configFile), c); err != nil {
		return err
	}
	s.cfg = c
	return nil
}

// ValidateTransferURL accepts absolute http(s) URLs.
func ValidateTransferURL(raw string) error {
	u, err := url.Parse(raw)
	if err != nil || (u.Scheme != "http" && u.Scheme != "https") || u.Host == "" {
		return fmt.Errorf("%q is not an http(s) URL", raw)
	}
	return nil
}

// IsUploaded reports whether file, with this size, was uploaded successfully
// before. A different size means a new recording under the same name (e.g.
// after the clock was set back), which must be uploaded again.
func (s *Store) IsUploaded(file string, size int64) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	u := s.state.Uploads[file]
	return u.Status == StatusUploaded && u.Size == size
}

// RecordUpload persists a successful upload. If writing fails the in-memory
// state is left unchanged, so the file stays pending (a later run may upload
// it again, but it is never lost).
func (s *Store) RecordUpload(u Upload) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	next := State{Version: stateVersion, LastUploaded: u.File, Uploads: make(map[string]Upload, len(s.state.Uploads)+1)}
	for k, v := range s.state.Uploads {
		next.Uploads[k] = v
	}
	next.Uploads[u.File] = u
	if err := writeJSON(filepath.Join(s.dir, stateFile), next); err != nil {
		return err
	}
	s.state = next
	return nil
}

// Uploads returns up to n successful uploads, newest first (n <= 0: all).
func (s *Store) Uploads(n int) []Upload {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := make([]Upload, 0, len(s.state.Uploads))
	for _, u := range s.state.Uploads {
		if u.Status == StatusUploaded {
			out = append(out, u)
		}
	}
	sort.Slice(out, func(i, j int) bool {
		if !out[i].UploadedAt.Equal(out[j].UploadedAt) {
			return out[i].UploadedAt.After(out[j].UploadedAt)
		}
		return out[i].File > out[j].File
	})
	if n > 0 && len(out) > n {
		out = out[:n]
	}
	return out
}

// writeJSON replaces path atomically: temp file in the same directory, fsync,
// rename. A crash leaves either the old or the new content, never a mix.
func writeJSON(path string, v any) error {
	b, err := json.MarshalIndent(v, "", "  ")
	if err != nil {
		return err
	}
	tmp, err := os.CreateTemp(filepath.Dir(path), "."+filepath.Base(path)+".*")
	if err != nil {
		return err
	}
	defer os.Remove(tmp.Name()) // no-op after a successful rename
	if _, err := tmp.Write(append(b, '\n')); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Chmod(0o600); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Sync(); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	if err := os.Rename(tmp.Name(), path); err != nil {
		return err
	}
	// Make the rename itself durable.
	dir, err := os.Open(filepath.Dir(path))
	if err != nil {
		return err
	}
	defer dir.Close()
	return dir.Sync()
}
