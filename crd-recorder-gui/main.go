// Command crd-recorder-gui is the desktop controller for crd-recorder.service:
// it shows whether the Chrome Remote Desktop session is being recorded (window
// and tray icon), turns recording on and off through systemd, and uploads
// finished recordings to a Transfer.sh-compatible server. It never records by
// itself; systemd runs the recorder.
package main

import (
	"errors"
	"flag"
	"fmt"
	"log"
	"runtime"

	"github.com/gotk3/gotk3/glib"
	"github.com/gotk3/gotk3/gtk"

	"github.com/oriolrius/ec2-console/crd-recorder-gui/internal/config"
	"github.com/oriolrius/ec2-console/crd-recorder-gui/internal/gui"
	"github.com/oriolrius/ec2-console/crd-recorder-gui/internal/instance"
)

// version is set at build time (-ldflags "-X main.version=...").
var version = "dev"

// GTK must be driven from the main OS thread.
func init() { runtime.LockOSThread() }

func main() {
	hidden := flag.Bool("hidden", false, "start in the system tray without showing the window (autostart)")
	showVersion := flag.Bool("version", false, "print the version and exit")
	flag.Parse()
	if *showVersion {
		fmt.Println(version)
		return
	}

	inst, err := instance.Acquire(config.AppName)
	if errors.Is(err, instance.ErrRunning) {
		// Launched again (dock, menu): bring the running window forward.
		if !*hidden {
			if err := instance.Send(config.AppName, "show"); err != nil {
				log.Fatalf("%s is already running but did not answer: %v", config.AppName, err)
			}
		}
		return
	}
	if err != nil {
		log.Fatalf("single-instance lock: %v", err)
	}
	defer inst.Close()

	dir, err := config.DefaultDir()
	if err != nil {
		log.Fatal(err)
	}
	store, err := config.Open(dir)
	if err != nil {
		log.Fatalf("loading settings: %v", err)
	}

	// gotk3 unrefs objects from Go finalizers, which run on the GC's goroutine;
	// GTK is not thread-safe, so hand every unref to the main loop.
	glib.FinalizerStrategy = func(f glib.Finalizer) { glib.IdleAdd(func() { f() }) }
	glib.SetPrgname(config.AppName) // WM_CLASS; matches StartupWMClass in the .desktop file
	glib.SetApplicationName(gui.AppTitle)
	gtk.Init(nil)

	app, err := gui.NewApp(store, version)
	if err != nil {
		log.Fatal(err)
	}
	inst.Serve(func(msg string) {
		if msg == "show" {
			glib.IdleAdd(app.ShowWindow)
		}
	})
	if !*hidden {
		app.ShowWindow()
	}
	gtk.Main()
}
