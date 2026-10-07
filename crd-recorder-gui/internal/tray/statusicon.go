package tray

// GtkStatusIcon is deprecated since GTK 3.14 but is still the XEmbed tray icon
// that xfce4-panel's systray plugin shows, and it reports plain left clicks
// ("activate"). gotk3 only exposes it behind its gtk_deprecated build tag,
// which no longer compiles with current Go, so the few calls needed are here.

// #cgo pkg-config: gtk+-3.0
// #cgo CFLAGS: -Wno-deprecated-declarations
// #include <stdlib.h>
// #include <gtk/gtk.h>
import "C"

import (
	"unsafe"

	"github.com/gotk3/gotk3/gdk"
	"github.com/gotk3/gotk3/glib"
)

type statusIcon struct {
	ptr *C.GtkStatusIcon
	obj *glib.Object // for signal connections through gotk3
}

func newStatusIcon(name, title string) *statusIcon {
	p := C.gtk_status_icon_new()
	s := &statusIcon{ptr: p, obj: glib.Take(unsafe.Pointer(p))}
	cname, ctitle := C.CString(name), C.CString(title)
	defer C.free(unsafe.Pointer(cname))
	defer C.free(unsafe.Pointer(ctitle))
	C.gtk_status_icon_set_name(p, cname)
	C.gtk_status_icon_set_title(p, ctitle)
	return s
}

func (s *statusIcon) setPixbuf(pb *gdk.Pixbuf) {
	C.gtk_status_icon_set_from_pixbuf(s.ptr, (*C.GdkPixbuf)(unsafe.Pointer(pb.GObject)))
}

func (s *statusIcon) setTooltip(text string) {
	c := C.CString(text)
	defer C.free(unsafe.Pointer(c))
	C.gtk_status_icon_set_tooltip_text(s.ptr, c)
}

func (s *statusIcon) embedded() bool {
	return C.gtk_status_icon_is_embedded(s.ptr) != 0
}
