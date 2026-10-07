// Package gui is the human-facing layer: the main window, the tray icon and
// the glue between them and the recorder, journal and upload packages.
//
// Threading: GTK is only touched on the main thread. Background goroutines
// (status polling, journal, uploads, systemctl calls) hand results over with
// glib.IdleAdd.
package gui

import (
	"context"
	"fmt"
	"path/filepath"
	"slices"
	"sync/atomic"
	"time"

	"github.com/gotk3/gotk3/glib"
	"github.com/gotk3/gotk3/gtk"

	"github.com/oriolrius/ec2-console/crd-recorder-gui/internal/config"
	"github.com/oriolrius/ec2-console/crd-recorder-gui/internal/journal"
	"github.com/oriolrius/ec2-console/crd-recorder-gui/internal/recorder"
	"github.com/oriolrius/ec2-console/crd-recorder-gui/internal/tray"
	"github.com/oriolrius/ec2-console/crd-recorder-gui/internal/upload"
)

// AppTitle is the user-visible name.
const AppTitle = "CRD Recorder"

const (
	pollInterval = 2 * time.Second
	scanEvery    = 5 // pending-files scan every 5 polls (10 s)
)

// App wires the window and tray to the recorder service and the uploader.
type App struct {
	store *config.Store
	win   *window
	tray  *tray.Tray

	ctx    context.Context
	cancel context.CancelFunc
	pollCh chan struct{}

	// main thread only
	status     recorder.Status
	haveStatus bool
	toggling   bool
	events     events

	uploading atomic.Bool
}

// NewApp builds the window and tray and starts the background work. It must
// be called on the GTK main thread after gtk.Init.
func NewApp(store *config.Store, version string) (*App, error) {
	a := &App{store: store, pollCh: make(chan struct{}, 1)}
	a.ctx, a.cancel = context.WithCancel(context.Background())
	gtk.WindowSetDefaultIconName(config.AppName)
	a.win = newWindow(a, version)
	t, err := tray.New(config.AppName, AppTitle, version, tray.Actions{
		Open: a.ShowWindow, Toggle: a.ToggleRecording, Upload: a.Upload, Quit: a.Quit,
	})
	if err != nil {
		return nil, fmt.Errorf("tray icon: %w", err)
	}
	a.tray = t
	a.win.setSettings(store.Config(), a.recordingsDir(), store.Dir())
	a.refreshUploads()
	// The recorder's recent history first, so the log reads in time order.
	history, cursor, err := journal.Backlog(recorder.Unit, 30)
	if err != nil {
		a.win.appendLog(time.Now(), "journal", err.Error(), 4)
	}
	for _, e := range history {
		a.appendJournal(e)
	}
	a.events.planned = false // only live lines announce the next restart
	a.logf("%s %s started", AppTitle, version)
	for _, w := range store.Warnings() {
		a.log(4, "%s", w)
	}
	go a.pollLoop()
	go a.followJournal(cursor)
	// The tray may appear after us (autostart order); tell the user if not.
	glib.TimeoutAdd(15000, func() bool {
		if !a.tray.Embedded() {
			a.log(4, "No system tray found: add the 'Status Tray' plugin to the XFCE panel to see the recording state icon")
		}
		return false
	})
	return a, nil
}

// ShowWindow shows, restores and raises the main window.
func (a *App) ShowWindow() { a.win.present() }

// Quit stops background work (an upload in progress is abandoned and stays
// pending) and leaves the GTK main loop. Recording is not affected.
func (a *App) Quit() {
	a.cancel()
	gtk.MainQuit()
}

// logf logs an app event (safe from any goroutine).
func (a *App) logf(format string, args ...any) { a.log(6, format, args...) }

func (a *App) log(priority int, format string, args ...any) {
	msg, t := fmt.Sprintf(format, args...), time.Now()
	glib.IdleAdd(func() { a.win.appendLog(t, "app", msg, priority) })
}

func (a *App) recordingsDir() string {
	if dir := a.store.Config().RecordingsDir; dir != "" {
		return dir
	}
	return recorder.RecordingsDir()
}

// requestPoll makes the poller refresh now instead of at the next tick.
func (a *App) requestPoll() {
	select {
	case a.pollCh <- struct{}{}:
	default:
	}
}

func (a *App) pollLoop() {
	tick := time.NewTicker(pollInterval)
	defer tick.Stop()
	for n := 0; ; n++ {
		st := recorder.Query()
		glib.IdleAdd(func() { a.applyStatus(st) })
		if n%scanEvery == 0 {
			ready, skipped, err := upload.Pending(a.recordingsDir(), a.store.IsUploaded, time.Now())
			writing := 0
			for _, s := range skipped {
				if s.Reason == upload.ReasonWriting {
					writing++
				}
			}
			glib.IdleAdd(func() { a.win.setPending(len(ready), writing, err) })
		}
		select {
		case <-a.ctx.Done():
			return
		case <-tick.C:
		case <-a.pollCh:
			n = -1 // rescan pending files right away
		}
	}
}

