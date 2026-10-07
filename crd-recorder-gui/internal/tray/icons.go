package tray

import (
	"image"
	"image/color"
	"math"

	"github.com/oriolrius/ec2-console/crd-recorder-gui/internal/recorder"
)

// iconSize is the drawn size; GtkStatusIcon scales it down to the panel.
const iconSize = 64

// look is how a state is drawn: a filled disk and/or a ring.
type look struct {
	fill color.NRGBA // zero = no fill
	ring color.NRGBA // zero = no ring
}

var (
	red   = color.NRGBA{0xe0, 0x1b, 0x24, 0xff}
	amber = color.NRGBA{0xf5, 0xc2, 0x11, 0xff}
	blue  = color.NRGBA{0x35, 0x84, 0xe4, 0xff}
	grey  = color.NRGBA{0x9a, 0x99, 0x96, 0xff}
	white = color.NRGBA{0xff, 0xff, 0xff, 0xff}
)

// looks: red dot = recording, grey ring = not recording; waiting, restarting
// and error get their own colour/shape.
var looks = map[recorder.State]look{
	recorder.Recording:  {fill: red, ring: white},
	recorder.Waiting:    {fill: amber},
	recorder.Restarting: {fill: blue},
	recorder.Stopping:   {ring: grey},
	recorder.Stopped:    {ring: grey},
	recorder.Error:      {ring: red},
	recorder.Unknown:    {ring: grey},
}

// drawIcon renders a state's look.
func drawIcon(l look) *image.NRGBA {
	img := image.NewNRGBA(image.Rect(0, 0, iconSize, iconSize))
	c := float64(iconSize) / 2
	outer := c - 2
	ringWidth := float64(iconSize) / 8
	for y := range iconSize {
		for x := range iconSize {
			d := math.Hypot(float64(x)+0.5-c, float64(y)+0.5-c)
			var px color.NRGBA
			if l.fill.A != 0 {
				px = over(px, l.fill, coverage(outer-ringWidth*boolf(l.ring.A != 0)/2, d))
			}
			if l.ring.A != 0 {
				px = over(px, l.ring, coverage(outer, d)-coverage(outer-ringWidth, d))
			}
			img.SetNRGBA(x, y, px)
		}
	}
	return img
}

// coverage is the anti-aliased share of a pixel at distance d inside radius r.
func coverage(r, d float64) float64 {
	return math.Max(0, math.Min(1, r-d+0.5))
}

func boolf(b bool) float64 {
	if b {
		return 1
	}
	return 0
}

// over composites src with alpha a on top of dst.
func over(dst, src color.NRGBA, a float64) color.NRGBA {
	if a <= 0 {
		return dst
	}
	sa := a * float64(src.A) / 255
	da := float64(dst.A) / 255
	oa := sa + da*(1-sa)
	if oa == 0 {
		return color.NRGBA{}
	}
	mix := func(s, d uint8) uint8 {
		return uint8(math.Round((float64(s)*sa + float64(d)*da*(1-sa)) / oa))
	}
	return color.NRGBA{mix(src.R, dst.R), mix(src.G, dst.G), mix(src.B, dst.B), uint8(math.Round(oa * 255))}
}
