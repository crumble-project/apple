package main

import (
	"fmt"
	"strings"
	"testing"
)

func TestCritterMarkupIsDeterministic(t *testing.T) {
	first, err := critterSVGMarkup("agent-seed")
	if err != nil {
		t.Fatal(err)
	}
	second, err := critterSVGMarkup("agent-seed")
	if err != nil {
		t.Fatal(err)
	}
	if first != second {
		t.Fatal("same seed generated different SVG")
	}
	if _, err := critterSVG("agent-seed"); err != nil {
		t.Fatal(err)
	}
}

func TestCritterSeedsAndLegacyAvatars(t *testing.T) {
	if got := agentAvatarSeed(Agent{ID: "a1", Avatar: "critters:violet"}); got != "violet" {
		t.Fatalf("got %q", got)
	}
	if got := agentAvatarSeed(Agent{ID: "a1", Avatar: "sparkles"}); got != "a1" {
		t.Fatalf("legacy got %q", got)
	}
	if got := agentAvatarSeed(Agent{ID: "a1", Avatar: "😀"}); got != "a1" {
		t.Fatalf("emoji got %q", got)
	}
	if got := agentAvatarSeed(Agent{ID: "a1"}); got != "a1" {
		t.Fatalf("empty got %q", got)
	}
}

func TestCritterSVGParsesComplexStyle(t *testing.T) {
	svg, err := critterSVG("parse-check")
	if err != nil || svg == nil {
		t.Fatalf("svg=%v err=%v", svg, err)
	}
	markup, err := critterSVGMarkup("parse-check")
	if err != nil || !strings.HasPrefix(strings.TrimSpace(markup), "<svg") {
		t.Fatalf("markup=%q err=%v", markup, err)
	}
}

func TestCritterCacheIsBounded(t *testing.T) {
	for i := 0; i < critterCacheLimit+12; i++ {
		if _, err := critterSVG(fmt.Sprintf("cache-seed-%d", i)); err != nil {
			t.Fatal(err)
		}
	}
	critterState.Lock()
	defer critterState.Unlock()
	if critterState.order.Len() > critterCacheLimit {
		t.Fatalf("cache len=%d", critterState.order.Len())
	}
}
