package gui

import (
	"fmt"
	"html"
	"strings"
	"time"

	"github.com/gotk3/gotk3/gdk"
	"github.com/gotk3/gotk3/gtk"
	"github.com/gotk3/gotk3/pango"

	"github.com/oriolrius/ec2-console/crd-recorder-gui/internal/config"
	"github.com/oriolrius/ec2-console/crd-recorder-gui/internal/recorder"
)

const (
	maxLogLines    = 3000
	maxUploadsRows = 50
)

var stateColors = map[recorder.State]string{
	recorder.Recording:  "#e01b24",
	recorder.Waiting:    "#e5a50a",
	recorder.Restarting: "#3584e4",
	recorder.Error:      "#c01c28",
}

// window is the main window. Every method runs on the GTK main thread.
type window struct {
	w            *gtk.Window
	stateLabel   *gtk.Label
	detailLabel  *gtk.Label
	toggleBtn    *gtk.Button
	uploadBtn    *gtk.Button
	pendingLabel *gtk.Label
	uploads      *gtk.ListBox
	uploadRows   []*gtk.ListBoxRow
	logView      *gtk.TextView
	logBuf       *gtk.TextBuffer
	logEnd       *gtk.TextMark
	emailEntry   *gtk.Entry
	urlEntry     *gtk.Entry
	dirLabel     *gtk.Label
}

func must[T any](v T, err error) T {
	if err != nil {
		panic(err) // GTK constructors only fail when out of memory
	}
	return v
}

func newLabel(text string) *gtk.Label {
	l := must(gtk.LabelNew(text))
	l.SetXAlign(0)
	return l
}

func frame(title string, child gtk.IWidget) *gtk.Frame {
	f := must(gtk.FrameNew(title))
	f.Add(child)
	return f
}

