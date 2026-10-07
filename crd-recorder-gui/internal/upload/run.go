package upload

import (
	"context"
	"fmt"
	"time"

	"github.com/oriolrius/ec2-console/crd-recorder-gui/internal/config"
)

// Ledger remembers which recordings were uploaded (config.Store implements it).
type Ledger interface {
	IsUploaded(name string, size int64) bool
	RecordUpload(config.Upload) error
}

// Summary counts what a Run did.
type Summary struct {
	Uploaded, Failed, Skipped int
}

// Run uploads every finished, not yet uploaded recording in dir, oldest first,
// one at a time. Each success is recorded in the ledger before the next file
// starts; a failure is logged and the file stays pending for the next run.
// logf receives one human-readable line per event.
func Run(ctx context.Context, dir string, ledger Ledger, client *Client, logf func(format string, args ...any)) (Summary, error) {
	var sum Summary
	ready, skipped, err := Pending(dir, ledger.IsUploaded, time.Now())
	if err != nil {
		return sum, err
	}
	for _, s := range skipped {
		if s.Reason == ReasonWriting {
			logf("File still being written, skipped: %s", s.Name)
		} else {
			logf("Skipped %s: %s", s.Name, s.Reason)
		}
	}
	sum.Skipped = len(skipped)
	if len(ready) == 0 {
		logf("Nothing to upload: no finished recordings pending in %s", dir)
		return sum, nil
	}
	logf("%d finished recording(s) to upload to %s", len(ready), client.BaseURL)
	for _, f := range ready {
		if ctx.Err() != nil {
			return sum, ctx.Err()
		}
		// Re-check just before sending: still closed and unchanged since listed.
		open, err := OpenFiles()
		if err != nil || open[f.Path] || !unchanged(f) {
			logf("File still being written, skipped: %s", f.Name)
			sum.Skipped++
			continue
		}
		logf("Upload started: %s (%s)", f.Name, humanSize(f.Size))
		start := time.Now()
		res, err := client.Upload(ctx, f)
		if err != nil {
			sum.Failed++
			logf("Upload failed: %s: %v", f.Name, err)
			continue
		}
		if !unchanged(f) {
			sum.Failed++
			logf("Upload discarded: %s changed while it was being sent; it stays pending", f.Name)
			continue
		}
		up := config.Upload{File: f.Name, Status: config.StatusUploaded, URL: res.URL, DeleteURL: res.DeleteURL, Size: f.Size, UploadedAt: time.Now().UTC()}
		if err := ledger.RecordUpload(up); err != nil {
			sum.Failed++
			logf("Uploaded %s to %s but could not save that (%v); it stays pending", f.Name, res.URL, err)
			continue
		}
		sum.Uploaded++
		logf("Upload completed: %s in %s", f.Name, time.Since(start).Round(time.Second))
		logf("Returned Transfer URL: %s → %s", f.Name, res.URL)
	}
	return sum, nil
}

func humanSize(n int64) string {
	switch {
	case n >= 1<<30:
		return fmt.Sprintf("%.1f GiB", float64(n)/(1<<30))
	case n >= 1<<20:
		return fmt.Sprintf("%.1f MiB", float64(n)/(1<<20))
	case n >= 1<<10:
		return fmt.Sprintf("%.1f KiB", float64(n)/(1<<10))
	}
	return fmt.Sprintf("%d B", n)
}
