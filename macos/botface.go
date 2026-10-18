package main

import (
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

// botEye and botEyes are an expression's eyes in Bloub's units: width and height against the
// body radius, lean in degrees, and the split between the eyes.
type botEye struct{ width, height, tilt float64 }

type botEyes struct {
	left, right botEye
	split       float64
}

var (
	botNeutral = botEyes{botEye{0.186, 0.412, 0}, botEye{0.186, 0.412, 0}, 15.46}
	botSleepy  = botEyes{botEye{0.2, 0.42 * 0.42, 0}, botEye{0.2, 0.42 * 0.42, 0}, 16}
)

// botPose is one frame of a face: gaze as a fraction of the size, roll in degrees, and the
// lid factor on eye height (1 open, 0.06 shut).
type botPose struct{ gazeX, gazeY, roll, lid float64 }

var botRest = botPose{lid: 1}

const botShutLid = 0.06

// botWorkingPose leans the face aside and sways it, as Hermex's working face does.
func botWorkingPose(t float64) botPose {
	turn := -11 + math.Sin(t*0.48)*8
	tilt := math.Sin(t*0.42)*8 + math.Sin(t*1.1)*1.6
	lid := 1.0
	if math.Mod(t, 1.45) > 1.26 {
		lid = botShutLid
	}
	return botPose{gazeX: turn * 0.0025, gazeY: -tilt * 0.0025, roll: math.Sin(t*0.75) * 4.2, lid: lid}
}

// botBlink shuts the eyes for 180 ms every 3 to 5 seconds, seeded so faces in a list never
// blink together. It returns whether they are shut at t and how long until that changes.
func botBlink(hash uint64, t float64) (bool, float64) {
	const shut = 0.18
	period := 3 + float64(hash%2001)/1000
	phase := float64((hash>>20)%5000) / 1000
	position := math.Mod(t-phase, period)
	if position < 0 {
		position += period
	}
	if position < shut {
		return true, shut - position
	}
	return false, period - position
}

// botAvatar shows the agent's bot. Live avatars blink and sway while working; small ones in
// lists stay still so they cost nothing to paint.
func botAvatar(c *ui.Context, agent Agent, size float32, state botState, live bool) ui.Element {
	return botAvatarSeed(c, agentAvatarSeed(agent), size, state, live).Label("Avatar for " + agent.Name)
}

func botAvatarSeed(c *ui.Context, seed string, size float32, state botState, live bool) ui.Element {
	spec := botSpecFor(seed)
	moving := live && !c.Preferences().ReduceMotion
	return ui.Box(c).Size(size, size).Shrink(0).Draw(func(p *ui.Painter, r ui.Rect) {
		pose, eyes := botRest, botNeutral
		t := float64(p.Now().UnixMilli()) / 1000
		switch {
		case state == botSleeping:
			eyes = botSleepy
		case moving && state == botWorking:
			pose = botWorkingPose(t)
			p.After(time.Second / 15)
		case moving:
			shut, next := botBlink(spec.hash, t)
			if shut {
				pose.lid = botShutLid
			}
			p.After(time.Duration(next * float64(time.Second)))
		}
		drawBot(p, r, spec, eyes, pose)
	})
}

func drawBot(p *ui.Painter, r ui.Rect, spec botSpec, eyes botEyes, pose botPose) {
	draw := func() {
		for _, path := range botBodyPaths(spec.shape, r) {
			p.FillPath(path, spec.color)
		}
		s := float64(r.W)
		lw := s * 0.075 * eyes.left.width / 0.186
		rw := s * 0.075 * eyes.right.width / 0.186
		total := lw + s*0.1*eyes.split/15.46 + rw
		cx := float64(r.X) + s/2 + s*(0.12+pose.gazeX)
		cy := float64(r.Y) + s/2 + s*(-0.08+pose.gazeY)
		for _, eye := range []struct {
			x, w float64
			e    botEye
		}{{cx - total/2 + lw/2, lw, eyes.left}, {cx + total/2 - rw/2, rw, eyes.right}} {
			h := s * 0.22 * eye.e.height / 0.412 * pose.lid
			p.FillPath(capsulePath(eye.x, cy, eye.w, h, -18+eye.e.tilt), spec.eyes)
		}
	}
	if pose.roll == 0 {
		draw()
		return
	}
	p.Transform(ui.Rotation(float32(pose.roll)), r.X+r.W/2, r.Y+r.H/2, draw)
}

// capsulePath is a w×h stadium centered on (cx, cy), turned clockwise by degrees.
func capsulePath(cx, cy, w, h, degrees float64) *ui.Path {
	radius := math.Min(w, h) / 2
	along := math.Max(w, h)/2 - radius
	// Each end cap is a half circle around a center on the long axis.
	type capArc struct{ x, y, from float64 }
	caps := []capArc{{0, -along, math.Pi}, {0, along, 0}}
	if w > h {
		caps = []capArc{{along, 0, -math.Pi / 2}, {-along, 0, math.Pi / 2}}
	}
	sin, cos := math.Sincos(degrees * math.Pi / 180)
	var path ui.Path
	for i, arc := range caps {
		for j := 0; j <= 16; j++ {
			a := arc.from + math.Pi*float64(j)/16
			x, y := arc.x+radius*math.Cos(a), arc.y+radius*math.Sin(a)
			px, py := float32(cx+x*cos-y*sin), float32(cy+x*sin+y*cos)
			if i == 0 && j == 0 {
				path.MoveTo(px, py)
			} else {
				path.LineTo(px, py)
			}
		}
	}
	return path.Close()
}

func ellipsePath(cx, cy, rx, ry float64) *ui.Path {
	var path ui.Path
	for i := 0; i < 64; i++ {
		a := 2 * math.Pi * float64(i) / 64
		x, y := float32(cx+rx*math.Cos(a)), float32(cy+ry*math.Sin(a))
		if i == 0 {
			path.MoveTo(x, y)
		} else {
			path.LineTo(x, y)
		}
	}
	return path.Close()
}
