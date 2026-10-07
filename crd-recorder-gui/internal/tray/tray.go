// Package tray owns the system-tray icon: its picture and tooltip follow the
// recorder state, a left click opens the main window and a right click shows
// a small menu. All methods must be called on the GTK main thread.
package tray

import (
	"bytes"
	"image"
	"image/png"

	"github.com/gotk3/gotk3/gdk"
	"github.com/gotk3/gotk3/gtk"

	"github.com/oriolrius/ec2-console/crd-recorder-gui/internal/recorder"
)

// Actions are the callbacks behind clicks and menu items.
type Actions struct {
	Open, Toggle, Upload, Quit func()
}

// Tray is the status icon plus its menu.
type Tray struct {
	title   string
	version string
	icon    *statusIcon
	toggle  *gtk.MenuItem
	pix     map[recorder.State]*gdk.Pixbuf
	state   recorder.State
	shown   bool
}

// New creates the tray icon. The tooltip reads "<title> — <state>" with the
// version on a second line.
func New(name, title, version string, a Actions) (*Tray, error) {
	t := &Tray{title: title, version: version, pix: map[recorder.State]*gdk.Pixbuf{}}
	for state, l := range looks {
		pb, err := pixbuf(drawIcon(l))
		if err != nil {
			return nil, err
		}
		t.pix[state] = pb
	}

	menu, err := gtk.MenuNew()
	if err != nil {
		return nil, err
	}
	add := func(label string, fn func()) (*gtk.MenuItem, error) {
		item, err := gtk.MenuItemNewWithLabel(label)
		if err != nil {
			return nil, err
		}
		item.Connect("activate", func() { fn() })
		menu.Append(item)
		return item, nil
	}
	if _, err := add("Open", a.Open); err != nil {
		return nil, err
	}
	if t.toggle, err = add("Start Recording", a.Toggle); err != nil {
		return nil, err
	}
	if _, err := add("Upload Pending Files", a.Upload); err != nil {
		return nil, err
	}
	sep, err := gtk.SeparatorMenuItemNew()
	if err != nil {
		return nil, err
	}
	menu.Append(sep)
	if _, err := add("Quit", a.Quit); err != nil {
		return nil, err
	}
	menu.ShowAll()

	t.icon = newStatusIcon(name, title)
	t.icon.obj.Connect("activate", func() { a.Open() })
	// popup-menu fires on right click; the current event is that click.
	t.icon.obj.Connect("popup-menu", func() { menu.PopupAtPointer(nil) })
	t.SetState(recorder.Unknown)
	return t, nil
}

// SetState updates picture, tooltip and the Start/Stop menu item.
func (t *Tray) SetState(s recorder.State) {
	if t.shown && s == t.state {
		return
	}
	t.state, t.shown = s, true
	t.icon.setPixbuf(t.pix[s])
	t.icon.setTooltip(t.title + " — " + s.String() + "\n" + t.version)
	if s.Active() {
		t.toggle.SetLabel("Stop Recording")
	} else {
		t.toggle.SetLabel("Start Recording")
	}
}

// Embedded reports whether a system tray is showing the icon.
func (t *Tray) Embedded() bool { return t.icon.embedded() }

// pixbuf converts an image through PNG and a PixbufLoader, which copies the
// data into GdkPixbuf-owned memory.
func pixbuf(img image.Image) (*gdk.Pixbuf, error) {
	var buf bytes.Buffer
	if err := png.Encode(&buf, img); err != nil {
		return nil, err
	}
	loader, err := gdk.PixbufLoaderNewWithType("png")
	if err != nil {
		return nil, err
	}
	return loader.WriteAndReturnPixbuf(buf.Bytes())
}
