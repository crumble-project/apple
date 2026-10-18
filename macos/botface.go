package main

import (
	"hash/fnv"
	"math"
	"time"

	"github.com/egoist/mygo/ui"
)

type botState int

const (
	botIdle botState = iota
	botWorking
	botSleeping
)

// botAvatar shows the agent's bot. Live avatars blink, glance around, and hop while
// working; small ones in lists stay still so they cost nothing to paint.
func botAvatar(c *ui.Context, agent Agent, size float32, state botState, live bool) ui.Element {
	return botAvatarSeed(c, agentAvatarSeed(agent), size, state, live).Label("Avatar for " + agent.Name)
}

func botAvatarSeed(c *ui.Context, seed string, size float32, state botState, live bool) ui.Element {
	body := botBodyFor(seed)
	reduce := c.Preferences().ReduceMotion
	return ui.Box(c).Size(size, size).Shrink(0).Draw(func(p *ui.Painter, r ui.Rect) {
		now := p.Now()
		t := float64(now.UnixMilli())/1000 + body.spec.wander
		if !live || reduce {
			t = body.spec.wander
		}
		hop := float32(0)
		if live && !reduce && state == botWorking {
			hop = float32(math.Abs(math.Sin(t*math.Pi/0.45))) * size * 0.07
			p.AnimationFrame()
		}
		p.Transform(ui.Translation(0, -hop), r.X+r.W/2, r.Y+r.H, func() {
			p.Image(body.bitmap, r, ui.FillBox)
			drawBotFace(p, r, body.spec, state, t, live && !reduce)
		})
	})
}

func drawBotFace(p *ui.Painter, r ui.Rect, spec botSpec, state botState, t float64, live bool) {
	scale := float64(r.W) * botScale
	cx, cy := float64(r.X+r.W/2), float64(r.Y+r.H/2)+spec.faceY*scale
	ink := ui.RGB(22, 18, 28)
	eyeR := spec.eyeR * scale
	gap := spec.eyeGap * scale

	if state == botSleeping {
		for _, side := range []float64{-1, 1} {
			var lid ui.Path
			ex := cx + side*gap
			for i := 0; i <= 12; i++ {
				a := math.Pi * float64(i) / 12
				x, y := float32(ex-eyeR*math.Cos(a)), float32(cy+eyeR*0.35*math.Sin(a))
				if i == 0 {
					lid.MoveTo(x, y)
				} else {
					lid.LineTo(x, y)
				}
			}
			p.StrokePath(&lid, float32(math.Max(1, eyeR*0.35)), ink)
		}
		return
	}

	// Glances change every couple of seconds and ease over 250 ms; blinks come every few.
	look := func(slot int64) (float64, float64) {
		h := fnv.New32a()
		_, _ = h.Write([]byte{byte(slot), byte(slot >> 8), byte(slot >> 16), byte(spec.wander)})
		v := h.Sum32()
		angle := float64(v%360) * math.Pi / 180
		amount := float64(v>>9%100) / 100
		if v>>16%3 == 0 {
			amount = 0
		}
		return math.Cos(angle) * amount, math.Sin(angle) * amount * 0.7
	}
	period := 2.6
	slot := int64(math.Floor(t / period))
	since := t - float64(slot)*period
	lx, ly := look(slot)
	if since < 0.25 {
		px, py := look(slot - 1)
		k := easeInOut(since / 0.25)
		lx, ly = px+(lx-px)*k, py+(ly-py)*k
	}
	if state == botWorking {
		lx, ly = 0, -0.6
	}
	open := 1.0
	blinkPeriod := 4.1
	if phase := math.Mod(t, blinkPeriod); phase < 0.14 {
		open = math.Max(0.08, math.Abs(phase-0.07)/0.07)
	}
	if live {
		switch {
		case since < 0.25 || math.Mod(t, blinkPeriod) < 0.14:
			p.AnimationFrame()
		default:
			next := math.Min(period-since, blinkPeriod-math.Mod(t, blinkPeriod))
			p.After(time.Duration(next * float64(time.Second)))
		}
	}

	shift := eyeR * 0.45
	for _, side := range []float64{-1, 1} {
		ex, ey := cx+side*gap+lx*shift, cy+ly*shift
		p.FillPath(ellipsePath(ex, ey, eyeR*0.82, eyeR*open), ink)
		if open > 0.5 {
			glint := ui.RGBA(255, 255, 255, 0.92)
			p.FillPath(ellipsePath(ex-eyeR*0.28, ey-eyeR*0.34, eyeR*0.26, eyeR*0.26), glint)
			p.FillPath(ellipsePath(ex+eyeR*0.24, ey+eyeR*0.28, eyeR*0.11, eyeR*0.11), ui.RGBA(255, 255, 255, 0.6))
		}
	}
	if spec.mouth {
		my := cy + eyeR*1.9
		if state == botWorking {
			p.FillPath(ellipsePath(cx, my+eyeR*0.2, eyeR*0.38, eyeR*0.48), ink)
			return
		}
		var smile ui.Path
		for i := 0; i <= 12; i++ {
			a := math.Pi * float64(i) / 12
			x, y := float32(cx-eyeR*0.7*math.Cos(a)), float32(my+eyeR*0.45*math.Sin(a))
			if i == 0 {
				smile.MoveTo(x, y)
			} else {
				smile.LineTo(x, y)
			}
		}
		p.StrokePath(&smile, float32(math.Max(1, eyeR*0.3)), ink)
	}
}

func ellipsePath(cx, cy, rx, ry float64) *ui.Path {
	var path ui.Path
	for i := 0; i < 32; i++ {
		a := 2 * math.Pi * float64(i) / 32
		x, y := float32(cx+rx*math.Cos(a)), float32(cy+ry*math.Sin(a))
		if i == 0 {
			path.MoveTo(x, y)
		} else {
			path.LineTo(x, y)
		}
	}
	return path.Close()
}

func easeInOut(t float64) float64 { return t * t * (3 - 2*t) }
