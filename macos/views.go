package main

import (
	"encoding/json"
	"fmt"
	"strings"
	"time"

	"github.com/egoist/mygo/plugins/glass"
	"github.com/egoist/mygo/ui"
	"github.com/egoist/mygo/ui/markdown"
)

const (
	titleBarHeight = 52
	sidebarWidth   = 240
	composerSpace  = 72
)

func contentText(value any) string {
	switch v := value.(type) {
	case string:
		return v
	case []any:
		var parts []string
		for _, item := range v {
			if object, ok := item.(map[string]any); ok {
				if text, ok := object["text"].(string); ok {
					parts = append(parts, text)
				}
			}
		}
		if len(parts) > 0 {
			return strings.Join(parts, "")
		}
	case map[string]any:
		if text, ok := v["text"].(string); ok {
			return text
		}
	}
	if value == nil {
		return ""
	}
	encoded, _ := json.Marshal(value)
	return string(encoded)
}

// iconButton is a borderless toolbar button that shows a face only while hovered, as AppKit's.
func iconButton(c *ui.Context, key string, name string, label string) ui.Element {
	t := c.Theme()
	button := ui.ButtonBase(c.Key(key)).Size(30, 28).Radius(7).Center().TextColor(t.TextMuted).Label(label).Tooltip(label)
	if button.Hovered() {
		button.Background(t.SurfaceHover)
	}
	button.Children(func() { symbol(c, name, 14, t.TextMuted) })
	return button
}

func (a *app) selectedAgent() (Agent, bool) {
	for _, agent := range a.agents {
		if agent.ID == a.selected {
			return agent, true
		}
	}
	return Agent{}, false
}

func avatar(c *ui.Context, agent Agent, size float32) {
	if svg, err := critterSVG(agentAvatarSeed(agent)); err == nil {
		ui.Image(c, svg).Size(size, size).Radius(size * 0.28).Label("Avatar for " + agent.Name)
	}
}

func (a *app) view(c *ui.Context) {
	theme := c.Theme()
	vibrant := c.Vibrancy()
	if vibrant {
		c.Root().Background(ui.Transparent)
	}
	if a.notice != "" {
		c.Toast(a.notice)
		a.notice = ""
	}
	ui.Row(c).Fill().AlignItems(ui.Stretch).Children(func() {
		side := ui.Column(c).Width(sidebarWidth).Shrink(0)
		if !vibrant {
			side.Background(theme.Surface)
		}
		side.Children(func() { a.sidebar(c, vibrant) })
		ui.Box(c).Width(1).Background(theme.Border)
		ui.Column(c).Grow(1).MinWidth(0).Background(theme.Background).Children(func() {
			switch {
			case a.settings:
				a.settingsView(c)
			case a.editor:
				a.agentEditorView(c)
			case a.panel != "":
				a.panelView(c, a.panel)
			default:
				a.chatView(c)
			}
		})
	})
	if c.Shortcut(ui.Cmd, ui.KeyN) {
		a.createAgent()
	}
	if c.Shortcut(ui.Cmd, ui.KeyComma) {
		a.openSettings()
	}
}

var workspaceItems = []struct{ id, label, symbol string }{
	{"memory", "Memory", symbolMemory},
	{"tasks", "Tasks", symbolTasks},
	{"activity", "Activity", symbolActivity},
	{"approvals", "Approvals", symbolApproval},
	{"mcp", "Integrations", symbolPlug},
	{"settings", "Settings", symbolSettings},
}

func (a *app) sidebar(c *ui.Context, vibrant bool) {
	theme := c.Theme()
	ui.Row(c).Height(titleBarHeight).Shrink(0).Padding(0, 10).AlignItems(ui.Center).DragWindow().Children(func() {
		ui.Spacer(c)
		if iconButton(c, "new-agent", symbolCompose, "New agent").Clicked() {
			a.createAgent()
		}
	})
	sidebar := ui.Sidebar(c, &a.navigation, func() {
		ui.SidebarSection(c, "Agents", nil, func() {
			for _, agent := range a.agents {
				item := ui.SidebarItem(c.Key(agent.ID), "agent:"+agent.ID, nil, agent.Name).Height(38).Padding(6, 8, 6, 40)
				item.Children(func() {
					if svg, err := critterSVG(agentAvatarSeed(agent)); err == nil {
						ui.Image(c, svg).Absolute().Left(8).Top(6).Size(26, 26).Radius(7).Label("Avatar for " + agent.Name)
					}
					if !agent.Enabled {
						ui.Badge(c, "Paused")
					}
				})
			}
			if len(a.agents) == 0 {
				ui.Text(c, "No agents yet").FontSize(12).TextColor(theme.TextMuted).Padding(6, 10)
			}
		})
		ui.SidebarSection(c, "Workspace", nil, func() {
			for _, item := range workspaceItems {
				tint := theme.Accent
				if a.navigation == item.id {
					tint = theme.TextMuted
				}
				ui.SidebarItem(c.Key(item.id), item.id, nil, item.label).Height(30).Padding(5, 8, 5, 34).Children(func() {
					ui.Row(c).Absolute().Left(8).Top(0).Bottom(0).Width(20).Center().Children(func() {
						symbol(c, item.symbol, 13, tint)
					})
				})
			}
		})
	}).Grow(1).Label("Workspace navigation")
	if vibrant {
		sidebar.Background(ui.Transparent)
	}
	if sidebar.Changed() {
		switch {
		case strings.HasPrefix(a.navigation, "agent:"):
			a.selectAgent(strings.TrimPrefix(a.navigation, "agent:"))
		case a.navigation == "settings":
			a.openSettings()
		default:
			a.openPanel(a.navigation)
		}
	}
	status, color := "Connected", ui.RGB(52, 199, 89)
	switch {
	case a.streamStatus != "":
		status, color = a.streamStatus, theme.Danger
	case a.loading:
		status, color = "Syncing…", theme.TextMuted
	}
	ui.Row(c).Padding(10, 18, 14, 18).Gap(6).AlignItems(ui.Center).Children(func() {
		ui.Box(c).Size(7, 7).Radius(4).Background(color)
		ui.Text(c, status).FontSize(11).TextColor(theme.TextMuted)
	})
}

