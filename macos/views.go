package main

import (
	"encoding/json"
	"fmt"

	"github.com/egoist/mygo/ui"
	"strings"
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

func (a *app) view(c *ui.Context) {
	theme := c.Theme()
	bar := c.TitleBar()
	if c.Vibrancy() {
		c.Root().Background(ui.Transparent)
	}
	ui.Row(c).Fill().AlignItems(ui.Stretch).Children(func() {
		side := ui.Column(c).Width(240).Shrink(0)
		if !c.Vibrancy() {
			side.Background(theme.Surface)
		}
		side.Children(func() {
			ui.Box(c).Height(max(bar.Height, 52)).Shrink(0).DragWindow()
			ui.Row(c).Padding(8, 18, 12, 18).Gap(8).AlignItems(ui.Center).Children(func() {
				ui.Text(c, "Crumble").FontSize(20).Bold().Grow(1)
				if ui.Button(c, "+").Tooltip("New agent").Label("New agent").Clicked() {
					a.createAgent()
				}
			})
			sidebar := ui.Sidebar(c, &a.navigation, func() {
				ui.SidebarSection(c, "Agents", nil, func() {
					for _, agent := range a.agents {
						label := agent.Name
						if !agent.Enabled {
							label += " · Paused"
						}
						ui.SidebarItem(c, "agent:"+agent.ID, nil, label)
					}
					if len(a.agents) == 0 {
						ui.Text(c, "No agents yet").TextColor(theme.TextMuted).Padding(8)
					}
				})
				if a.selected != "" && len(a.conversations) > 0 {
					ui.SidebarSection(c, "Conversations", nil, func() {
						for _, conversation := range a.conversations {
							ui.SidebarItem(c, "chat:"+conversation.ID, nil, conversation.Title)
						}
					})
				}
				ui.SidebarSection(c, "Workspace", nil, func() {
					ui.SidebarItem(c, "memory", nil, "Memory")
					ui.SidebarItem(c, "tasks", nil, "Tasks")
					ui.SidebarItem(c, "activity", nil, "Activity")
					ui.SidebarItem(c, "approvals", nil, "Approvals")
					ui.SidebarItem(c, "mcp", nil, "Integrations")
					ui.SidebarItem(c, "settings", nil, "Settings")
				})
			}).Grow(1).Label("Workspace navigation")
			if c.Vibrancy() {
				sidebar.Background(ui.Transparent)
			}
			if sidebar.Changed() {
				switch {
				case strings.HasPrefix(a.navigation, "agent:"):
					a.selectAgent(strings.TrimPrefix(a.navigation, "agent:"))
				case strings.HasPrefix(a.navigation, "chat:"):
					a.selectConversation(strings.TrimPrefix(a.navigation, "chat:"))
				case a.navigation == "settings":
					a.settings = true
					a.editor = false
					a.panel = ""
				default:
					a.openPanel(a.navigation)
				}
			}
			status := "Connected"
			if a.loading {
				status = "Syncing…"
			}
			if a.streamStatus != "" {
				status = a.streamStatus
			}
			ui.Text(c, status).FontSize(11).TextColor(theme.TextMuted).Padding(12, 18)
		})
		ui.Box(c).Width(1).Background(theme.Border)
		ui.Column(c).Grow(1).MinWidth(0).Background(theme.Background).Children(func() {
			if a.errorText != "" {
				ui.Text(c, a.errorText).TextColor(theme.Danger).Padding(12, 24).Margin(max(bar.Height, 40), 0, 0, 0)
			}
			if a.notice != "" && a.settings {
				ui.Text(c, a.notice).TextColor(theme.TextMuted).Padding(8, 24)
			}
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
		if a.selected != "" {
			a.newConversation()
		} else {
			a.createAgent()
		}
	}
	if c.Shortcut(ui.Cmd, ui.KeyComma) {
		a.settings = true
		a.editor = false
		a.panel = ""
		a.navigation = "settings"
	}
}

func (a *app) chatView(c *ui.Context) {
	theme := c.Theme()
	ui.Row(c).Height(56).Shrink(0).Padding(0, 24).AlignItems(ui.Center).Gap(8).DragWindow().Children(func() {
		title := "Your agents"
		for _, agent := range a.agents {
			if agent.ID == a.selected {
				title = agent.Name
			}
		}
		ui.Text(c, title).FontSize(16).Bold().Grow(1)
		if a.selected != "" {
			if ui.Button(c, "Profile").Clicked() {
				a.openEditor()
			}
			if ui.Button(c, "New chat").Tooltip("New conversation · ⌘N").Clicked() {
				a.newConversation()
			}
		}
	})
	ui.Divider(c)
	if a.snapshot != nil {
		ui.Row(c).Padding(10, 24).Gap(8).AlignItems(ui.Center).Children(func() {
			ui.TextInput(c, &a.chatTitle).Label("Conversation title").Grow(1)
			if ui.Button(c, "Rename").Clicked() {
				a.renameConversation()
			}
			if ui.Button(c, "Delete").Label("Delete conversation").Clicked() {
				a.deleteConversation()
			}
		})
	}
	if a.snapshot == nil || len(a.snapshot.Messages) == 0 {
		ui.Column(c).Grow(1).Center().Padding(32).Gap(12).Children(func() {
			heading, detail := "A little help, always here.", "Create an agent with a purpose, then give it something to do."
			if a.selected != "" {
				heading = "What shall we work on?"
				detail = "Start a conversation. Your agent keeps its work and memory between visits."
			}
			if a.loading {
				heading = "Opening your workspace…"
				detail = ""
			}
			ui.Text(c, heading).FontSize(25).Bold()
			ui.Text(c, detail).MaxWidth(420).TextColor(theme.TextMuted)
			if a.selected == "" {
				if ui.PrimaryButton(c, "Create an agent").Clicked() {
					a.createAgent()
				}
			} else if a.snapshot == nil && !a.loading {
				if ui.PrimaryButton(c, "Start a conversation").Clicked() {
					a.newConversation()
				}
			}
		})
	} else {
		ui.Scroll(c).Grow(1).Padding(22, 28).Children(func() {
			ui.Column(c).Gap(18).Children(func() {
				for _, message := range a.snapshot.Messages {
					text := contentText(message.Content)
					if text == "" || message.Role == "system" {
						continue
					}
					ui.Column(c).MaxWidth(700).Gap(6).Children(func() {
						label := "Agent"
						if message.Role == "user" {
							label = "You"
						} else if message.Role != "assistant" {
							label = "Tool result"
						}
						ui.Text(c, label).FontSize(11).Bold().TextColor(theme.TextMuted)
						ui.Text(c, text).Selectable().FontSize(14)
					})
				}
				if a.snapshot.Partial != "" {
					ui.Column(c).Gap(6).Children(func() {
						ui.Text(c, "Responding").FontSize(11).TextColor(theme.TextMuted)
						ui.Text(c, a.snapshot.Partial).Selectable().FontSize(14)
					})
				}
				if a.snapshot.Error != "" {
					ui.Column(c).Gap(6).Padding(14).Radius(10).Background(theme.Surface).Children(func() {
						ui.Text(c, "The agent couldn’t finish").Bold()
						ui.Text(c, a.snapshot.Error).TextColor(theme.Danger).Selectable()
						if ui.Button(c, "Provider settings").Clicked() {
							a.settings = true
							a.navigation = "settings"
						}
					})
				}
			})
		})
	}
	if a.snapshot != nil {
		ui.Row(c).Padding(16, 24).Gap(10).AlignItems(ui.Center).Children(func() {
			input := ui.TextArea(c, &a.draft).Label("Message your agent").Placeholder("Message your agent…").Height(66).Grow(1).Disabled(a.sending)
			input.OnTextKey(func(k ui.TextKey) bool {
				if k.Key != ui.KeyEnter || k.Mods != 0 {
					return false
				}
				a.draft = k.Text()
				a.sendMessage()
				k.SetText(a.draft)
				return true
			})
			if a.snapshot.Status == "running" {
				if ui.Button(c, "Stop").Clicked() {
					a.abortConversation()
				}
			} else if ui.PrimaryButton(c, "Send").Disabled(a.sending || strings.TrimSpace(a.draft) == "").Clicked() {
				a.sendMessage()
			}
		})
	}
}

func (a *app) settingsView(c *ui.Context) {
	t := c.Theme()
	ui.Scroll(c).Fill().Padding(28, 36).Children(func() {
		ui.Text(c, "Connection & providers").FontSize(22).Bold()
		ui.Text(c, "The token stays in the macOS Keychain; it is never written to the project.").TextColor(t.TextMuted).Margin(0, 0, 20, 0)
		ui.TextInput(c, &a.serverURL).Label("Server URL").Width(520).Placeholder("http://127.0.0.1:7337")
		ui.TextInput(c, &a.token).Label("Server token").Width(520).Password()
		ui.Row(c).Gap(8).Margin(0, 16).Children(func() {
			if ui.PrimaryButton(c, "Save connection").Clicked() {
				a.saveSettings()
			}
			if ui.Button(c, "Back").Clicked() {

				a.settings = false

			}
		})
		ui.Divider(c)
		ui.Text(c, "Provider API key").FontSize(16).Bold().Margin(0, 20, 8, 0)
		ui.TextInput(c, &a.provider).Label("Provider").Width(240).Placeholder("openai")
		ui.TextInput(c, &a.providerKey).Label("API key").Width(520).Password()
		if ui.Button(c, "Save provider key").Clicked() {
			a.saveProviderKey()
		}
	})
}

func (a *app) agentEditorView(c *ui.Context) {
	ui.Scroll(c).Fill().Padding(28, 32).Children(func() {
		ui.Column(c).Gap(14).Children(func() {
			title := "Agent profile"
			if a.newAgent {
				title = "Create an agent"
			}
			ui.Text(c, title).FontSize(23).Bold()
			ui.TextInput(c, &a.editName).Label("Name").Width(500).Placeholder("Give your agent a name")
			ui.TextInput(c, &a.editDescription).Label("Description").Width(600).Placeholder("What does this agent help with?")
			ui.Row(c).Gap(12).Children(func() {
				ui.TextInput(c, &a.editAvatar).Label("Avatar symbol").Width(140)
				ui.TextInput(c, &a.editFolder).Label("Folder").Width(250)
			})
			ui.Row(c).Gap(12).AlignItems(ui.End).Children(func() {
				ui.Select(c, &a.editProvider, []string{"openai", "anthropic", "google"}).Label("Provider").Width(180)
				ui.TextInput(c, &a.editModel).Label("Model").Width(300)
			})
			ui.TextArea(c, &a.editInstructions).Label("Instructions").Width(620).Height(140)
			ui.Checkbox(c, &a.editEnabled, "Agent enabled")
			ui.Divider(c)
			ui.Text(c, "Capabilities").FontSize(16).Bold()
			ui.Checkbox(c, &a.toolsMemory, "Read and manage its own memory")
			ui.Checkbox(c, &a.toolsDelegate, "Delegate bounded tasks to selected agents")
			if a.toolsDelegate {
				for _, agent := range a.agents {
					if agent.ID == a.selected {
						continue
					}
					enabled := a.editDelegates[agent.ID]
					if ui.Checkbox(c, &enabled, agent.Name).Changed() {
						a.editDelegates[agent.ID] = enabled
					}
				}
			}
			ui.Text(c, "Integrations").FontSize(16).Bold()
			if len(a.mcpServers) == 0 {
				ui.Text(c, "Add an MCP server in Integrations to make its tools available here.").TextColor(c.Theme().TextMuted)
			}
			for _, server := range a.mcpServers {
				enabled := a.editMCP[server.ID]
				if ui.Checkbox(c, &enabled, server.Name).Disabled(!server.Enabled).Changed() {
					a.editMCP[server.ID] = enabled
				}
			}
			ui.Text(c, "Skills").FontSize(16).Bold()
			ui.Text(c, "Reusable instructions your agent follows when working.").TextColor(c.Theme().TextMuted)
			for i := range a.editSkills {
				index := i
				ui.Column(c).Key(fmt.Sprintf("skill-%d", i)).Gap(8).Padding(12).Radius(10).Background(c.Theme().Surface).Children(func() {
					ui.TextInput(c, &a.editSkills[index].Name).Label("Skill name").Width(500)
					ui.TextArea(c, &a.editSkills[index].Instructions).Label("Skill instructions").Width(600).Height(100)
					if ui.Button(c, "Remove skill").Clicked() {
						a.editSkills = append(a.editSkills[:index], a.editSkills[index+1:]...)
					}
				})
			}
			if ui.Button(c, "Add skill").Clicked() {
				a.editSkills = append(a.editSkills, Skill{})
			}
			ui.Row(c).Gap(8).Padding(8, 0).Children(func() {
				label := "Save changes"
				if a.newAgent {
					label = "Create agent"
				}
				if ui.PrimaryButton(c, label).Disabled(a.loading).Clicked() {
					a.saveAgentEditor()
				}
				if ui.Button(c, "Cancel").Clicked() {
					a.editor = false
				}
				if !a.newAgent {
					if ui.Button(c, "Duplicate").Clicked() {
						a.duplicateSelected()
					}
					if ui.Button(c, "Delete agent").Clicked() {
						a.deleteSelected()
					}
				}
			})
		})
	})
}

func (a *app) memoryFormView(c *ui.Context) {
	ui.Text(c, "Memory entry").FontSize(18).Bold()
	ui.TextArea(c, &a.memoryContent).Label("Content").Width(620).Height(150)
	ui.Row(c).Gap(8).Children(func() {
		if ui.PrimaryButton(c, "Save memory").Clicked() {
			a.saveMemory()
		}
		if ui.Button(c, "Cancel").Clicked() {

			a.memoryForm = false

		}
	})
}

func (a *app) taskFormView(c *ui.Context) {
	ui.Text(c, "Task").FontSize(18).Bold()
	ui.TextInput(c, &a.taskName).Label("Name").Width(560)
	ui.TextArea(c, &a.taskPrompt).Label("Prompt").Width(620).Height(140)
	ui.TextInput(c, &a.taskCron).Label("Recurring cron (optional)").Width(420).Placeholder("0 9 * * 1-5")
	ui.TextInput(c, &a.taskRunAt).Label("One-time run at (optional ISO-8601)").Width(560).Placeholder("2026-10-18T09:00:00Z")
	ui.TextInput(c, &a.taskTimezone).Label("Timezone").Width(240)
	ui.Checkbox(c, &a.taskEnabled, "Enabled")
	ui.Row(c).Gap(8).Children(func() {
		if ui.PrimaryButton(c, "Save task").Clicked() {
			a.saveTask()
		}
		if ui.Button(c, "Cancel").Clicked() {

			a.taskForm = false

		}
	})
}

func (a *app) mcpFormView(c *ui.Context) {
	ui.Text(c, "MCP server").FontSize(18).Bold()
	ui.TextInput(c, &a.mcpName).Label("Name").Width(520)
	ui.TextInput(c, &a.mcpURL).Label("HTTP URL").Width(620)
	ui.TextInput(c, &a.mcpToken).Label("Token (optional)").Password().Width(520)
	ui.Checkbox(c, &a.mcpEnabled, "Enabled")
	ui.Row(c).Gap(8).Children(func() {
		if ui.PrimaryButton(c, "Save server").Clicked() {
			a.saveMCP()
		}
		if ui.Button(c, "Cancel").Clicked() {

			a.mcpForm = false

		}
	})
}

func (a *app) panelView(c *ui.Context, panel string) {
	ui.Scroll(c).Fill().Padding(28, 32).Children(func() {
		ui.Column(c).Gap(14).Children(func() {
			ui.Row(c).Gap(8).Children(func() {
				if ui.Button(c, "Back to chat").Clicked() {
					a.panel = ""
					a.navigation = "agent:" + a.selected
				}
				if ui.Button(c, "Refresh").Clicked() {
					a.openPanel(panel)
				}
			})
			switch panel {
			case "memory":
				ui.Text(c, "Memory").FontSize(23).Bold()
				if a.selected == "" {
					ui.Text(c, "Select an agent to see its memory.")
					return
				}
				if a.memoryForm {
					a.memoryFormView(c)
					return
				}
				if ui.PrimaryButton(c, "New memory").Clicked() {
					a.openMemoryForm("")
				}
				if len(a.memories) == 0 {
					ui.Text(c, "No memories saved yet.").TextColor(c.Theme().TextMuted)
				}
				for _, memory := range a.memories {
					ui.Row(c).Key(memory.ID).Gap(8).Padding(10, 0).Children(func() {
						ui.Text(c, memory.Content).Selectable().Grow(1)
						if ui.Button(c, "Edit").Clicked() {
							a.openMemoryForm(memory.ID)
						}
						if ui.Button(c, "Delete").Clicked() {
							a.deleteMemory(memory.ID)
						}
					})
				}
			case "tasks":
				ui.Text(c, "Tasks").FontSize(23).Bold()
				if a.taskForm {
					a.taskFormView(c)
					return
				}
				if ui.PrimaryButton(c, "New task").Disabled(a.selected == "").Clicked() {
					a.openTaskForm("")
				}
				if len(a.schedules) == 0 {
					ui.Text(c, "Give an agent a task to run once or on a schedule.").TextColor(c.Theme().TextMuted)
				}
				for _, schedule := range a.schedules {
					ui.Column(c).Key(schedule.ID).Gap(6).Padding(12).Radius(10).Background(c.Theme().Surface).Children(func() {
						ui.Text(c, schedule.Name).Bold()
						ui.Text(c, schedule.Prompt).MaxWidth(620)
						timing := schedule.RunAt
						if schedule.Cron != "" {
							timing = schedule.Cron + " · " + schedule.Timezone
						}
						if !schedule.Enabled {
							timing = "Paused · " + timing
						}
						ui.Text(c, timing).FontSize(12).TextColor(c.Theme().TextMuted)
						ui.Row(c).Gap(8).Children(func() {
							if ui.Button(c, "Edit").Clicked() {
								a.openTaskForm(schedule.ID)
							}
							if ui.Button(c, "Run now").Disabled(!schedule.Enabled).Clicked() {
								a.runSchedule(schedule.ID)
							}
							if ui.Button(c, "Delete").Clicked() {
								a.deleteSchedule(schedule.ID)
							}
						})
					})
				}
			case "activity":
				ui.Text(c, "Activity").FontSize(23).Bold()
				if len(a.executions) == 0 {
					ui.Text(c, "Work from conversations and tasks will appear here.").TextColor(c.Theme().TextMuted)
				}
				for _, execution := range a.executions {
					ui.Column(c).Key(execution.ID).Gap(6).Padding(12).Radius(10).Background(c.Theme().Surface).Children(func() {
						ui.Text(c, execution.Status+" · "+execution.CreatedAt).FontSize(12).TextColor(c.Theme().TextMuted)
						ui.Text(c, execution.Prompt).MaxWidth(620)
						if execution.Error != "" {
							ui.Text(c, execution.Error).TextColor(c.Theme().Danger).Selectable()
						}
						if ui.Button(c, "Open conversation").Clicked() {
							a.selected = execution.AgentID
							a.selectConversation(execution.ConversationID)
						}
					})
				}
			case "approvals":
				ui.Text(c, "Approvals").FontSize(23).Bold()
				pending := 0
				for _, approval := range a.approvals {
					if approval.Status != "pending" {
						continue
					}
					pending++
					ui.Column(c).Key(approval.ID).Gap(8).Padding(14).Radius(10).Background(c.Theme().Surface).Children(func() {
						ui.Text(c, approval.ToolName).Bold()
						encoded, _ := json.MarshalIndent(approval.Arguments, "", "  ")
						ui.Text(c, string(encoded)).Selectable().MaxWidth(620)
						ui.Row(c).Gap(8).Children(func() {
							if ui.PrimaryButton(c, "Approve once").Clicked() {
								a.decideApproval(approval.ID, "approved")
							}
							if ui.Button(c, "Deny").Clicked() {
								a.decideApproval(approval.ID, "denied")
							}
						})
					})
				}
				if pending == 0 {
					ui.Text(c, "No actions need your approval.").TextColor(c.Theme().TextMuted)
				}
			case "mcp":
				ui.Text(c, "Integrations").FontSize(23).Bold()
				ui.Text(c, "Connect an MCP server, then enable it for individual agents in their profiles.").TextColor(c.Theme().TextMuted)
				if a.mcpForm {
					a.mcpFormView(c)
					return
				}
				if ui.PrimaryButton(c, "Add MCP server").Clicked() {
					a.openMCPForm("")
				}
				for _, server := range a.mcpServers {
					ui.Column(c).Key(server.ID).Gap(6).Padding(12).Radius(10).Background(c.Theme().Surface).Children(func() {
						ui.Text(c, server.Name).Bold()
						ui.Text(c, server.URL).TextColor(c.Theme().TextMuted)
						ui.Row(c).Gap(8).Children(func() {
							if ui.Button(c, "Edit").Clicked() {
								a.openMCPForm(server.ID)
							}
							if ui.Button(c, "Delete").Clicked() {
								a.deleteMCP(server.ID)
							}
						})
					})
				}
			}
		})
	})
}
