// Package instance keeps the app single-instance. The first process takes a
// lock and listens on a Unix socket in $XDG_RUNTIME_DIR; later launches (dock
// icon, menu, autostart) send it a message ("show") and exit.
package instance

import (
	"bufio"
	"errors"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"time"
)

// ErrRunning means another instance holds the lock.
var ErrRunning = errors.New("another instance is running")

// Instance is the running primary process.
type Instance struct {
	lock *os.File
	ln   net.Listener
}

func socketPath(name string) (string, error) {
	dir := os.Getenv("XDG_RUNTIME_DIR")
	if dir == "" {
		// Fallback in /tmp: must be ours and private, or another user could
		// hold the lock or answer on the socket.
		dir = filepath.Join(os.TempDir(), fmt.Sprintf("%s-%d", name, os.Getuid()))
		if err := os.Mkdir(dir, 0o700); err != nil && !errors.Is(err, os.ErrExist) {
			return "", err
		}
		fi, err := os.Lstat(dir)
		if err != nil {
			return "", err
		}
		st, ok := fi.Sys().(*syscall.Stat_t)
		if !fi.IsDir() || !ok || int(st.Uid) != os.Getuid() || fi.Mode().Perm() != 0o700 {
			return "", fmt.Errorf("%s is not a private directory owned by us", dir)
		}
	}
	return filepath.Join(dir, name+".sock"), nil
}

// Acquire makes this process the primary instance, or returns ErrRunning.
// The lock (flock) is released by the kernel when the process exits, so a
// crashed instance never blocks the next one.
func Acquire(name string) (*Instance, error) {
	path, err := socketPath(name)
	if err != nil {
		return nil, err
	}
	lock, err := os.OpenFile(path+".lock", os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return nil, err
	}
	if err := syscall.Flock(int(lock.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		lock.Close()
		if errors.Is(err, syscall.EWOULDBLOCK) {
			return nil, ErrRunning
		}
		return nil, err
	}
	_ = os.Remove(path) // left behind by a crashed instance; we hold the lock
	ln, err := net.Listen("unix", path)
	if err != nil {
		lock.Close()
		return nil, err
	}
	return &Instance{lock: lock, ln: ln}, nil
}

// Serve calls onMessage (from a background goroutine) for every message sent
// by Send.
func (i *Instance) Serve(onMessage func(msg string)) {
	go func() {
		for {
			c, err := i.ln.Accept()
			if err != nil {
				return // listener closed
			}
			go func() {
				defer c.Close()
				_ = c.SetReadDeadline(time.Now().Add(2 * time.Second))
				line, _ := bufio.NewReader(c).ReadString('\n')
				if msg := strings.TrimSpace(line); msg != "" {
					onMessage(msg)
				}
			}()
		}
	}()
}

// Close stops listening and releases the lock.
func (i *Instance) Close() {
	i.ln.Close() // also removes the socket file
	i.lock.Close()
}

// Send delivers msg to the primary instance. It retries for a couple of
// seconds, because the primary may still be starting.
func Send(name, msg string) error {
	path, err := socketPath(name)
	if err != nil {
		return err
	}
	for range 20 {
		var c net.Conn
		if c, err = net.DialTimeout("unix", path, time.Second); err == nil {
			defer c.Close()
			_, err = c.Write([]byte(msg + "\n"))
			return err
		}
		time.Sleep(100 * time.Millisecond)
	}
	return err
}