// chatRow is one row of the chat list: a transcript message or a transient row around it.
type chatRow struct {
	key     string
	kind    string
	message Message
	divider string
}

func (a *app) chatRows() []chatRow {
	var rows []chatRow
	if a.hasMore {
		rows = append(rows, chatRow{key: "older", kind: "older"})
	}
	var last int64
	for _, message := range a.messages {
		if !shownInChat(message) {
			continue
		}
		if message.Timestamp > 0 && message.Timestamp-last > int64(30*time.Minute/time.Millisecond) {
			rows = append(rows, chatRow{key: "time:" + message.ID, kind: "time", divider: timeLabel(time.UnixMilli(message.Timestamp))})
		}
		if message.Timestamp > 0 {
			last = message.Timestamp
		}
		rows = append(rows, chatRow{key: message.ID, kind: "message", message: message})
	}
	if a.snapshot != nil {
		switch {
		case a.snapshot.Partial != "":
			rows = append(rows, chatRow{key: "partial", kind: "partial"})
		case a.snapshot.Status == "running":
			rows = append(rows, chatRow{key: "thinking", kind: "thinking"})
		}
		if a.snapshot.Error != "" {
			rows = append(rows, chatRow{key: "error", kind: "error"})
		}
	}
	return rows
}

// shownInChat keeps the conversation itself: owner and agent text and context events,
// not thinking, tool calls, or tool results.
func shownInChat(message Message) bool {
	switch message.Role {
	case "user", "event":
		return contentText(message.Content) != ""
	case "assistant":
		blocks, ok := message.Blocks.([]any)
		if !ok {
			return contentText(message.Blocks) != ""
		}
		for _, block := range blocks {
			if object, ok := block.(map[string]any); ok && object["type"] == "text" {
				if text, _ := object["text"].(string); strings.TrimSpace(text) != "" {
					return true
				}
			}
		}
	}
	return false
}

func timeLabel(at time.Time) string {
	now := time.Now()
	switch {
	case at.YearDay() == now.YearDay() && at.Year() == now.Year():
		return "Today " + at.Format("15:04")
	case at.Year() == now.Year():
		return at.Format("Mon, 2 Jan 15:04")
	}
	return at.Format("2 Jan 2006 15:04")
}

func (a *app) chatView(c *ui.Context) {
	theme := c.Theme()
	agent, ok := a.selectedAgent()
	if !ok {
		a.welcomeView(c)
		return
	}
	rows := a.chatRows()
	a.chatList.Key = func(i int) any { return rows[i].key }
	a.chatList.FollowEnd = true
	a.chatList.FollowAnimation = &ui.Smooth
	bottom := float32(composerSpace)
	if a.replyTo != nil {
		bottom += 54
	}
	ui.Box(c).Fill().Children(func() {
		ui.List(c, &a.chatList, len(rows), func(i int) {
			a.chatRowView(c, agent, rows[i])
		}).Fill().Padding(titleBarHeight+12, 28, bottom, 28).Gap(10).Justify(ui.End).
			ScrollbarInsets(titleBarHeight, 0, bottom-20, 0)
		if len(rows) == 0 {
			a.emptyChat(c, agent)
		}
		ui.Box(c).Absolute().Top(0).Left(0).Right(0).Height(titleBarHeight + 10).PassThrough().Material(glass.ScrollEdge{})
		ui.Box(c).Absolute().Bottom(0).Left(0).Right(0).Height(bottom).PassThrough().Material(glass.ScrollEdge{Bottom: true})
		a.chatHeader(c, agent)
		if a.errorText != "" {
			ui.Row(c).Absolute().Top(titleBarHeight+6).Left(28).Right(28).Padding(8, 12).Gap(8).Radius(10).
				Material(glass.Glass{Tint: theme.Danger.Alpha(0.25)}).AlignItems(ui.Center).Children(func() {
				ui.Text(c, a.errorText).FontSize(12).Grow(1)
				if iconButton(c, "dismiss-error", symbolClose, "Dismiss").Clicked() {
					a.errorText = ""
				}
			})
		}
		a.composer(c, agent)
	})
}

