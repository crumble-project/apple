package main

import (
	"bytes"
	"fmt"
	"image"
	"image/color"
	"image/png"
	"sync"

	"github.com/egoist/mygo/ui"
)

// SF Symbol names used by the app.
const (
	symbolCompose  = "square.and.pencil"
	symbolMemory   = "brain"
	symbolTasks    = "calendar.badge.clock"
	symbolActivity = "waveform.path.ecg"
	symbolApproval = "checkmark.shield"
	symbolPlug     = "powerplug"
	symbolSettings = "gearshape"
	symbolSend     = "arrow.up"
	symbolStop     = "stop.fill"
	symbolReply    = "arrowshape.turn.up.left"
	symbolCompact  = "rectangle.compress.vertical"
	symbolProfile  = "person.crop.circle"
	symbolClose    = "xmark"
	symbolSparkles = "sparkles"
	symbolPlus     = "plus"
)

// symbolScale renders symbols at three pixels per point so they stay sharp on Retina screens.
const symbolScale = 3

var symbolCache sync.Map

type tintedSymbol struct {
	bitmap *ui.Bitmap
	w, h   float32
}

// symbolImage returns the system's SF Symbol tinted with tint, or nil where AppKit has none.
func symbolImage(name string, points float32, tint ui.Color) *tintedSymbol {
	key := fmt.Sprintf("%s/%g/%d,%d,%d,%d", name, points, tint.R, tint.G, tint.B, tint.A)
	if cached, ok := symbolCache.Load(key); ok {
		symbol, _ := cached.(*tintedSymbol)
		return symbol
	}
	var symbol *tintedSymbol
	if data := renderSymbol(name, float64(points*symbolScale)); data != nil {
		if mask, err := png.Decode(bytes.NewReader(data)); err == nil {
			bounds := mask.Bounds()
			out := image.NewNRGBA(bounds)
			for y := bounds.Min.Y; y < bounds.Max.Y; y++ {
				for x := bounds.Min.X; x < bounds.Max.X; x++ {
					_, _, _, alpha := mask.At(x, y).RGBA()
					out.SetNRGBA(x, y, color.NRGBA{tint.R, tint.G, tint.B, uint8(alpha >> 8 * uint32(tint.A) / 255)})
				}
			}
			symbol = &tintedSymbol{bitmap: ui.NewBitmap(out), w: float32(bounds.Dx()) / symbolScale, h: float32(bounds.Dy()) / symbolScale}
		}
	}
	symbolCache.Store(key, symbol)
	return symbol
}

// symbol shows an SF Symbol at points, in tint.
func symbol(c *ui.Context, name string, points float32, tint ui.Color) ui.Element {
	if s := symbolImage(name, points, tint); s != nil {
		return ui.Image(c, s.bitmap).Size(s.w, s.h)
	}
	return ui.Box(c).Size(points, points)
}