func newWindow(a *App) *window {
	v := &window{}
	v.w = must(gtk.WindowNew(gtk.WINDOW_TOPLEVEL))
	v.w.SetTitle(AppTitle)
	v.w.SetDefaultSize(780, 640)
	v.w.SetIconName(config.AppName)
	// Closing hides the window; the app keeps running in the tray.
	v.w.Connect("delete-event", func() bool {
		v.w.Hide()
		return true
	})

	root := must(gtk.BoxNew(gtk.ORIENTATION_VERTICAL, 8))
	root.SetMarginStart(12)
	root.SetMarginEnd(12)
	root.SetMarginTop(12)
	root.SetMarginBottom(12)
	v.w.Add(root)

	// Recording status + the single recording control.
	statusRow := must(gtk.BoxNew(gtk.ORIENTATION_HORIZONTAL, 12))
	v.stateLabel = newLabel("")
	v.toggleBtn = must(gtk.ButtonNewWithLabel("Start recording"))
	v.toggleBtn.Connect("clicked", func() { a.ToggleRecording() })
	statusRow.PackStart(v.stateLabel, true, true, 0)
	statusRow.PackEnd(v.toggleBtn, false, false, 0)
	root.PackStart(statusRow, false, false, 0)
	v.detailLabel = newLabel("")
	v.detailLabel.SetSelectable(true)
	v.detailLabel.SetLineWrap(true)
	root.PackStart(v.detailLabel, false, false, 0)

	// Upload.
	uploadRow := must(gtk.BoxNew(gtk.ORIENTATION_HORIZONTAL, 12))
	v.uploadBtn = must(gtk.ButtonNewWithLabel("Upload"))
	v.uploadBtn.SetTooltipText("Upload finished recordings that were not uploaded yet, oldest first")
	v.uploadBtn.Connect("clicked", func() { a.Upload() })
	v.pendingLabel = newLabel("")
	uploadRow.PackStart(v.uploadBtn, false, false, 0)
	uploadRow.PackStart(v.pendingLabel, true, true, 0)
	root.PackStart(uploadRow, false, false, 0)

	// Uploaded URLs, newest first, each with a Copy button.
	v.uploads = must(gtk.ListBoxNew())
	v.uploads.SetSelectionMode(gtk.SELECTION_NONE)
	upScroll := must(gtk.ScrolledWindowNew(nil, nil))
	upScroll.SetPolicy(gtk.POLICY_NEVER, gtk.POLICY_AUTOMATIC)
	upScroll.SetMinContentHeight(110)
	upScroll.Add(v.uploads)
	root.PackStart(frame("Uploaded recordings", upScroll), false, true, 0)

	// Log.
	v.logView = must(gtk.TextViewNew())
	v.logView.SetEditable(false)
	v.logView.SetCursorVisible(false)
	v.logView.SetMonospace(true)
	v.logView.SetWrapMode(gtk.WRAP_WORD_CHAR)
	v.logBuf = must(v.logView.GetBuffer())
	v.logBuf.CreateTag("error", map[string]interface{}{"foreground": "#c01c28"})
	v.logBuf.CreateTag("warning", map[string]interface{}{"foreground": "#c64600"})
	v.logBuf.CreateTag("dim", map[string]interface{}{"foreground": "#77767b"})
	// Right gravity: text inserted at the end goes before the mark, so the
	// mark always stays at the end and can be scrolled to.
	v.logEnd = v.logBuf.CreateMark("end", v.logBuf.GetEndIter(), false)
	logScroll := must(gtk.ScrolledWindowNew(nil, nil))
	logScroll.SetPolicy(gtk.POLICY_AUTOMATIC, gtk.POLICY_AUTOMATIC)
	logScroll.Add(v.logView)
	root.PackStart(frame("Log", logScroll), true, true, 0)

	// Settings.
	grid := must(gtk.GridNew())
	grid.SetRowSpacing(6)
	grid.SetColumnSpacing(8)
	grid.SetMarginTop(6)
	v.emailEntry = must(gtk.EntryNew())
	v.emailEntry.SetPlaceholderText("you@example.com")
	v.emailEntry.SetHExpand(true)
	v.urlEntry = must(gtk.EntryNew())
	v.urlEntry.SetPlaceholderText(config.DefaultTransferURL)
	save := must(gtk.ButtonNewWithLabel("Save"))
	save.Connect("clicked", func() {
		a.SaveSettings(must(v.emailEntry.GetText()), must(v.urlEntry.GetText()))
	})
	v.dirLabel = newLabel("")
	v.dirLabel.SetSelectable(true)
	grid.Attach(newLabel("Email"), 0, 0, 1, 1)
	grid.Attach(v.emailEntry, 1, 0, 1, 1)
	grid.Attach(newLabel("Transfer URL"), 0, 1, 1, 1)
	grid.Attach(v.urlEntry, 1, 1, 1, 1)
	grid.Attach(save, 2, 1, 1, 1)
	grid.Attach(v.dirLabel, 0, 2, 3, 1)
	settings := must(gtk.ExpanderNew("Settings"))
	settings.Add(grid)
	root.PackStart(settings, false, false, 0)

	// Footer.
	footer := must(gtk.BoxNew(gtk.ORIENTATION_HORIZONTAL, 12))
	hint := newLabel("Closing this window keeps CRD Recorder running in the system tray.")
	hint.SetSensitive(false)
	quit := must(gtk.ButtonNewWithLabel("Quit"))
	quit.SetTooltipText("Exit CRD Recorder (recording itself keeps running under systemd)")
	quit.Connect("clicked", func() { a.Quit() })
	footer.PackStart(hint, true, true, 0)
	footer.PackEnd(quit, false, false, 0)
	root.PackStart(footer, false, false, 0)

	root.ShowAll()
	return v
}

// present shows the window, restoring and raising it if needed.
func (v *window) present() {
	v.w.Show()
	v.w.Deiconify()
	v.w.Present()
}

func (v *window) setStatus(st recorder.Status, toggling bool) {
	color, ok := stateColors[st.State]
	if !ok {
		color = "#77767b"
	}
	v.stateLabel.SetMarkup(fmt.Sprintf(`<span size="x-large" foreground="%s">●</span>  <span size="x-large" weight="bold">%s</span>`,
		color, html.EscapeString(st.State.String())))

	var lines []string
	if st.ActiveState != "" {
		enabled := "recording disabled"
		if st.Enabled {
			enabled = "starts with every CRD session"
		}
		lines = append(lines, fmt.Sprintf("%s: %s · %s · automatic restarts: %d", recorder.Unit, st.ActiveState, enabled, st.Restarts))
	}
	for _, f := range st.Files {
		lines = append(lines, "Writing: "+f)
	}
	if st.Err != nil {
		lines = append(lines, "Error: "+st.Err.Error())
	}
	v.detailLabel.SetText(strings.Join(lines, "\n"))

	if st.State.Active() {
		v.toggleBtn.SetLabel("Stop recording")
	} else {
		v.toggleBtn.SetLabel("Start recording")
	}
	v.toggleBtn.SetSensitive(!toggling)
}