func (a *app) chatHeader(c *ui.Context, agent Agent) {
	theme := c.Theme()
	ui.Row(c).Absolute().Top(0).Left(0).Right(0).Height(titleBarHeight).Padding(0, 16, 0, 20).Gap(10).AlignItems(ui.Center).DragWindow().Children(func() {
		avatar(c, agent, 28)
		ui.Column(c).Grow(1).MinWidth(0).Children(func() {
			ui.Text(c, agent.Name).FontSize(13).Bold().SingleLine().Ellipsis("…")
			subtitle := agent.Model
			switch {
			case !agent.Enabled:
				subtitle = "Paused"
			case a.snapshot != nil && a.snapshot.Status == "running":
				subtitle = "Working…"
			case agent.Description != "":
				subtitle = agent.Description
			}
			ui.Text(c, subtitle).FontSize(11).TextColor(theme.TextMuted).SingleLine().Ellipsis("…")
		})
		ui.Row(c).Padding(2).Gap(2).Radius(16).Material(glass.Glass{}).Children(func() {
			if iconButton(c, "compact", symbolCompact, "Summarize older context").Disabled(a.loading || len(a.messages) == 0).Clicked() {
				a.compactChat()
			}
			if iconButton(c, "profile", symbolProfile, "Agent profile").Clicked() {
				a.openEditor()
			}
		})
	})
}

func (a *app) emptyChat(c *ui.Context, agent Agent) {
	theme := c.Theme()
	ui.Column(c).Absolute().Top(titleBarHeight).Bottom(composerSpace).Left(0).Right(0).Center().Gap(10).PassThrough().Children(func() {
		if a.snapshot == nil {
			ui.Spinner(c).Label("Opening chat")
			return
		}
		avatar(c, agent, 72)
		ui.Text(c, agent.Name).FontSize(22).Bold()
		detail := agent.Description
		if detail == "" {
			detail = "Send a message to start. Your agent keeps its work and memory between visits."
		}
		ui.Text(c, detail).MaxWidth(420).TextColor(theme.TextMuted).TextAlign(ui.Center)
	})
}

func (a *app) welcomeView(c *ui.Context) {
	theme := c.Theme()
	ui.Box(c).Height(titleBarHeight).Shrink(0).DragWindow()
	ui.Column(c).Grow(1).Center().Padding(32).Gap(12).Children(func() {
		if a.loading {
			ui.Spinner(c).Size(28, 28).Label("Opening your workspace")
			return
		}
		symbol(c, symbolSparkles, 36, theme.Accent)
		ui.Text(c, "A little help, always here.").FontSize(22).Bold()
		ui.Text(c, "Create an agent with a purpose, then give it something to do.").MaxWidth(420).TextColor(theme.TextMuted).TextAlign(ui.Center)
		if ui.PrimaryButton(c, "Create an agent").Clicked() {
			a.createAgent()
		}
		if a.errorText != "" {
			ui.Text(c, a.errorText).FontSize(12).TextColor(theme.Danger).MaxWidth(420).TextAlign(ui.Center)
		}
	})
}

func (a *app) chatRowView(c *ui.Context, agent Agent, row chatRow) {
	theme := c.Theme()
	switch row.kind {
	case "older":
		ui.Row(c).Justify(ui.Center).Padding(4).Children(func() {
			if a.loadingOlder {
				ui.Spinner(c).Label("Loading earlier messages")
			} else if ui.Button(c, "Load earlier messages").Clicked() {
				a.loadOlder()
			}
		})
	case "time":
		ui.Text(c, row.divider).FontSize(11).TextColor(theme.TextMuted).AlignSelf(ui.Center).Padding(6, 0, 2, 0)
	case "partial":
		agentBubble(c).Children(func() {
			markdown.Stream(c, a.snapshot.Partial, &a.markdown)
		})
	case "thinking":
		ui.Row(c).Gap(8).AlignItems(ui.Center).Children(func() {
			ui.Spinner(c).Label("Working")
			ui.Text(c, agent.Name+" is working…").FontSize(12).TextColor(theme.TextMuted)
		})
	case "error":
		ui.Column(c).MaxWidth(560).Gap(8).Padding(12, 14).Radius(12).Background(theme.Danger.Alpha(0.1)).Children(func() {
			ui.Text(c, "The agent couldn’t finish").FontSize(13).Bold()
			ui.Text(c, a.snapshot.Error).FontSize(12).TextColor(theme.Danger).Selectable()
			if ui.Button(c, "Provider settings").AlignSelf(ui.Start).Clicked() {
				a.openSettings()
			}
		})
	default:
		a.messageView(c, row.message)
	}
}

