// Package upload finds finished recordings and uploads them, oldest first and
// one at a time, to a Transfer.sh-compatible server.
package upload

import (
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"syscall"
	"time"
)

// Settle is how long a recording must have been left untouched, on top of not
// being open by any process, before it counts as finished.
const Settle = 10 * time.Second

// File is a recording on disk.
type File struct {
	Path    string
	Name    string
	Size    int64
	ModTime time.Time
}

// Skipped is a recording that is not uploaded now, and why.
type Skipped struct {
	File
	Reason string
}

// Reasons for skipping a recording.
const (
	ReasonWriting = "still being written"
	ReasonRecent  = "modified less than 10s ago"
	// A recording killed before ffmpeg wrote anything; Transfer servers
	// reject empty uploads, and there is nothing to keep.
	ReasonEmpty = "empty file"
)

// Pending lists the recordings in dir that are finished and not yet uploaded,
// oldest first, plus the ones skipped because they are still being written.
//
// A recording is finished when no process has it open (ffmpeg keeps the
// current segment open until it has written the trailer and closed it) and it
// has not been modified for Settle. The directory is listed before open files
// are checked: a file that already existed and is not open at the later check
// has been closed for good.
func Pending(dir string, uploaded func(name string, size int64) bool, now time.Time) (ready []File, skipped []Skipped, err error) {
	if resolved, err := filepath.EvalSymlinks(dir); err == nil {
		dir = resolved
	}
	entries, err := os.ReadDir(dir)
	if errors.Is(err, fs.ErrNotExist) {
		return nil, nil, nil // the recorder has not written anything yet
	}
	if err != nil {
		return nil, nil, err
	}
	var candidates []File
	for _, e := range entries {
		if !e.Type().IsRegular() || !strings.HasSuffix(e.Name(), ".mkv") {
			continue
		}
		info, err := e.Info()
		if err != nil {
			continue // removed meanwhile
		}
		if uploaded(e.Name(), info.Size()) {
			continue
		}
		candidates = append(candidates, File{Path: filepath.Join(dir, e.Name()), Name: e.Name(), Size: info.Size(), ModTime: info.ModTime()})
	}
	if len(candidates) == 0 {
		return nil, nil, nil
	}
	open, err := OpenFiles()
	if err != nil {
		return nil, nil, fmt.Errorf("checking open files: %w", err)
	}
	for _, f := range candidates {
		switch {
		case open[f.Path]:
			skipped = append(skipped, Skipped{f, ReasonWriting})
		case now.Sub(f.ModTime) < Settle:
			skipped = append(skipped, Skipped{f, ReasonRecent})
		case f.Size == 0:
			skipped = append(skipped, Skipped{f, ReasonEmpty})
		default:
			ready = append(ready, f)
		}
	}
	sort.Slice(ready, func(i, j int) bool {
		if !ready[i].ModTime.Equal(ready[j].ModTime) {
			return ready[i].ModTime.Before(ready[j].ModTime)
		}
		return ready[i].Name < ready[j].Name
	})
	return ready, skipped, nil
}

// OpenFiles returns the paths that processes have open (/proc/*/fd), except
// this process. Processes that cannot be inspected (other users', or
// non-dumpable ones like ssh-agent) are skipped, except ffmpeg: the recorder
// is the only writer of recordings, so not knowing what an ffmpeg has open is
// an error rather than a guess that a file is finished.
func OpenFiles() (map[string]bool, error) {
	procs, err := os.ReadDir("/proc")
	if err != nil {
		return nil, err
	}
	self := os.Getpid()
	open := map[string]bool{}
	for _, p := range procs {
		pid, err := strconv.Atoi(p.Name())
		if err != nil || pid == self {
			continue
		}
		fdDir := filepath.Join("/proc", p.Name(), "fd")
		fds, err := os.ReadDir(fdDir)
		if err != nil {
			if !gone(err) && isFFmpeg(pid) {
				return nil, fmt.Errorf("cannot see the files ffmpeg (pid %d) has open: %w", pid, err)
			}
			continue
		}
		for _, fd := range fds {
			target, err := os.Readlink(filepath.Join(fdDir, fd.Name()))
			if err != nil {
				if !gone(err) && isFFmpeg(pid) {
					return nil, fmt.Errorf("cannot see the files ffmpeg (pid %d) has open: %w", pid, err)
				}
				continue
			}
			if strings.HasPrefix(target, "/") {
				open[target] = true
			}
		}
	}
	return open, nil
}

func isFFmpeg(pid int) bool {
	comm, err := os.ReadFile(fmt.Sprintf("/proc/%d/comm", pid))
	return err == nil && strings.TrimSpace(string(comm)) == "ffmpeg"
}

// gone reports errors meaning the process or descriptor disappeared meanwhile.
func gone(err error) bool {
	return errors.Is(err, fs.ErrNotExist) || errors.Is(err, syscall.ESRCH)
}

// unchanged reports whether f still has the size and mtime seen when listed.
func unchanged(f File) bool {
	info, err := os.Stat(f.Path)
	return err == nil && info.Size() == f.Size && info.ModTime().Equal(f.ModTime)
}
