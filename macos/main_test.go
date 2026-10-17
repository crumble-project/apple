package main

import (
	"github.com/egoist/mygo/ui"
	"testing"
)

func TestViewRendersEmptyState(t *testing.T) {
	a := &app{}
	tt := ui.NewTester(a.view, 1120, 760)
	if !tt.HasText("A little help, always here.") {
		t.Fatalf("texts=%q", tt.Texts())
	}
	if !tt.HasText("No agents yet") {
		t.Fatalf("texts=%q", tt.Texts())
	}
}