func (a *app) messageView(c *ui.Context, message Message) {
	theme := c.Theme()
	text := contentText(message.Content)
	replyable := message.EntryID != "" && (message.Role == "user" || message.Role == "assistant")
	menu := func(m *ui.Menu) {
		if replyable && m.Item("Reply").Chosen() {
			a.startReply(message)
		}
		if m.Item("Copy").Chosen() {
			c.Services().WriteClipboard(text)
		}
	}
	switch {
	case message.Role == "event":
		label := "Earlier messages summarized"
		if message.Kind == "reset" {
			label = "Context reset"
		}
		open := a.expanded[message.ID]
		ui.Column(c).AlignSelf(ui.Center).MaxWidth(560).Gap(4).Children(func() {
			if ui.Collapsible(c, label, &open, func() {
				ui.Text(c, text).FontSize(12).TextColor(theme.TextMuted).Selectable()
			}).Changed() {
				a.setExpanded(message.ID, open)
			}
		})
	case message.Role == "user":
		row := ui.Row(c).Gap(6).AlignItems(ui.Center)
		hovered := row.Hovered()
		row.Children(func() {
			ui.Spacer(c)
			if hovered && replyable {
				if iconButton(c, "reply", symbolReply, "Reply").Clicked() {
					a.startReply(message)
				}
			}
			ui.Column(c).MaxWidth(520).Gap(4).AlignItems(ui.End).Children(func() {
				owner := message.Origin == nil || message.Origin.Kind == "owner"
				if !owner {
					ui.Text(c, messageLabel(message)).FontSize(11).TextColor(theme.TextMuted).Padding(0, 6)
				}
				a.replyQuote(c, message)
				bubble := ui.Text(c, text).Selectable().FontSize(13).Padding(7, 12).Radius(16)
				if owner {
					bubble.Background(theme.Accent).TextColor(theme.AccentText)
				} else {
					bubble.Background(theme.Surface)
				}
				bubble.ContextMenu(menu)
			})
		})
	case message.Role == "assistant":
		row := ui.Row(c).Gap(6)
		hovered := row.Hovered()
		row.Children(func() {
			agentBubble(c).Selectable().ContextMenu(menu).Children(func() {
				markdown.View(c, text, &a.markdown)
			})
			if hovered && replyable {
				if iconButton(c, "reply", symbolReply, "Reply").Clicked() {
					a.startReply(message)
				}
			}
		})
	}
}

// agentBubble is the gray bubble agent replies sit in, opposite the owner's blue ones.
func agentBubble(c *ui.Context) ui.Element {
	return ui.Column(c).MaxWidth(560).MinWidth(0).Shrink(1).Padding(7, 12).Radius(16).Background(c.Theme().Surface)
}

func (a *app) setExpanded(id string, open bool) {
	if a.expanded == nil {
		a.expanded = map[string]bool{}
	}
	a.expanded[id] = open
}

func (a *app) replyQuote(c *ui.Context, message Message) {
	if message.ReplyTo == "" {
		return
	}
	quoted := message.ReplyPreview
	for _, original := range a.messages {
		if quoted == "" && original.EntryID == message.ReplyTo {
			quoted = contentText(original.Content)
		}
	}
	if quoted == "" {
		return
	}
	theme := c.Theme()
	ui.Row(c).Gap(8).Padding(5, 10).Radius(10).Background(theme.Surface).Children(func() {
		ui.Box(c).Width(2).AlignSelf(ui.Stretch).Radius(1).Background(theme.Accent)
		ui.Text(c, preview(quoted)).FontSize(12).TextColor(theme.TextMuted).MaxLines(2)
	})
}

func (a *app) composer(c *ui.Context, agent Agent) {
	theme := c.Theme()
	if a.snapshot == nil {
		return
	}
	ui.Column(c).Absolute().Left(20).Right(20).Bottom(14).Gap(6).Children(func() {
		if a.replyTo != nil {
			ui.Row(c).Gap(8).AlignItems(ui.Center).Padding(6, 6, 6, 12).Radius(12).Material(glass.Glass{}).Children(func() {
				ui.Box(c).Width(2).Height(28).Radius(1).Background(theme.Accent)
				ui.Column(c).Grow(1).MinWidth(0).Children(func() {
					ui.Text(c, "Replying to "+messageLabel(*a.replyTo)).FontSize(11).Bold().TextColor(theme.Accent)
					ui.Text(c, preview(contentText(a.replyTo.Content))).FontSize(12).TextColor(theme.TextMuted).SingleLine().Ellipsis("…")
				})
				if iconButton(c, "cancel-reply", symbolClose, "Cancel reply").Clicked() {
					a.cancelReply()
				}
			})
		}
		// A pill-shaped field with a hairline border, as Messages draws its composer.
		ui.Row(c).Padding(4, 4, 4, 14).Gap(6).AlignItems(ui.End).Radius(18).MinHeight(36).
			Material(glass.Glass{}).BorderWidth(1).BorderColor(theme.Border).Children(func() {
			input := ui.TextAreaBase(c, &a.draft).Lines(1, 8).Grow(1).Padding(5, 0).FontSize(13).
				Label("Message your agent").Placeholder("Message " + agent.Name).Disabled(a.sending || !agent.Enabled)
			if !agent.Enabled {
				input.Placeholder(agent.Name + " is paused. Enable it in its profile.")
			}
			input.OnTextKey(func(k ui.TextKey) bool {
				if k.Key != ui.KeyEnter || k.Mods != 0 {
					return false
				}
				a.draft = k.Text()
				a.sendMessage()
				k.SetText(a.draft)
				return true
			})
			running := a.snapshot.Status == "running"
			if !running && (strings.TrimSpace(a.draft) == "" || a.sending) {
				return
			}
			label := "Send"
			if running {
				label = "Stop"
			}
			button := ui.ButtonBase(c.Key("send")).Size(26, 26).Radius(13).Center().Label(label).Tooltip(label).Background(theme.Accent)
			button.Children(func() {
				if running {
					symbol(c, symbolStop, 10, theme.AccentText)
				} else {
					symbol(c, symbolSend, 12, theme.AccentText)
				}
			})
			if button.Clicked() {
				if running {
					a.abortChat()
				} else {
					a.sendMessage()
				}
			}
		})
	})
}

