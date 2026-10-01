package journal

import "testing"

func TestParse(t *testing.T) {
	line := `{"__CURSOR":"s=abc;i=1","__REALTIME_TIMESTAMP":"1759240000000000","MESSAGE":"Recording started: :20 at 1600x1200","SYSLOG_IDENTIFIER":"crd-recorder","PRIORITY":"6"}`
	e, cursor, err := parse([]byte(line))
	if err != nil {
		t.Fatal(err)
	}
	if cursor != "s=abc;i=1" || e.Identifier != "crd-recorder" || e.Priority != 6 {
		t.Fatalf("got %+v cursor %q", e, cursor)
	}
	if e.Message != "Recording started: :20 at 1600x1200" || e.Time.Unix() != 1759240000 {
		t.Fatalf("got %+v", e)
	}
}

func TestParseBinaryMessage(t *testing.T) {
	// journald encodes non-UTF-8 values as byte arrays ("ok\xff").
	e, _, err := parse([]byte(`{"__CURSOR":"c","MESSAGE":[111,107,255],"PRIORITY":"3"}`))
	if err != nil {
		t.Fatal(err)
	}
	if e.Message != "ok?" || e.Priority != 3 {
		t.Fatalf("got %+v", e)
	}
}
