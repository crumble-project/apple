package main

import "testing"

func TestBotSpecIsDeterministic(t *testing.T) {
	if botSpecFor("agent-seed") != botSpecFor("agent-seed") {
		t.Fatal("same seed produced different bots")
	}
	body := bakeBotBody(botSpecFor("agent-seed"), 64)
	if body.Bounds().Dx() != 64 || body.NRGBAAt(32, 32).A == 0 {
		t.Fatal("baked body is empty at its center")
	}
}

func TestBotSeedsAndLegacyAvatars(t *testing.T) {
	for avatar, want := range map[string]string{"bot:violet": "violet", "critters:violet": "violet", "sparkles": "a1", "😀": "a1", "": "a1"} {
		if got := agentAvatarSeed(Agent{ID: "a1", Avatar: avatar}); got != want {
			t.Fatalf("avatar %q: got %q, want %q", avatar, got, want)
		}
	}
}

func TestEveryBotShapeHasABody(t *testing.T) {
	for _, shape := range botShapes {
		body := bakeBotBody(botSpec{shape: shape, color: botPalette[0]}, 48)
		if body.NRGBAAt(24, 26).A < 200 {
			t.Fatalf("%s: center not covered", shape)
		}
	}
}