func messageLabel(message Message) string {
	switch {
	case message.Role == "assistant":
		return "Agent"
	case message.Role != "user":
		return "Tool result"
	case message.Origin != nil && message.Origin.Kind == "task":
		return "Task · " + message.Origin.Name
	case message.Origin != nil && message.Origin.Kind == "bot":
		return "From " + message.Origin.Name
	}
	return "You"
}

var markdownMarks = strings.NewReplacer("**", "", "__", "", "`", "", "# ", "", "> ", "")

func preview(text string) string {
	text = strings.Join(strings.Fields(markdownMarks.Replace(text)), " ")
	if runes := []rune(text); len(runes) > 120 {
		return string(runes[:119]) + "…"
	}
	return text
}

// page lays out a settings-style page: a title row in the title bar and centered content.
func (a *app) page(c *ui.Context, title string, actions func(), content func()) {
	ui.Row(c).Height(titleBarHeight).Shrink(0).Padding(0, 20, 0, 32).Gap(8).AlignItems(ui.Center).DragWindow().Children(func() {
		ui.Text(c, title).FontSize(15).Bold().Grow(1)
		if actions != nil {
			actions()
		}
	})
	ui.Divider(c)
	ui.Scroll(c).Grow(1).Children(func() {
		ui.Row(c).Justify(ui.Center).Padding(24, 32, 40, 32).Children(func() {
			ui.Column(c).Grow(1).MaxWidth(620).Gap(20).Children(func() {
				if a.errorText != "" {
					ui.Text(c, a.errorText).FontSize(12).TextColor(c.Theme().Danger).Selectable()
				}
				content()
			})
		})
	})
}

// group is an inset list of rows on the surface color, as System Settings draws them.
func group(c *ui.Context, rows int, row func(i int)) {
	theme := c.Theme()
	ui.Column(c).Radius(10).Background(theme.Surface).Clip().Children(func() {
		for i := 0; i < rows; i++ {
			if i > 0 {
				ui.Box(c).Height(1).Margin(0, 0, 0, 14).Background(theme.Border)
			}
			row(i)
		}
	})
}

func emptyText(c *ui.Context, text string) {
	ui.Text(c, text).TextColor(c.Theme().TextMuted).Padding(24, 0).AlignSelf(ui.Center)
}

func (a *app) settingsView(c *ui.Context) {
	var configured []string
	for _, provider := range a.providers {
		if provider.Configured {
			configured = append(configured, provider.Provider)
		}
	}
	keysFooter := "Keys are stored encrypted on your server."
	if len(configured) > 0 {
		keysFooter = "Configured: " + strings.Join(configured, ", ") + ". " + keysFooter
	}
	names := make([]string, 0, len(a.providers))
	for _, provider := range a.providers {
		names = append(names, provider.Provider)
	}
	a.page(c, "Settings", nil, func() {
		section(c, "Server", "The token stays in the macOS Keychain; it is never written to the project.",
			func() {
				settingsRow(c, "Server URL", func() { textValue(c, &a.serverURL, "Server URL", "http://127.0.0.1:7337") })
			},
			func() {
				settingsRow(c, "Server token", func() { textValue(c, &a.token, "Server token", "Required").Password() })
			},
			func() {
				if rowButton(c, "save-connection", "Save Connection", false) {
					a.saveSettings()
				}
			},
		)
		section(c, "Provider API Keys", keysFooter,
			func() {
				settingsRow(c, "Provider", func() {
					if len(names) > 0 {
						popupButton(c, "Provider", &a.provider, names)
					} else {
						textValue(c, &a.provider, "Provider", "melious")
					}
				})
			},
			func() {
				settingsRow(c, "API key", func() { textValue(c, &a.providerKey, "API key", "Paste a key").Password() })
			},
			func() {
				if rowButton(c, "save-key", "Save Key", false) {
					a.saveProviderKey()
				}
			},
			func() {
				if rowButton(c, "remove-key", "Remove Key", true) {
					a.removeProviderKey()
				}
			},
		)
	})
}

