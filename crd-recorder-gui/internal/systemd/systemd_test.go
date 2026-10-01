package systemd

import "testing"

func TestParseShow(t *testing.T) {
	out := "ActiveState=activating\nSubState=auto-restart\nControlGroup=/system.slice/crd-recorder.service\nStatusText=a=b\n"
	p := parseShow(out)
	if p["ActiveState"] != "activating" || p["SubState"] != "auto-restart" || p["ControlGroup"] != "/system.slice/crd-recorder.service" {
		t.Fatalf("got %v", p)
	}
	if p["StatusText"] != "a=b" {
		t.Fatalf("value with '=' split wrongly: %q", p["StatusText"])
	}
}
