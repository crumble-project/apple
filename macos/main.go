package main

import (
	"context"
	"github.com/egoist/mygo"
	"github.com/egoist/mygo/ui"
	"github.com/egoist/mygo/ui/markdown"
	"log"
	"os"
	"strings"
)

type app struct {
	dispatch         func(func())
	activeRequests   int
	selectionVersion int
	sending          bool
	streamStatus     string
	notice           string
	newAgent         bool
	editProvider     string
	editThinking     string
	editTemperature  string
	editMaxOutput    string
	providers        []ProviderStatus
	models           []ModelSummary
	editAvatar       string
	avatarChoices    []string
	editFolder       string
	editMCP          map[string]bool
	editDelegates    map[string]bool
	editSkills       []Skill
	toolsDelegate    bool
	navigation       string
	draftRequestID   string
	failedDraft      string
	client           *APIClient
	win              *mygo.Window
	agents           []Agent
	selected         string
	snapshot         *ChatSnapshot
	messages         []Message
	hasMore          bool
	oldestEntryID    string
	loadingOlder     bool
	replyTo          *Message
	failedReplyTo    string
	chatList         ui.ListState
	markdown         markdown.Options
	expanded         map[string]bool
	draft            string
	loading          bool
	errorText        string
	serverURL        string
	token            string
	provider         string
	providerKey      string
	settings         bool
	editor           bool
	editName         string
	editDescription  string
	editInstructions string
	editModel        string
	editEnabled      bool
	streamCancel     context.CancelFunc
	panel            string
	memories         []Memory
	schedules        []Schedule
	executions       []Execution
	approvals        []Approval
	memoryForm       bool
	memoryID         string
	memoryContent    string
	taskForm         bool
	taskID           string
	taskName         string
	taskPrompt       string
	taskCron         string
	taskRunAt        string
	taskTimezone     string
	taskEnabled      bool
	toolsMemory      bool
	delegatesText    string
	skillsText       string
	mcpServers       []MCPServer
	mcpForm          bool
	mcpID            string
	mcpName          string
	mcpURL           string
	mcpToken         string
	mcpEnabled       bool
}

func main() {
	a := &app{serverURL: "http://127.0.0.1:7337", provider: "melious"}
	mygo.App.WhenReady(func() {
		if raw, err := mygo.Secrets.Service("dev.crumble.desktop").Get("server-url"); err == nil && len(raw) > 0 {
			a.serverURL = string(raw)
		}
		if raw, err := mygo.Secrets.Service("dev.crumble.desktop").Get("server-token"); err == nil {
			a.token = string(raw)
		}
		if envURL := strings.TrimSpace(os.Getenv("CRUMBLE_URL")); envURL != "" {
			a.serverURL = strings.TrimRight(envURL, "/")
		}
		if envToken := os.Getenv("CRUMBLE_TOKEN"); envToken != "" {
			a.token = envToken
		}
		a.client = NewAPIClient(a.serverURL, a.token)
		a.win = mygo.NewWindow(mygo.WindowOptions{Title: "Crumble", Width: 1120, Height: 760, MinWidth: 860, MinHeight: 560, StateKey: "main", TitleBarStyle: mygo.TitleBarHiddenInset, TitleBarHeight: 52, Vibrancy: mygo.VibrancySidebar, Content: ui.View(a.view)})
		a.win.OnClosed(func() { a.cancelStream() })
		a.refresh()
	})
	if err := mygo.App.Run(); err != nil {
		log.Fatal(err)
	}
}