func (a *app) agentEditorView(c *ui.Context) {
	theme := c.Theme()
	title := "Agent Profile"
	if a.newAgent {
		title = "New Agent"
	}
	a.page(c, title, func() {
		if ui.Button(c, "Cancel").Clicked() {
			a.editor = false
		}
		label := "Save"
		if a.newAgent {
			label = "Create"
		}
		if ui.PrimaryButton(c, label).Disabled(a.loading).Clicked() {
			a.saveAgentEditor()
		}
	}, func() {
		ui.Column(c).AlignItems(ui.Center).Gap(6).Padding(4, 0, 8, 0).Children(func() {
			if svg, err := critterSVG(agentAvatarSeed(Agent{ID: a.selected, Avatar: a.editAvatar})); err == nil {
				ui.Image(c, svg).Size(76, 76).Radius(22).Label("Agent avatar")
			}
			name := strings.TrimSpace(a.editName)
			if name == "" {
				name = "New Agent"
			}
			ui.Text(c, name).FontSize(20).Bold()
			critter := ui.ButtonBase(c.Key("new-critter")).Padding(2, 6).Radius(5).Label("New critter")
			critter.Children(func() { ui.Text(c, "New Critter").FontSize(12).TextColor(theme.Accent) })
			if critter.Clicked() {
				a.editAvatar = "critters:" + newRequestID()
			}
		})
		section(c, "", "",
			func() { settingsRow(c, "Name", func() { textValue(c, &a.editName, "Name", "Required") }) },
			func() {
				settingsRow(c, "Description", func() { textValue(c, &a.editDescription, "Description", "What it helps with") })
			},
			func() { settingsRow(c, "Folder", func() { textValue(c, &a.editFolder, "Folder", "Personal") }) },
			func() { settingsRow(c, "Enabled", func() { miniSwitch(c, &a.editEnabled, "Enabled") }) },
		)
		ids := make([]string, 0, len(a.models))
		for _, model := range a.models {
			ids = append(ids, model.ID)
		}
		section(c, "Model", a.modelHint(),
			func() {
				settingsRow(c, "Provider", func() {
					if popupButton(c, "Provider", &a.editProvider, a.providerChoices()) {
						a.models = nil
						a.editModel = ""
						a.loadModels(a.editProvider)
					}
				})
			},
			func() { settingsRow(c, "Model", func() { modelField(c, &a.editModel, ids) }) },
		)
		section(c, "Instructions", "How the agent should behave in every chat.", func() {
			ui.TextAreaBase(c.Key("instructions"), &a.editInstructions).Lines(4, 14).FontSize(13).Padding(10, 12).Label("Instructions")
		})
		capabilities := []func(){
			func() { settingsRow(c, "Memory", func() { miniSwitch(c, &a.toolsMemory, "Memory") }) },
			func() {
				settingsRow(c, "Delegate to other agents", func() { miniSwitch(c, &a.toolsDelegate, "Delegation") })
			},
		}
		if a.toolsDelegate {
			for _, agent := range a.agents {
				if agent.ID == a.selected {
					continue
				}
				agent := agent
				capabilities = append(capabilities, func() {
					enabled := a.editDelegates[agent.ID]
					settingsRow(c, "    "+agent.Name, func() {
						if miniSwitch(c, &enabled, "Delegate to "+agent.Name).Changed() {
							a.editDelegates[agent.ID] = enabled
						}
					})
				})
			}
		}
		section(c, "Capabilities", "Memory lets the agent keep notes between chats. Delegation lets it hand bounded tasks to the agents you allow.", capabilities...)
		if len(a.mcpServers) == 0 {
			section(c, "Integrations", "", func() {
				ui.Text(c, "Add an MCP server under Integrations to use its tools here.").FontSize(13).TextColor(theme.TextMuted).Padding(10, 12)
			})
		} else {
			var rows []func()
			for _, server := range a.mcpServers {
				server := server
				rows = append(rows, func() {
					enabled := a.editMCP[server.ID]
					settingsRow(c, server.Name, func() {
						if miniSwitch(c, &enabled, server.Name).Disabled(!server.Enabled).Changed() {
							a.editMCP[server.ID] = enabled
						}
					})
				})
			}
			section(c, "Integrations", "", rows...)
		}
		var skills []func()
		for i := range a.editSkills {
			index := i
			skills = append(skills, func() {
				ui.Column(c).Key(fmt.Sprintf("skill-%d", index)).Padding(8, 12).Gap(4).Children(func() {
					ui.Row(c).Gap(8).AlignItems(ui.Center).Children(func() {
						ui.TextInputBase(c.Key("name"), &a.editSkills[index].Name).FontSize(13).Bold().Grow(1).Label("Skill name").Placeholder("Skill name")
						if iconButton(c, "remove", symbolClose, "Remove skill").Clicked() {
							a.editSkills = append(a.editSkills[:index], a.editSkills[index+1:]...)
						}
					})
					if index < len(a.editSkills) {
						ui.TextAreaBase(c.Key("instructions"), &a.editSkills[index].Instructions).Lines(2, 10).FontSize(13).
							TextColor(theme.TextMuted).Label("Skill instructions").Placeholder("What the agent should do")
					}
				})
			})
		}
		skills = append(skills, func() {
			if rowButton(c, "add-skill", "Add Skill…", false) {
				a.editSkills = append(a.editSkills, Skill{})
			}
		})
		section(c, "Skills", "Reusable instructions the agent follows when working.", skills...)
		if !a.newAgent {
			section(c, "", "",
				func() {
					if rowButton(c, "duplicate", "Duplicate Agent", false) {
						a.duplicateSelected()
					}
				},
				func() {
					if rowButton(c, "delete", "Delete Agent…", true) {
						a.deleteSelected()
					}
				},
			)
		}
	})
}

