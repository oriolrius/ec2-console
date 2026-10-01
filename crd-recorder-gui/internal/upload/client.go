package upload

import (
	"context"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"strings"
	"sync/atomic"
	"time"
)

// Client uploads files to a Transfer.sh-compatible server: `PUT <base>/<name>`
// answers with the file's URL in the body (and a delete URL in X-Url-Delete).
type Client struct {
	BaseURL string
	HTTP    *http.Client
	// StallTimeout aborts an upload when no data could be sent for this long
	// (e.g. a peer that stops reading); waiting for the reply after the last
	// byte is bounded separately by the transport's ResponseHeaderTimeout.
	StallTimeout time.Duration
}

// Result is what the server returned for one upload.
type Result struct {
	URL       string
	DeleteURL string
}

// NewClient returns a client with timeouts suited to large uploads: no limit
// on the transfer itself, but bounded connect and server-reply waits.
func NewClient(baseURL string) *Client {
	tr := http.DefaultTransport.(*http.Transport).Clone()
	tr.DialContext = (&net.Dialer{Timeout: 30 * time.Second, KeepAlive: 30 * time.Second}).DialContext
	tr.ResponseHeaderTimeout = 10 * time.Minute
	return &Client{BaseURL: baseURL, HTTP: &http.Client{Transport: tr}, StallTimeout: 2 * time.Minute}
}

// progressReader records when the transport last took data from the file.
type progressReader struct {
	r    io.Reader
	last atomic.Int64 // unix nanoseconds
	eof  atomic.Bool
}

func (p *progressReader) Read(b []byte) (int, error) {
	n, err := p.r.Read(b)
	p.last.Store(time.Now().UnixNano())
	if err == io.EOF {
		p.eof.Store(true)
	}
	return n, err
}

// Upload sends f and returns the URL the server assigned to it.
func (c *Client) Upload(ctx context.Context, f File) (Result, error) {
	fh, err := os.Open(f.Path)
	if err != nil {
		return Result{}, err
	}
	defer fh.Close()
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	sent := &progressReader{r: fh}
	sent.last.Store(time.Now().UnixNano())
	var stalled atomic.Bool
	if c.StallTimeout > 0 {
		go func() {
			tick := time.NewTicker(min(5*time.Second, c.StallTimeout/4))
			defer tick.Stop()
			for {
				select {
				case <-ctx.Done():
					return
				case <-tick.C:
					if !sent.eof.Load() && time.Since(time.Unix(0, sent.last.Load())) > c.StallTimeout {
						stalled.Store(true)
						cancel()
						return
					}
				}
			}
		}()
	}
	target := strings.TrimRight(c.BaseURL, "/") + "/" + url.PathEscape(f.Name)
	req, err := http.NewRequestWithContext(ctx, http.MethodPut, target, sent)
	if err != nil {
		return Result{}, err
	}
	req.ContentLength = f.Size
	req.Header.Set("Content-Type", "video/x-matroska")
	resp, err := c.HTTP.Do(req)
	if err != nil {
		if stalled.Load() {
			return Result{}, fmt.Errorf("no data could be sent for %s; upload aborted", c.StallTimeout)
		}
		return Result{}, err
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 64<<10))
	reply := strings.TrimSpace(string(body))
	if resp.StatusCode < 200 || resp.StatusCode > 299 {
		return Result{}, fmt.Errorf("server answered %s: %s", resp.Status, snippet(reply))
	}
	u, err := url.Parse(reply)
	if err != nil || (u.Scheme != "http" && u.Scheme != "https") || u.Host == "" {
		return Result{}, fmt.Errorf("server did not answer with a URL: %q", snippet(reply))
	}
	return Result{URL: reply, DeleteURL: resp.Header.Get("X-Url-Delete")}, nil
}

func snippet(s string) string {
	if len(s) > 200 {
		return s[:200] + "…"
	}
	return s
}
