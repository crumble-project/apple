package main

import (
	"container/list"
	"hash/fnv"
	"image"
	"image/color"
	"math"
	"math/rand/v2"
	"slices"
	"strings"
	"sync"

	"github.com/egoist/mygo/ui"
	"golang.org/x/image/vector"
)

// Bot avatars are lit, rounded shapes with live faces. The body is baked once per seed:
// its outline is rasterized, a distance field raises it into a bevelled dome, and the
// resulting normals are shaded per pixel. The face is drawn live over it (botface.go).

const (
	botScale     = 0.47 // unit coordinates to the image's size
	botBakeSize  = 192  // pixels; sharp up to 96 points on a Retina screen
	botCacheSize = 96
)

type botPoint struct{ x, y float64 }

type botSpec struct {
	shape  string
	color  [3]float64 // sRGB 0..1
	matte  bool
	mouth  bool
	eyeGap float64 // unit offset of each eye from the face center
	eyeR   float64 // unit eye radius
	faceY  float64 // unit face center
	wander float64 // phase that keeps avatars in a row from moving together
}

var botShapes = []string{"circle", "squircle", "blob", "flower", "clover", "star", "cloud", "pill", "hexagon", "ghost", "drop", "cat", "droid"}

var botPalette = [][3]float64{
	{1.00, 0.42, 0.34}, // coral
	{1.00, 0.62, 0.11}, // tangerine
	{1.00, 0.79, 0.20}, // sunflower
	{0.55, 0.83, 0.27}, // lime
	{0.24, 0.84, 0.64}, // mint
	{0.10, 0.71, 0.77}, // teal
	{0.23, 0.65, 1.00}, // sky
	{0.29, 0.42, 0.97}, // cobalt
	{0.55, 0.36, 0.96}, // violet
	{0.82, 0.39, 0.91}, // orchid
	{1.00, 0.37, 0.64}, // pink
	{0.88, 0.27, 0.48}, // berry
	{0.42, 0.48, 0.56}, // slate
	{0.95, 0.89, 0.77}, // cream
}

