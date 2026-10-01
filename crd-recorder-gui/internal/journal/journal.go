// Package journal streams a systemd unit's journal (`journalctl -f -o json`).
package journal

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"os/exec"
	"strconv"
	"strings"
	"sync"
	"time"
)

// Entry is one journal line.
type Entry struct {
	Time       time.Time
	Identifier string // SYSLOG_IDENTIFIER: "crd-recorder", "systemd", ...
	Message    string
	Priority   int // 0 emerg ... 7 debug
}

// Follow sends the unit's last `backlog` entries and then every new one to
// out, until ctx is done. If journalctl exits it is restarted after the last
// seen cursor, so nothing is lost or repeated; problems are sent as entries so
// they show up next to the log lines.
func Follow(ctx context.Context, unit string, backlog int, out chan<- Entry) {
	cursor := ""
	for {
		err := follow(ctx, unit, backlog, &cursor, out)
		if ctx.Err() != nil {
			return
		}
		out <- Entry{Time: time.Now(), Identifier: "journalctl", Priority: 4,
			Message: fmt.Sprintf("journal reader stopped (%v); retrying in 5s", err)}
		select {
		case <-ctx.Done():
			return
		case <-time.After(5 * time.Second):
		}
	}
}

func follow(ctx context.Context, unit string, backlog int, cursor *string, out chan<- Entry) error {
	args := []string{"-u", unit, "-f", "-o", "json", "--no-pager"}
	if *cursor != "" {
		args = append(args, "--after-cursor", *cursor)
	} else {
		args = append(args, "-n", strconv.Itoa(backlog))
	}
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	cmd := exec.CommandContext(ctx, "journalctl", args...)
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return err
	}
	stderr, err := cmd.StderrPipe()
	if err != nil {
		return err
	}
	if err := cmd.Start(); err != nil {
		return err
	}
	// journalctl explains permission problems on stderr ("insufficient permissions").
	var wg sync.WaitGroup
	wg.Add(1)
	go func() {
		defer wg.Done()
		sc := bufio.NewScanner(stderr)
		for sc.Scan() {
			if line := strings.TrimSpace(sc.Text()); line != "" {
				out <- Entry{Time: time.Now(), Identifier: "journalctl", Message: line, Priority: 4}
			}
		}
	}()
	sc := bufio.NewScanner(stdout)
	sc.Buffer(make([]byte, 64*1024), 1024*1024)
	for sc.Scan() {
		e, c, err := parse(sc.Bytes())
		if err != nil {
			continue
		}
		*cursor = c
		out <- e
	}
	if err := sc.Err(); err != nil {
		cancel() // stop journalctl, or it would block on the full pipe
	}
	wg.Wait() // read all of stderr before Wait closes the pipe
	return cmd.Wait()
}

type rawEntry struct {
	Cursor     string          `json:"__CURSOR"`
	Realtime   string          `json:"__REALTIME_TIMESTAMP"`
	Message    json.RawMessage `json:"MESSAGE"`
	Identifier json.RawMessage `json:"SYSLOG_IDENTIFIER"`
	Priority   string          `json:"PRIORITY"`
}

func parse(line []byte) (Entry, string, error) {
	var r rawEntry
	if err := json.Unmarshal(line, &r); err != nil {
		return Entry{}, "", err
	}
	e := Entry{Message: field(r.Message), Identifier: field(r.Identifier), Priority: 6}
	if usec, err := strconv.ParseInt(r.Realtime, 10, 64); err == nil {
		e.Time = time.UnixMicro(usec)
	}
	if p, err := strconv.Atoi(r.Priority); err == nil {
		e.Priority = p
	}
	return e, r.Cursor, nil
}

// field decodes a journal field: a string, or an array of bytes when the value
// is not valid UTF-8 (ffmpeg output can contain control characters).
func field(raw json.RawMessage) string {
	if len(raw) == 0 || string(raw) == "null" {
		return ""
	}
	var s string
	if json.Unmarshal(raw, &s) == nil {
		return s
	}
	var b []byte
	var ints []int
	if json.Unmarshal(raw, &ints) == nil {
		for _, i := range ints {
			b = append(b, byte(i))
		}
		return strings.ToValidUTF8(string(b), "?")
	}
	return string(raw)
}
