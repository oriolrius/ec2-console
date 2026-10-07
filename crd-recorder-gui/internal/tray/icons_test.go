package tray

import (
	"testing"

	"github.com/oriolrius/ec2-console/crd-recorder-gui/internal/recorder"
)

func TestIconsTellStatesApart(t *testing.T) {
	center := func(s recorder.State) [4]uint8 {
		c := drawIcon(looks[s]).NRGBAAt(iconSize/2, iconSize/2)
		return [4]uint8{c.R, c.G, c.B, c.A}
	}
	if c := center(recorder.Recording); c != [4]uint8{red.R, red.G, red.B, 255} {
		t.Fatalf("recording centre = %v, want solid red", c)
	}
	if c := center(recorder.Stopped); c[3] != 0 {
		t.Fatalf("stopped centre = %v, want transparent (ring only)", c)
	}
	seen := map[[4]uint8]recorder.State{}
	for _, s := range []recorder.State{recorder.Recording, recorder.Waiting, recorder.Restarting} {
		if other, dup := seen[center(s)]; dup {
			t.Fatalf("%v and %v look the same", s, other)
		}
		seen[center(s)] = s
	}
	for s := range looks {
		if drawIcon(looks[s]).NRGBAAt(0, 0).A != 0 {
			t.Fatalf("%v: corner not transparent", s)
		}
	}
}
