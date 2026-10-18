package main

import (
	"hash/fnv"
	"strings"

	"github.com/egoist/mygo/ui"
)

// Bot avatars follow Hermex's drawn faces (MIT, see THIRD_PARTY_NOTICES.md): a flat shape in
// one color with two leaning capsule eyes. The seed picks the shape and color.

type botSpec struct {
	shape string
	color ui.Color
	eyes  ui.Color
	hash  uint64
}

var botShapes = []string{"circle", "squircle", "pill", "triangle", "hexagon", "cloud", "drop"}

var botPalette = []string{"#8b5cf6", "#38bdf8", "#14b8a6", "#22c55e", "#f59e0b", "#f97316", "#ef4444", "#ec4899"}

func botSpecFor(seed string) botSpec {
	h := fnv.New64a()
	_, _ = h.Write([]byte(seed))
	sum := h.Sum64()
	body := ui.Hex(botPalette[sum%uint64(len(botPalette))])
	eyes := ui.RGBA(0, 0, 0, 0.85)
	if 0.2126*float64(body.R)+0.7152*float64(body.G)+0.0722*float64(body.B) < 110 {
		eyes = ui.RGBA(255, 255, 255, 0.9)
	}
	return botSpec{shape: botShapes[sum%uint64(len(botShapes))], color: body, eyes: eyes, hash: sum}
}

func agentAvatarSeed(agent Agent) string {
	for _, prefix := range []string{"bot:", "critters:"} {
		if seed := strings.TrimSpace(strings.TrimPrefix(agent.Avatar, prefix)); strings.HasPrefix(agent.Avatar, prefix) && seed != "" {
			return seed
		}
	}
	if strings.TrimSpace(agent.ID) != "" {
		return agent.ID
	}
	return "crumble"
}

// botBodyPaths returns the body's outline in r; a cloud is three overlapping ellipses.
func botBodyPaths(shape string, r ui.Rect) []*ui.Path {
	x, y, w, h := r.X, r.Y, r.W, r.H
	in := ui.Rect{X: x + w*0.08, Y: y + h*0.08, W: w * 0.84, H: h * 0.84}
	midX, midY := x+w/2, y+h/2
	switch shape {
	case "squircle":
		return []*ui.Path{roundedRectPath(in, w*0.28)}
	case "pill":
		pill := ui.Rect{X: in.X, Y: midY - h*0.27, W: in.W, H: h * 0.54}
		return []*ui.Path{roundedRectPath(pill, pill.H/2)}
	case "triangle":
		return []*ui.Path{(&ui.Path{}).MoveTo(midX, in.Y).LineTo(in.X+in.W, in.Y+in.H).LineTo(in.X, in.Y+in.H).Close()}
	case "hexagon":
		return []*ui.Path{(&ui.Path{}).MoveTo(midX, in.Y).LineTo(in.X+in.W, y+h*0.3).LineTo(in.X+in.W, y+h*0.7).
			LineTo(midX, in.Y+in.H).LineTo(in.X, y+h*0.7).LineTo(in.X, y+h*0.3).Close()}
	case "cloud":
		oval := func(ox, oy, ow, oh float32) *ui.Path {
			return ellipsePath(float64(x+w*ox+w*ow/2), float64(y+h*oy+h*oh/2), float64(w*ow/2), float64(h*oh/2))
		}
		return []*ui.Path{oval(0.08, 0.38, 0.48, 0.48), oval(0.28, 0.12, 0.5, 0.64), oval(0.55, 0.35, 0.38, 0.45)}
	case "drop":
		right, left, bottom := in.X+in.W, in.X, in.Y+in.H
		return []*ui.Path{(&ui.Path{}).MoveTo(midX, in.Y).
			CubeTo(midX+w*0.22, y+h*0.2, right, y+h*0.42, right, y+h*0.62).
			CubeTo(right, bottom, left, bottom, left, y+h*0.62).
			CubeTo(left, y+h*0.42, midX-w*0.22, y+h*0.2, midX, in.Y).Close()}
	}
	return []*ui.Path{ellipsePath(float64(midX), float64(midY), float64(in.W/2), float64(in.H/2))}
}

func roundedRectPath(r ui.Rect, radius float32) *ui.Path {
	radius = min(radius, r.W/2, r.H/2)
	k := radius * 0.4477 // cubic handle that draws a quarter circle
	right, bottom := r.X+r.W, r.Y+r.H
	return (&ui.Path{}).MoveTo(r.X+radius, r.Y).LineTo(right-radius, r.Y).
		CubeTo(right-k, r.Y, right, r.Y+k, right, r.Y+radius).LineTo(right, bottom-radius).
		CubeTo(right, bottom-k, right-k, bottom, right-radius, bottom).LineTo(r.X+radius, bottom).
		CubeTo(r.X+k, bottom, r.X, bottom-k, r.X, bottom-radius).LineTo(r.X, r.Y+radius).
		CubeTo(r.X, r.Y+k, r.X+k, r.Y, r.X+radius, r.Y).Close()
}
