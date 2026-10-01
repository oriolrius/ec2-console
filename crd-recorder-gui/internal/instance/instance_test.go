package instance

import (
	"errors"
	"testing"
	"time"
)

func TestSingleInstanceAndActivation(t *testing.T) {
	t.Setenv("XDG_RUNTIME_DIR", t.TempDir())
	first, err := Acquire("test-app")
	if err != nil {
		t.Fatal(err)
	}
	got := make(chan string, 1)
	first.Serve(func(msg string) { got <- msg })

	if _, err := Acquire("test-app"); !errors.Is(err, ErrRunning) {
		t.Fatalf("second Acquire = %v, want ErrRunning", err)
	}
	if err := Send("test-app", "show"); err != nil {
		t.Fatal(err)
	}
	select {
	case msg := <-got:
		if msg != "show" {
			t.Fatalf("msg = %q", msg)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("primary did not receive the message")
	}

	first.Close()
	again, err := Acquire("test-app")
	if err != nil {
		t.Fatalf("Acquire after Close = %v", err)
	}
	again.Close()
}