func (v *window) setUploadBusy(busy bool) {
	v.uploadBtn.SetSensitive(!busy)
	if busy {
		v.uploadBtn.SetLabel("Uploading…")
	} else {
		v.uploadBtn.SetLabel("Upload")
	}
}

func (v *window) setPending(ready, writing int, err error) {
	switch {
	case err != nil:
		v.pendingLabel.SetText("Cannot scan recordings: " + err.Error())
	case ready == 0 && writing == 0:
		v.pendingLabel.SetText("No recordings pending upload")
	default:
		v.pendingLabel.SetText(fmt.Sprintf("%d finished recording(s) pending upload · %d being written", ready, writing))
	}
}

func (v *window) setSettings(c config.Config, recordingsDir, configDir string) {
	v.emailEntry.SetText(c.Email)
	v.urlEntry.SetText(c.TransferURL)
	v.dirLabel.SetText(fmt.Sprintf("Recordings: %s   ·   Settings and upload state: %s", recordingsDir, configDir))
}

// setUploads lists uploaded recordings, newest first.
func (v *window) setUploads(ups []config.Upload, copyURL func(config.Upload)) {
	for _, r := range v.uploadRows {
		r.Destroy()
	}
	v.uploadRows = v.uploadRows[:0]
	if len(ups) == 0 {
		row := must(gtk.ListBoxRowNew())
		l := newLabel("Nothing uploaded yet.")
		l.SetSensitive(false)
		row.Add(l)
		v.uploads.Add(row)
		v.uploadRows = append(v.uploadRows, row)
	}
	for _, u := range ups {
		u := u
		row := must(gtk.ListBoxRowNew())
		box := must(gtk.BoxNew(gtk.ORIENTATION_HORIZONTAL, 8))
		box.SetMarginStart(4)
		box.SetMarginEnd(4)
		name := newLabel(u.File)
		name.SetTooltipText("Uploaded " + u.UploadedAt.Local().Format(time.DateTime))
		link := newLabel(u.URL)
		link.SetSelectable(true)
		link.SetEllipsize(pango.ELLIPSIZE_MIDDLE)
		link.SetHExpand(true)
		link.SetTooltipText(u.URL)
		btn := must(gtk.ButtonNewWithLabel("Copy"))
		btn.SetTooltipText("Copy the URL to the clipboard")
		btn.Connect("clicked", func() { copyURL(u) })
		box.PackStart(name, false, false, 0)
		box.PackStart(link, true, true, 0)
		box.PackEnd(btn, false, false, 0)
		row.Add(box)
		v.uploads.Add(row)
		v.uploadRows = append(v.uploadRows, row)
	}
	v.uploads.ShowAll()
}

// appendLog adds one line and keeps the view scrolled to the end.
func (v *window) appendLog(t time.Time, source, msg string, priority int) {
	end := v.logBuf.GetEndIter()
	v.logBuf.InsertWithTagByName(end, t.Local().Format("15:04:05")+" ", "dim")
	line := fmt.Sprintf("%-9s %s\n", "["+source+"]", strings.TrimRight(msg, "\n"))
	end = v.logBuf.GetEndIter()
	switch {
	case priority <= 3:
		v.logBuf.InsertWithTagByName(end, line, "error")
	case priority == 4:
		v.logBuf.InsertWithTagByName(end, line, "warning")
	default:
		v.logBuf.Insert(end, line)
	}
	if n := v.logBuf.GetLineCount(); n > maxLogLines {
		v.logBuf.Delete(v.logBuf.GetStartIter(), v.logBuf.GetIterAtLine(n-maxLogLines))
	}
	v.logView.ScrollToMark(v.logEnd, 0, false, 0, 0)
}

func setClipboard(text string) {
	if cb, err := gtk.ClipboardGet(gdk.SELECTION_CLIPBOARD); err == nil {
		cb.SetText(text)
	}
}
