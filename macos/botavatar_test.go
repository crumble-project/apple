package main

import "testing"

func TestBotSpecIsDeterministic(t *testing.T) {
	if botSpecFor("agent-seed") != botSpecFor("agent-seed") {
		t.Fatal("same seed produced different bots")
	}
}

func TestBotSeedsAndLegacyAvatars(t *testing.T) {
	for avatar, want := range map[string]string{"bot:violet": "violet", "critters:violet": "violet", "sparkles": "a1", "😀": "a1", "": "a1"} {
		if got := agentAvatarSeed(Agent{ID: "a1", Avatar: avatar}); got != want {
			t.Fatalf("avatar %q: got %q, want %q", avatar, got, want)
		}
	}
}