// providerChoices lists the server's providers, configured ones first, keeping the current choice.
func (a *app) providerChoices() []string {
	var configured, others []string
	for _, provider := range a.providers {
		if provider.Configured {
			configured = append(configured, provider.Provider)
		} else {
			others = append(others, provider.Provider)
		}
	}
	choices := append(configured, others...)
	for _, choice := range choices {
		if choice == a.editProvider {
			return choices
		}
	}
	return append([]string{a.editProvider}, choices...)
}

func (a *app) modelHint() string {
	for _, provider := range a.providers {
		if provider.Provider == a.editProvider && !provider.Configured {
			return "Add an API key for this provider in Settings to load its models."
		}
	}
	if len(a.models) == 0 {
		return "Type a model ID."
	}
	return fmt.Sprintf("%d models available.", len(a.models))
}

func formButtons(c *ui.Context, save string, onSave, onCancel func()) {
	ui.Row(c).Gap(8).Children(func() {
		ui.Spacer(c)
		if ui.Button(c, "Cancel").Clicked() {
			onCancel()
		}
		if ui.PrimaryButton(c, save).Clicked() {
			onSave()
		}
	})
}

func (a *app) memoryFormView(c *ui.Context) {
	section(c, "Memory Entry", "", func() {
		ui.TextAreaBase(c.Key("memory"), &a.memoryContent).Lines(4, 14).FontSize(13).Padding(10, 12).Label("Content").Placeholder("Something to remember")
	})
	formButtons(c, "Save", a.saveMemory, func() { a.memoryForm = false })
}

func (a *app) taskFormView(c *ui.Context) {
	section(c, "Task", "",
		func() { settingsRow(c, "Name", func() { textValue(c, &a.taskName, "Name", "Required") }) },
		func() { settingsRow(c, "Enabled", func() { miniSwitch(c, &a.taskEnabled, "Enabled") }) },
	)
	section(c, "Prompt", "", func() {
		ui.TextAreaBase(c.Key("prompt"), &a.taskPrompt).Lines(3, 12).FontSize(13).Padding(10, 12).Label("Prompt").Placeholder("What the agent should do")
	})
	section(c, "Schedule", "Use a cron expression to repeat, or a date and time to run once.",
		func() { settingsRow(c, "Repeat", func() { textValue(c, &a.taskCron, "Repeat", "0 9 * * 1-5") }) },
		func() {
			settingsRow(c, "Run once at", func() { textValue(c, &a.taskRunAt, "Run once at", "2026-10-18T09:00:00Z") })
		},
		func() { settingsRow(c, "Time zone", func() { textValue(c, &a.taskTimezone, "Time zone", "UTC") }) },
	)
	formButtons(c, "Save", a.saveTask, func() { a.taskForm = false })
}

func (a *app) mcpFormView(c *ui.Context) {
	section(c, "MCP Server", "",
		func() { settingsRow(c, "Name", func() { textValue(c, &a.mcpName, "Name", "Required") }) },
		func() { settingsRow(c, "HTTP URL", func() { textValue(c, &a.mcpURL, "HTTP URL", "https://") }) },
		func() { settingsRow(c, "Token", func() { textValue(c, &a.mcpToken, "Token", "Optional").Password() }) },
		func() { settingsRow(c, "Enabled", func() { miniSwitch(c, &a.mcpEnabled, "Enabled") }) },
	)
	formButtons(c, "Save", a.saveMCP, func() { a.mcpForm = false })
}

var panelTitles = map[string]string{"memory": "Memory", "tasks": "Tasks", "activity": "Activity", "approvals": "Approvals", "mcp": "Integrations"}