// applyStatus shows a new status and logs what changed (main thread).
func (a *App) applyStatus(st recorder.Status) {
	prev, had := a.status, a.haveStatus
	a.status, a.haveStatus = st, true
	now := time.Now()
	for _, l := range a.events.status(prev, st, had) {
		a.win.appendLog(now, "app", l.msg, l.priority)
	}
	for _, f := range st.Files {
		if !slices.Contains(prev.Files, f) {
			a.logf("Recording file detected: %s", filepath.Base(f))
		}
	}
	a.win.setStatus(st, a.toggling)
	a.tray.SetState(st.State)
}

func (a *App) followJournal(cursor string) {
	ch := make(chan journal.Entry, 256)
	go journal.Follow(a.ctx, recorder.Unit, cursor, ch)
	for {
		select {
		case <-a.ctx.Done():
			return
		case e := <-ch:
			glib.IdleAdd(func() { a.appendJournal(e) })
		}
	}
}

// appendJournal shows a journal entry, unless it is expected x11grab noise
// (main thread).
func (a *App) appendJournal(e journal.Entry) {
	source := e.Identifier
	if source == "crd-recorder" {
		source = "recorder"
		if !a.events.journalLine(e.Message) {
			return
		}
	}
	a.win.appendLog(e.Time, source, e.Message, e.Priority)
}

// ToggleRecording enables or disables crd-recorder.service (main thread).
func (a *App) ToggleRecording() {
	if a.toggling {
		return
	}
	enable := !a.status.State.Active()
	a.toggling = true
	a.win.setStatus(a.status, true)
	go func() {
		var err error
		if enable {
			a.logf("Starting recording: systemctl enable --now %s", recorder.Unit)
			err = recorder.Enable()
		} else {
			a.logf("Stopping recording: systemctl disable --now %s", recorder.Unit)
			err = recorder.Disable()
		}
		if err != nil {
			a.log(3, "%v", err)
		}
		glib.IdleAdd(func() {
			a.toggling = false
			a.win.setStatus(a.status, false)
			a.requestPoll()
		})
	}()
}

// Upload uploads all finished recordings that are still pending (main thread).
// Only one upload run happens at a time.
func (a *App) Upload() {
	if !a.uploading.CompareAndSwap(false, true) {
		a.logf("An upload is already running")
		return
	}
	a.win.setUploadBusy(true)
	dir, cfg := a.recordingsDir(), a.store.Config()
	go func() {
		a.logf("Upload requested: scanning %s", dir)
		sum, err := upload.Run(a.ctx, dir, ledger{a}, upload.NewClient(cfg.TransferURL), a.logf)
		switch {
		case err != nil:
			a.log(3, "Upload stopped: %v", err)
		case sum.Failed > 0:
			a.log(3, "Upload finished: %d uploaded, %d failed (they stay pending), %d skipped", sum.Uploaded, sum.Failed, sum.Skipped)
		case sum.Uploaded > 0:
			a.logf("Upload finished: %d uploaded, %d skipped", sum.Uploaded, sum.Skipped)
		}
		glib.IdleAdd(func() {
			a.win.setUploadBusy(false)
			a.uploading.Store(false)
		})
		a.requestPoll()
	}()
}

// ledger records uploads in the store and refreshes the URL list.
type ledger struct{ a *App }

func (l ledger) IsUploaded(name string, size int64) bool { return l.a.store.IsUploaded(name, size) }

func (l ledger) RecordUpload(u config.Upload) error {
	if err := l.a.store.RecordUpload(u); err != nil {
		return err
	}
	glib.IdleAdd(l.a.refreshUploads)
	return nil
}

func (a *App) refreshUploads() {
	a.win.setUploads(a.store.Uploads(maxUploadsRows), func(u config.Upload) {
		setClipboard(u.URL)
		a.logf("Copied to clipboard: %s", u.URL)
	})
}

// SaveSettings validates and stores the settings form (main thread).
func (a *App) SaveSettings(email, transferURL string) {
	c := a.store.Config()
	c.Email, c.TransferURL = email, transferURL
	if err := a.store.SaveConfig(c); err != nil {
		a.log(3, "Settings not saved: %v", err)
		return
	}
	a.win.setSettings(a.store.Config(), a.recordingsDir(), a.store.Dir())
	a.logf("Settings saved")
}