func botSpecFor(seed string) botSpec {
	h := fnv.New64a()
	_, _ = h.Write([]byte(seed))
	sum := h.Sum64()
	rng := rand.New(rand.NewPCG(sum, sum^0x9e3779b97f4a7c15))
	spec := botSpec{
		shape:  botShapes[rng.IntN(len(botShapes))],
		color:  botPalette[rng.IntN(len(botPalette))],
		matte:  rng.IntN(3) == 0,
		mouth:  rng.IntN(3) == 0,
		eyeGap: 0.24 + rng.Float64()*0.08,
		eyeR:   0.12 + rng.Float64()*0.035,
		wander: rng.Float64() * 100,
	}
	switch spec.shape {
	case "ghost":
		spec.faceY = -0.16
	case "drop":
		spec.faceY = 0.22
	case "cat":
		spec.faceY = 0.14
	case "droid":
		spec.faceY = 0.12
	case "star", "flower", "clover":
		spec.eyeGap, spec.eyeR = spec.eyeGap*0.85, spec.eyeR*0.85
	case "pill":
		spec.eyeGap *= 1.2
	}
	return spec
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

// botOutline returns the body's polygons in unit coordinates, y down, roughly within [-0.9, 0.9].
func botOutline(shape string) [][]botPoint {
	polar := func(r func(theta float64) float64) []botPoint {
		points := make([]botPoint, 0, 240)
		for i := 0; i < 240; i++ {
			theta := 2 * math.Pi * float64(i) / 240
			radius := r(theta)
			points = append(points, botPoint{radius * math.Cos(theta), radius * math.Sin(theta)})
		}
		return points
	}
	circle := func(cx, cy, r float64) []botPoint {
		points := polar(func(float64) float64 { return r })
		for i := range points {
			points[i].x += cx
			points[i].y += cy
		}
		return points
	}
	roundRect := func(w, h, r float64) []botPoint {
		var points []botPoint
		corners := []botPoint{{w/2 - r, h/2 - r}, {-w/2 + r, h/2 - r}, {-w/2 + r, -h/2 + r}, {w/2 - r, -h/2 + r}}
		for i, corner := range corners {
			for j := 0; j <= 12; j++ {
				a := math.Pi/2*float64(i) + math.Pi/2*float64(j)/12
				points = append(points, botPoint{corner.x + r*math.Cos(a), corner.y + r*math.Sin(a)})
			}
		}
		return points
	}
	switch shape {
	case "squircle":
		return [][]botPoint{polar(func(t float64) float64 {
			c, s := math.Abs(math.Cos(t)), math.Abs(math.Sin(t))
			return 0.82 / math.Pow(math.Pow(c, 4)+math.Pow(s, 4), 0.25)
		})}
	case "blob":
		return [][]botPoint{polar(func(t float64) float64 {
			return 0.8 + 0.06*math.Sin(3*t+0.7) + 0.05*math.Sin(2*t+2.1)
		})}
	case "flower":
		return [][]botPoint{polar(func(t float64) float64 {
			return 0.66 + 0.22*math.Pow(0.5+0.5*math.Cos(6*t), 0.7)
		})}
	case "clover":
		return [][]botPoint{polar(func(t float64) float64 {
			return 0.55 + 0.33*math.Pow(math.Abs(math.Cos(2*t+math.Pi/4)), 0.6)
		})}
	case "star":
		return [][]botPoint{polar(func(t float64) float64 {
			return 0.6 + 0.3*math.Pow(0.5+0.5*math.Cos(5*(t+math.Pi/2)), 1.4)
		})}
	case "cloud":
		return [][]botPoint{circle(-0.42, 0.18, 0.38), circle(0.42, 0.18, 0.38), circle(-0.16, -0.12, 0.42), circle(0.24, -0.2, 0.36), roundRect(1.2, 0.6, 0.28)}
	case "pill":
		return [][]botPoint{roundRect(1.7, 1.05, 0.52)}
	case "hexagon":
		var points []botPoint
		for i := 0; i < 6; i++ {
			center := math.Pi/3*float64(i) - math.Pi/2
			cx, cy := 0.66*math.Cos(center), 0.66*math.Sin(center)
			for j := 0; j <= 10; j++ {
				a := center - math.Pi/6 + math.Pi/3*float64(j)/10
				points = append(points, botPoint{cx + 0.22*math.Cos(a), cy + 0.22*math.Sin(a)})
			}
		}
		return [][]botPoint{points}
	case "ghost":
		var points []botPoint
		for j := 0; j <= 40; j++ {
			a := math.Pi + math.Pi*float64(j)/40
			points = append(points, botPoint{0.72 * math.Cos(a), -0.12 + 0.72*math.Sin(a)})
		}
		for j := 0; j <= 60; j++ {
			x := 0.72 - 1.44*float64(j)/60
			points = append(points, botPoint{x, 0.72 + 0.07*math.Cos(x/0.72*3*math.Pi)})
		}
		return [][]botPoint{points}
	case "drop":
		const r, cy, apex = 0.68, 0.2, -0.92
		d := cy - apex
		alpha := math.Acos(r / d)
		var points []botPoint
		points = append(points, botPoint{0, apex})
		for j := 0; j <= 60; j++ {
			a := -math.Pi/2 + alpha + (2*math.Pi-2*alpha)*float64(j)/60
			points = append(points, botPoint{r * math.Cos(a), cy + r*math.Sin(a)})
		}
		return [][]botPoint{points}
	case "cat":
		// Ears sink well into the head so the union has no seam; a circle rounds each tip.
		ear := func(sign float64) []botPoint {
			return []botPoint{{sign * 0.78, 0.05}, {sign * 0.58, -0.8}, {sign * 0.06, -0.42}}
		}
		return [][]botPoint{circle(0, 0.12, 0.74), ear(-1), ear(1), circle(-0.56, -0.76, 0.1), circle(0.56, -0.76, 0.1)}
	case "droid":
		stick := roundRect(0.1, 0.36, 0.05)
		for i := range stick {
			stick[i].y -= 0.62
		}
		return [][]botPoint{roundRect(1.5, 1.1, 0.3), stick, circle(0, -0.8, 0.13)}
	}
	return [][]botPoint{circle(0, 0, 0.82)}
}

func srgbToLinear(v float64) float64 {
	if v <= 0.04045 {
		return v / 12.92
	}
	return math.Pow((v+0.055)/1.055, 2.4)
}

func linearToSRGB(v float64) float64 {
	v = math.Max(0, math.Min(1, v))
	if v <= 0.0031308 {
		return v * 12.92
	}
	return 1.055*math.Pow(v, 1/2.4) - 0.055
}

// boxBlur blurs a square field in place with three passes, close to a Gaussian.
func boxBlur(field []float64, n, radius int) {
	if radius < 1 {
		return
	}
	tmp := make([]float64, len(field))
	for pass := 0; pass < 3; pass++ {
		for y := 0; y < n; y++ {
			for x := 0; x < n; x++ {
				sum, count := 0.0, 0
				for k := max(0, x-radius); k <= min(n-1, x+radius); k++ {
					sum += field[y*n+k]
					count++
				}
				tmp[y*n+x] = sum / float64(count)
			}
		}
		for y := 0; y < n; y++ {
			for x := 0; x < n; x++ {
				sum, count := 0.0, 0
				for k := max(0, y-radius); k <= min(n-1, y+radius); k++ {
					sum += tmp[k*n+x]
					count++
				}
				field[y*n+x] = sum / float64(count)
			}
		}
	}
}

// distanceInside returns each pixel's Euclidean distance to the nearest outside pixel (Felzenszwalb).
func distanceInside(inside []bool, n int) []float64 {
	const inf = 1e12
	grid := make([]float64, n*n)
	for i, in := range inside {
		if in {
			grid[i] = inf
		}
	}
	line := func(f []float64) []float64 {
		d := make([]float64, len(f))
		v := make([]int, len(f))
		z := make([]float64, len(f)+1)
		k := 0
		z[0], z[1] = -inf, inf
		for q := 1; q < len(f); q++ {
			s := ((f[q] + float64(q*q)) - (f[v[k]] + float64(v[k]*v[k]))) / float64(2*q-2*v[k])
			for s <= z[k] {
				k--
				s = ((f[q] + float64(q*q)) - (f[v[k]] + float64(v[k]*v[k]))) / float64(2*q-2*v[k])
			}
			k++
			v[k], z[k], z[k+1] = q, s, inf
		}
		k = 0
		for q := range f {
			for z[k+1] < float64(q) {
				k++
			}
			d[q] = float64((q-v[k])*(q-v[k])) + f[v[k]]
		}
		return d
	}
	column := make([]float64, n)
	for x := 0; x < n; x++ {
		for y := 0; y < n; y++ {
			column[y] = grid[y*n+x]
		}
		for y, value := range line(column) {
			grid[y*n+x] = value
		}
	}
	for y := 0; y < n; y++ {
		copy(grid[y*n:(y+1)*n], line(grid[y*n:(y+1)*n]))
	}
	for i := range grid {
		grid[i] = math.Sqrt(grid[i])
	}
	return grid
}

// bakeBotBody renders the lit body, with a soft contact shadow, as an n×n image.
func bakeBotBody(spec botSpec, n int) *image.NRGBA {
	scale := float64(n) * botScale
	center := float64(n) / 2
	raster := vector.NewRasterizer(n, n)
	for _, polygon := range botOutline(spec.shape) {
		// The rasterizer sums signed coverage, so overlapping parts must wind the same way.
		if signedArea(polygon) < 0 {
			slices.Reverse(polygon)
		}
		for i, point := range polygon {
			x, y := float32(center+point.x*scale), float32(center+point.y*scale)
			if i == 0 {
				raster.MoveTo(x, y)
			} else {
				raster.LineTo(x, y)
			}
		}
		raster.ClosePath()
	}
	mask := image.NewAlpha(image.Rect(0, 0, n, n))
	raster.Draw(mask, mask.Bounds(), image.Opaque, image.Point{})

	inside := make([]bool, n*n)
	coverage := make([]float64, n*n)
	for i := range inside {
		coverage[i] = float64(mask.Pix[i]) / 255
		inside[i] = coverage[i] >= 0.5
	}
	dist := distanceInside(inside, n)
	maxDist := 1.0
	for _, d := range dist {
		maxDist = math.Max(maxDist, d)
	}
	bevel := math.Max(6, maxDist*0.55)
	height := make([]float64, n*n)
	for i, d := range dist {
		t := math.Min(d/bevel, 1)
		height[i] = bevel*math.Sqrt(1-(1-t)*(1-t)) + 0.2*bevel*math.Min(d/maxDist, 1)
	}
	boxBlur(height, n, n/96+1)

	shadow := append([]float64(nil), coverage...)
	boxBlur(shadow, n, n/40+1)
	shadowOffset := n / 28

	light := normalize3(-0.38, -0.58, 0.72)
	half := normalize3(light[0], light[1], light[2]+1)
	base := [3]float64{srgbToLinear(spec.color[0]), srgbToLinear(spec.color[1]), srgbToLinear(spec.color[2])}
	out := image.NewNRGBA(image.Rect(0, 0, n, n))
	for y := 0; y < n; y++ {
		for x := 0; x < n; x++ {
			i := y*n + x
			var shadowAlpha float64
			if sy := y - shadowOffset; sy >= 0 {
				shadowAlpha = shadow[sy*n+x] * 0.3
			}
			alpha := coverage[i]
			if alpha <= 0 {
				out.SetNRGBA(x, y, color.NRGBA{0, 0, 0, uint8(shadowAlpha * 255)})
				continue
			}
			hx := height[y*n+min(x+1, n-1)] - height[y*n+max(x-1, 0)]
			hy := height[min(y+1, n-1)*n+x] - height[max(y-1, 0)*n+x]
			normal := normalize3(-hx/2, -hy/2, 1)
			diffuse := math.Max(0, dot3(normal, light))
			facing := math.Max(0, dot3(normal, half))
			specular := math.Pow(facing, 60)*0.6 + math.Pow(facing, 10)*0.1
			ambient, gain := 0.34, 0.78
			if spec.matte {
				specular = math.Pow(facing, 12) * 0.08
				ambient, gain = 0.42, 0.68
			}
			rim := math.Pow(1-normal[2], 2.5) * 0.22
			fade := 1.06 - 0.16*float64(y)/float64(n)
			var rgb [3]float64
			for c := range rgb {
				rgb[c] = linearToSRGB(base[c]*(ambient+gain*diffuse)*fade + specular + rim*0.5*(1+base[c]))
			}
			// Edge pixels blend the body over its shadow, so the outline stays antialiased.
			a := alpha + shadowAlpha*(1-alpha)
			mix := func(v float64) uint8 { return uint8(math.Round(v * alpha / a * 255)) }
			out.SetNRGBA(x, y, color.NRGBA{mix(rgb[0]), mix(rgb[1]), mix(rgb[2]), uint8(math.Round(a * 255))})
		}
	}
	return out
}

func signedArea(polygon []botPoint) float64 {
	area := 0.0
	for i, a := range polygon {
		b := polygon[(i+1)%len(polygon)]
		area += a.x*b.y - b.x*a.y
	}
	return area / 2
}

func normalize3(x, y, z float64) [3]float64 {
	l := math.Sqrt(x*x + y*y + z*z)
	return [3]float64{x / l, y / l, z / l}
}

func dot3(a, b [3]float64) float64 { return a[0]*b[0] + a[1]*b[1] + a[2]*b[2] }

type botBody struct {
	seed   string
	spec   botSpec
	bitmap *ui.Bitmap
}

var botBodies = struct {
	sync.Mutex
	values map[string]*list.Element
	order  *list.List
}{values: map[string]*list.Element{}, order: list.New()}

func botBodyFor(seed string) *botBody {
	botBodies.Lock()
	defer botBodies.Unlock()
	if element := botBodies.values[seed]; element != nil {
		botBodies.order.MoveToFront(element)
		return element.Value.(*botBody)
	}
	spec := botSpecFor(seed)
	body := &botBody{seed: seed, spec: spec, bitmap: ui.NewBitmap(bakeBotBody(spec, botBakeSize))}
	botBodies.values[seed] = botBodies.order.PushFront(body)
	for botBodies.order.Len() > botCacheSize {
		oldest := botBodies.order.Back()
		delete(botBodies.values, oldest.Value.(*botBody).seed)
		botBodies.order.Remove(oldest)
	}
	return body
}