func (a *app) panelView(c *ui.Context, panel string) {
	theme := c.Theme()
	actions := func() {
		switch {
		case panel == "memory" && a.selected != "" && !a.memoryForm:
			if iconButton(c, "new-memory", symbolPlus, "New memory").Clicked() {
				a.openMemoryForm("")
			}
		case panel == "tasks" && !a.taskForm:
			if iconButton(c, "new-task", symbolPlus, "New task").Disabled(a.selected == "").Clicked() {
				a.openTaskForm("")
			}
		case panel == "mcp" && !a.mcpForm:
			if iconButton(c, "new-mcp", symbolPlus, "Add MCP server").Clicked() {
				a.openMCPForm("")
			}
		}
		if ui.Button(c, "Refresh").Clicked() {
			a.openPanel(panel)
		}
	}
	a.page(c, panelTitles[panel], actions, func() {
		switch panel {
		case "memory":
			if a.selected == "" {
				emptyText(c, "Select an agent to see its memory.")
				return
			}
			if a.memoryForm {
				a.memoryFormView(c)
				return
			}
			if agent, ok := a.selectedAgent(); ok {
				ui.Text(c, "What "+agent.Name+" remembers between chats.").FontSize(12).TextColor(theme.TextMuted)
			}
			if len(a.memories) == 0 {
				emptyText(c, "No memories saved yet.")
				return
			}
			group(c, len(a.memories), func(i int) {
				memory := a.memories[i]
				ui.Row(c).Key(memory.ID).Gap(8).Padding(10, 10, 10, 14).AlignItems(ui.Center).Children(func() {
					ui.Text(c, memory.Content).Selectable().Grow(1).FontSize(13)
					ui.Toolbar(c, func() {
						if ui.Button(c, "Edit").Clicked() {
							a.openMemoryForm(memory.ID)
						}
						if ui.Button(c, "Delete").Clicked() {
							a.deleteMemory(memory.ID)
						}
					}).Label("Memory actions")
				})
			})
		case "tasks":
			if a.taskForm {
				a.taskFormView(c)
				return
			}
			if len(a.schedules) == 0 {
				emptyText(c, "Give an agent a task to run once or on a schedule.")
				return
			}
			group(c, len(a.schedules), func(i int) {
				schedule := a.schedules[i]
				ui.Row(c).Key(schedule.ID).Gap(8).Padding(10, 10, 10, 14).AlignItems(ui.Center).Children(func() {
					ui.Column(c).Grow(1).MinWidth(0).Gap(2).Children(func() {
						ui.Text(c, schedule.Name).FontSize(13).Bold()
						ui.Text(c, schedule.Prompt).FontSize(12).MaxLines(2).Ellipsis("…")
						timing := schedule.RunAt
						if schedule.Cron != "" {
							timing = schedule.Cron + " · " + schedule.Timezone
						}
						if !schedule.Enabled {
							timing = "Paused · " + timing
						}
						ui.Text(c, timing).FontSize(11).TextColor(theme.TextMuted)
					})
					ui.Toolbar(c, func() {
						if ui.Button(c, "Run now").Disabled(!schedule.Enabled).Clicked() {
							a.runSchedule(schedule.ID)
						}
						if ui.Button(c, "Edit").Clicked() {
							a.openTaskForm(schedule.ID)
						}
						if ui.Button(c, "Delete").Clicked() {
							a.deleteSchedule(schedule.ID)
						}
					}).Label("Task actions")
				})
			})
		case "activity":
			if len(a.executions) == 0 {
				emptyText(c, "Work from chats and tasks will appear here.")
				return
			}
			group(c, len(a.executions), func(i int) {
				execution := a.executions[i]
				ui.Row(c).Key(execution.ID).Gap(8).Padding(10, 10, 10, 14).AlignItems(ui.Center).Children(func() {
					ui.Column(c).Grow(1).MinWidth(0).Gap(2).Children(func() {
						ui.Row(c).Gap(6).AlignItems(ui.Center).Children(func() {
							ui.Badge(c, execution.Status)
							ui.Text(c, activityTime(execution.CreatedAt)).FontSize(11).TextColor(theme.TextMuted)
						})
						ui.Text(c, execution.Prompt).FontSize(13).MaxLines(2).Ellipsis("…")
						if execution.Error != "" {
							ui.Text(c, execution.Error).FontSize(12).TextColor(theme.Danger).Selectable()
						}
					})
					ui.Toolbar(c, func() {
						if ui.Button(c, "Open chat").Clicked() {
							a.selectAgent(execution.AgentID)
						}
					}).Label("Activity actions")
				})
			})
		case "approvals":
			var pending []Approval
			for _, approval := range a.approvals {
				if approval.Status == "pending" {
					pending = append(pending, approval)
				}
			}
			if len(pending) == 0 {
				emptyText(c, "No actions need your approval.")
				return
			}
			group(c, len(pending), func(i int) {
				approval := pending[i]
				ui.Column(c).Key(approval.ID).Gap(8).Padding(12, 14).Children(func() {
					ui.Text(c, approval.ToolName).FontSize(13).Bold()
					encoded, _ := json.MarshalIndent(approval.Arguments, "", "  ")
					ui.Text(c, string(encoded)).FontSize(12).Font("Menlo").TextColor(theme.TextMuted).Selectable()
					ui.Row(c).Gap(8).Children(func() {
						if ui.PrimaryButton(c, "Approve once").Clicked() {
							a.decideApproval(approval.ID, "approved")
						}
						if ui.Button(c, "Deny").Clicked() {
							a.decideApproval(approval.ID, "denied")
						}
					})
				})
			})
		case "mcp":
			if a.mcpForm {
				a.mcpFormView(c)
				return
			}
			ui.Text(c, "Connect an MCP server, then enable it for individual agents in their profiles.").FontSize(12).TextColor(theme.TextMuted)
			if len(a.mcpServers) == 0 {
				emptyText(c, "No MCP servers yet.")
				return
			}
			group(c, len(a.mcpServers), func(i int) {
				server := a.mcpServers[i]
				ui.Row(c).Key(server.ID).Gap(8).Padding(10, 10, 10, 14).AlignItems(ui.Center).Children(func() {
					ui.Column(c).Grow(1).MinWidth(0).Gap(2).Children(func() {
						ui.Text(c, server.Name).FontSize(13).Bold()
						ui.Text(c, server.URL).FontSize(12).TextColor(theme.TextMuted).SingleLine().Ellipsis("…")
					})
					if !server.Enabled {
						ui.Badge(c, "Disabled")
					}
					ui.Toolbar(c, func() {
						if ui.Button(c, "Edit").Clicked() {
							a.openMCPForm(server.ID)
						}
						if ui.Button(c, "Delete").Clicked() {
							a.deleteMCP(server.ID)
						}
					}).Label("Server actions")
				})
			})
		}
	})
}

func activityTime(value string) string {
	at, err := time.Parse(time.RFC3339Nano, value)
	if err != nil {
		return value
	}
	return timeLabel(at.Local())
}
