package main

import (
	"context"
	"crypto/rand"
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
"os"
	"strings"
	"time"

	"github.com/egoist/mygo"
)

// Window state is confined to the UI thread. Workers return mutations through
// Window.Update; text input bindings never race network callbacks.
func (a *app) update(fn func()) {
	if a.dispatch != nil {
		a.dispatch(fn)
	} else if a.win != nil {
		a.win.Update(fn)
	} else {
		fn()
	}
}
func (a *app) request(work func(context.Context, *APIClient) (func(), error)) {
	client := a.client
	if client == nil {
		a.errorText = "Connect to your server in Settings."
		return
	}
	a.activeRequests++
	a.loading = true
	a.errorText = ""
	a.notice = ""
	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
		defer cancel()
		apply, err := work(ctx, client)
		a.update(func() {
			if a.client != client {
				return
			}
			a.activeRequests--
			a.loading = a.activeRequests > 0
			if err != nil {
				a.errorText = friendlyError(err)
				return
			}
			if apply != nil {
				apply()
			}
		})
	}()
}
func friendlyError(err error) string {
	var apiError *APIError
	if errors.As(err, &apiError) {
		if apiError.StatusCode == 401 {
			return "Authentication failed. Check the server token in Settings."
		}
		var body struct {
			Error   string `json:"error"`
			Details []struct {
				Message string `json:"message"`
			} `json:"details"`
		}
		if json.Unmarshal([]byte(apiError.Body), &body) == nil && body.Error != "" {
			if len(body.Details) > 0 {
				return body.Error + ": " + body.Details[0].Message
			}
			return body.Error
		}
	}
	return err.Error()
}
func (a *app) cancelStream() {
	if a.streamCancel != nil {
		a.streamCancel()
		a.streamCancel = nil
	}
	a.streamStatus = ""
}
func (a *app) refresh() {
	a.request(func(ctx context.Context, client *APIClient) (func(), error) {
		agents, err := client.Agents(ctx)
		return func() {
			a.agents = agents
			a.notice = "Connected"
			chosen := a.selected
			exists := false
			for _, agent := range agents {
				if agent.ID == chosen {
					exists = true
				}
			}
			if !exists {
				chosen = ""
				if len(agents) > 0 {
					chosen = agents[0].ID
				}
			}
			if chosen != "" {
				a.selectAgent(chosen)
			} else {
				a.cancelStream()
				a.selected = ""
				a.snapshot = nil
				a.conversations = nil
			}
		}, err
	})
}
func (a *app) selectAgent(id string) {
	a.cancelStream()
	a.selectionVersion++
	version := a.selectionVersion
	a.selected = id
	a.snapshot = nil
	a.conversationID = ""
	a.conversations = nil
	a.panel = ""
	a.settings = false
	a.editor = false
	a.draft = ""
	a.failedDraft = ""
	a.draftRequestID = ""
	a.request(func(ctx context.Context, client *APIClient) (func(), error) {
		conversations, err := client.Conversations(ctx, id)
		return func() {
			if a.selectionVersion != version || a.selected != id {
				return
			}
			a.conversations = conversations
			if len(conversations) > 0 {
				a.selectConversation(conversations[0].ID)
			}
		}, err
	})
}
func (a *app) selectConversation(id string) {
	a.cancelStream()
	a.selectionVersion++
	version := a.selectionVersion
	a.conversationID = id
	a.panel = ""
	a.settings = false
	a.editor = false
	a.snapshot = nil
	a.draft = ""
	a.failedDraft = ""
	a.draftRequestID = ""
	a.request(func(ctx context.Context, client *APIClient) (func(), error) {
		snapshot, err := client.Snapshot(ctx, id)
		return func() {
			if a.selectionVersion != version || a.conversationID != id {
				return
			}
			a.snapshot = &snapshot
			a.chatTitle = snapshot.Conversation.Title
			streamCtx, cancel := context.WithCancel(context.Background())
			a.streamCancel = cancel
			go a.streamConversation(streamCtx, client, id)
		}, err
	})
}
func (a *app) streamConversation(ctx context.Context, client *APIClient, id string) {
	backoff := 500 * time.Millisecond
	for ctx.Err() == nil {
		err := client.Events(ctx, id, func(data string) {
			var snapshot ConversationSnapshot
			if json.Unmarshal([]byte(data), &snapshot) != nil {
				return
			}
			a.update(func() {
				if ctx.Err() != nil || a.client != client || a.conversationID != id {
					return
				}
				if snapshot.Conversation.ID == "" && a.snapshot != nil {
					snapshot.Conversation = a.snapshot.Conversation
				}
				a.snapshot = &snapshot
				a.streamStatus = ""
				a.errorText = ""
				for i := range a.conversations {
					if a.conversations[i].ID == id {
						a.conversations[i].Title = snapshot.Conversation.Title
					}
				}
			})
		})
		if ctx.Err() != nil {
			return
		}
		a.update(func() {
			if a.conversationID == id && a.client == client {
				a.streamStatus = "Reconnecting…"
			}
		})
		var apiError *APIError
		if errors.As(err, &apiError) && apiError.StatusCode == 401 {
			a.update(func() {
				if a.conversationID == id {
					a.errorText = friendlyError(err)
					a.streamStatus = "Disconnected"
				}
			})
			return
		}
		timer := time.NewTimer(backoff)
		select {
		case <-ctx.Done():
			timer.Stop()
			return
		case <-timer.C:
		}
		backoff = min(backoff*2, 8*time.Second)
	}
}
func (a *app) newConversation() {
	id := a.selected
	if id == "" {
		return
	}
	a.request(func(ctx context.Context, client *APIClient) (func(), error) {
		conversation, err := client.CreateConversation(ctx, id)
		return func() {
			if a.selected != id {
				return
			}
			a.conversations = append([]Conversation{conversation}, a.conversations...)
			a.selectConversation(conversation.ID)
		}, err
	})
}
func newRequestID() string {
	b := make([]byte, 16)
	if _, err := rand.Read(b); err != nil {
		panic(fmt.Errorf("generate request ID: %w", err))
	}
	b[6] = (b[6] & 0x0f) | 0x40
	b[8] = (b[8] & 0x3f) | 0x80
	return fmt.Sprintf("%08x-%04x-%04x-%04x-%012x", b[0:4], b[4:6], b[6:8], b[8:10], b[10:16])
}
func (a *app) sendMessage() {
	if a.sending || a.snapshot == nil {
		return
	}
	content := strings.TrimSpace(a.draft)
	if content == "" {
		return
	}
	id := a.conversationID
	if a.draftRequestID == "" || a.failedDraft != content {
		a.draftRequestID = newRequestID()
	}
	requestID := a.draftRequestID
	a.failedDraft = content
	a.sending = true
	a.draft = ""
	client := a.client
	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer cancel()
		err := client.SendMessage(ctx, id, content, requestID)
		a.update(func() {
			a.sending = false
			if a.client != client || a.conversationID != id {
				return
			}
			if err != nil {
				a.errorText = "Message was not confirmed: " + friendlyError(err)
				a.draft = content
				return
			}
			a.draftRequestID = ""
			a.failedDraft = ""
		})
	}()
}
func (a *app) abortConversation() {
	id := a.conversationID
	a.request(func(ctx context.Context, client *APIClient) (func(), error) { return nil, client.Abort(ctx, id) })
}
func (a *app) renameConversation() {
	id, title := a.conversationID, strings.TrimSpace(a.chatTitle)
	if title == "" {
		a.errorText = "A conversation title is required."
		return
	}
	a.request(func(ctx context.Context, client *APIClient) (func(), error) {
		conversation, err := client.UpdateConversation(ctx, id, title)
		return func() {
			for i := range a.conversations {
				if a.conversations[i].ID == id {
					a.conversations[i] = conversation
				}
			}
			if a.conversationID == id && a.snapshot != nil {
				copy := *a.snapshot
				copy.Conversation = conversation
				a.snapshot = &copy
			}
		}, err
	})
}
func (a *app) deleteConversation() {
	id := a.conversationID
	a.confirm("Delete conversation?", "The conversation and its execution history will be removed.", func() {
		a.request(func(ctx context.Context, client *APIClient) (func(), error) {
			err := client.DeleteConversation(ctx, id)
			return func() { a.selectAgent(a.selected) }, err
		})
	})
}
func (a *app) confirm(title, message string, action func()) {
	go func() {
		result, err := mygo.Dialog.Message(mygo.MessageOptions{Title: title, Message: message, Buttons: []string{"Cancel", "Delete"}, Type: mygo.MessageWarning})
		if err == nil && result.Button == 1 {
			a.update(action)
		}
	}()
}
func (a *app) createAgent() {
	a.newAgent = true
	a.editor = true
	a.settings = false
	a.panel = ""
	a.editName = ""
	a.editDescription = ""
	a.editInstructions = "You are a thoughtful, capable personal assistant."
	a.editModel = "gpt-4.1"
	a.editProvider = "openai"
	a.editEnabled = true
	a.editAvatar = "✦"
	a.editFolder = "Personal"
	a.toolsMemory = true
	a.toolsDelegate = false
	a.editDelegates = map[string]bool{}
	a.editMCP = map[string]bool{}
	a.editSkills = []Skill{}
	a.loadMCPServers()
}
func (a *app) openEditor() {
	for _, agent := range a.agents {
		if agent.ID == a.selected {
			a.newAgent = false
			a.editor = true
			a.panel = ""
			a.settings = false
			a.editName = agent.Name
			a.editDescription = agent.Description
			a.editInstructions = agent.Instructions
			a.editModel = agent.Model
			a.editProvider = agent.Provider
			a.editEnabled = agent.Enabled
			a.editAvatar = agent.Avatar
			a.editFolder = agent.Folder
			a.toolsMemory = false
			a.toolsDelegate = false
			for _, tool := range agent.Tools {
				if tool == "memory" {
					a.toolsMemory = true
				}
				if tool == "delegate" {
					a.toolsDelegate = true
				}
			}
			a.editSkills = append([]Skill{}, agent.Skills...)
			a.editDelegates = map[string]bool{}
			a.editMCP = map[string]bool{}
			for _, id := range agent.Delegates {
				a.editDelegates[id] = true
			}
			for _, id := range agent.MCPServers {
				a.editMCP[id] = true
			}
			a.loadMCPServers()
			return
		}
	}
}
func (a *app) loadMCPServers() {
	a.request(func(ctx context.Context, client *APIClient) (func(), error) {
		servers, err := client.MCPServers(ctx)
		return func() { a.mcpServers = servers }, err
	})
}
func (a *app) saveAgentEditor() {
	if strings.TrimSpace(a.editName) == "" {
		a.errorText = "Give your agent a name."
		return
	}
	tools := []string{}
	if a.toolsMemory {
		tools = append(tools, "memory")
	}
	if a.toolsDelegate {
		tools = append(tools, "delegate")
	}
	delegates := []string{}
	for id, enabled := range a.editDelegates {
		if enabled {
			delegates = append(delegates, id)
		}
	}
	servers := []string{}
	for id, enabled := range a.editMCP {
		if enabled {
			servers = append(servers, id)
		}
	}
	skills := append([]Skill{}, a.editSkills...)
	for _, skill := range skills {
		if strings.TrimSpace(skill.Name) == "" || strings.TrimSpace(skill.Instructions) == "" {
			a.errorText = "Each skill needs a name and instructions."
			return
		}
	}
	input := Agent{Name: strings.TrimSpace(a.editName), Description: a.editDescription, Instructions: a.editInstructions, Provider: a.editProvider, Model: a.editModel, Avatar: a.editAvatar, Folder: a.editFolder, Enabled: a.editEnabled, Tools: tools, Skills: skills, MCPServers: servers, Delegates: delegates}
	id, isNew := a.selected, a.newAgent
	a.request(func(ctx context.Context, client *APIClient) (func(), error) {
		var agent Agent
		var err error
		if isNew {
			agent, err = client.CreateAgent(ctx, input)
		} else {
			agent, err = client.UpdateAgent(ctx, id, map[string]any{"name": input.Name, "description": input.Description, "instructions": input.Instructions, "provider": input.Provider, "model": input.Model, "avatar": input.Avatar, "folder": input.Folder, "enabled": input.Enabled, "tools": tools, "skills": skills, "mcpServers": servers, "delegates": delegates})
		}
		return func() {
			if isNew {
				a.agents = append(a.agents, agent)
			} else {
				for i := range a.agents {
					if a.agents[i].ID == id {
						a.agents[i] = agent
					}
				}
			}
			a.editor = false
			a.selectAgent(agent.ID)
		}, err
	})
}
func (a *app) duplicateSelected() {
	id := a.selected
	a.request(func(ctx context.Context, client *APIClient) (func(), error) {
		agent, err := client.DuplicateAgent(ctx, id)
		return func() { a.agents = append(a.agents, agent); a.selectAgent(agent.ID); a.openEditor() }, err
	})
}
func (a *app) deleteSelected() {
	id := a.selected
	a.confirm("Delete agent?", "The agent, conversations, memories and tasks will be removed.", func() {
		a.request(func(ctx context.Context, client *APIClient) (func(), error) {
			err := client.DeleteAgent(ctx, id)
			return func() { a.selected = ""; a.editor = false; a.refresh() }, err
		})
	})
}
func (a *app) openPanel(panel string) {
	a.settings = false
	a.editor = false
	a.panel = panel
	a.memoryForm = false
	a.taskForm = false
	a.mcpForm = false
	selected := a.selected
	if panel == "memory" && selected == "" {
		a.errorText = "Select an agent to manage its memory."
		return
	}
	a.request(func(ctx context.Context, client *APIClient) (func(), error) {
		switch panel {
		case "memory":
			items, err := client.Memories(ctx, selected)
			return func() {
				if a.selected == selected && a.panel == panel {
					a.memories = items
				}
			}, err
		case "tasks":
			items, err := client.Schedules(ctx)
			return func() { a.schedules = items }, err
		case "activity":
			items, err := client.Executions(ctx)
			return func() { a.executions = items }, err
		case "approvals":
			items, err := client.Approvals(ctx)
			return func() { a.approvals = items }, err
		case "mcp":
			items, err := client.MCPServers(ctx)
			return func() { a.mcpServers = items }, err
		}
		return nil, nil
	})
}
func (a *app) openMemoryForm(id string) {
	a.memoryForm = true
	a.memoryID = id
	a.memoryContent = ""
	for _, m := range a.memories {
		if m.ID == id {
			a.memoryContent = m.Content
		}
	}
}
func (a *app) saveMemory() {
	id, agent, content := a.memoryID, a.selected, strings.TrimSpace(a.memoryContent)
	if content == "" {
		a.errorText = "Memory content is required."
		return
	}
	a.request(func(ctx context.Context, client *APIClient) (func(), error) {
		var err error
		if id == "" {
			_, err = client.AddMemory(ctx, agent, content)
		} else {
			_, err = client.UpdateMemory(ctx, agent, id, content)
		}
		return func() { a.openPanel("memory") }, err
	})
}
func (a *app) deleteMemory(id string) {
	agent := a.selected
	a.request(func(ctx context.Context, client *APIClient) (func(), error) {
		err := client.DeleteMemory(ctx, agent, id)
		return func() { a.openPanel("memory") }, err
	})
}
func (a *app) openTaskForm(id string) {
	if a.selected == "" {
		a.errorText = "Select an agent before creating a task."
		return
	}
	a.taskForm = true
	a.taskID = id
	a.taskName = ""
	a.taskPrompt = ""
	a.taskCron = ""
	a.taskRunAt = ""
	a.taskTimezone = localTimezone()
	a.taskEnabled = true
	for _, s := range a.schedules {
		if s.ID == id {
			a.taskName = s.Name
			a.taskPrompt = s.Prompt
			a.taskCron = s.Cron
			a.taskRunAt = s.RunAt
			a.taskTimezone = s.Timezone
			a.taskEnabled = s.Enabled
		}
	}
}
func validateTask(name, prompt, cron, runAt string) string {
	if strings.TrimSpace(name) == "" || strings.TrimSpace(prompt) == "" {
		return "Task name and prompt are required."
	}
	if (cron == "") == (runAt == "") {
		return "Choose either a recurring cron or a one-time run time."
	}
	if runAt != "" {
		if _, err := time.Parse(time.RFC3339, runAt); err != nil {
			return "Use a complete date and time with a time zone, such as 2026-10-18T09:00:00Z."
		}
	}
	return ""
}
func (a *app) saveTask() {
	id, agent, name, prompt, cron, runAt, timezone, enabled := a.taskID, a.selected, strings.TrimSpace(a.taskName), strings.TrimSpace(a.taskPrompt), strings.TrimSpace(a.taskCron), strings.TrimSpace(a.taskRunAt), strings.TrimSpace(a.taskTimezone), a.taskEnabled
	if message := validateTask(name, prompt, cron, runAt); message != "" {
		a.errorText = message
		return
	}
	for _, schedule := range a.schedules {
		if schedule.ID == id {
			agent = schedule.AgentID
		}
	}
	payload := map[string]any{"agentId": agent, "name": name, "prompt": prompt, "cron": nil, "runAt": nil, "timezone": timezone, "enabled": enabled}
	if cron != "" {
		payload["cron"] = cron
	} else {
		payload["runAt"] = runAt
	}
	a.request(func(ctx context.Context, client *APIClient) (func(), error) {
		var err error
		if id == "" {
			_, err = client.CreateSchedule(ctx, Schedule{AgentID: agent, Name: name, Prompt: prompt, Cron: cron, RunAt: runAt, Timezone: timezone, Enabled: enabled})
		} else {
			_, err = client.UpdateSchedule(ctx, id, payload)
		}
		return func() { a.openPanel("tasks") }, err
	})
}
func (a *app) runSchedule(id string) {
	a.request(func(ctx context.Context, client *APIClient) (func(), error) {
		execution, err := client.RunSchedule(ctx, id)
		return func() {
			a.notice = "Task started"
			if execution.ConversationID != "" {
				a.selected = execution.AgentID
				a.selectConversation(execution.ConversationID)
			}
		}, err
	})
}
func (a *app) deleteSchedule(id string) {
	a.request(func(ctx context.Context, client *APIClient) (func(), error) {
		err := client.DeleteSchedule(ctx, id)
		return func() { a.openPanel("tasks") }, err
	})
}
func (a *app) decideApproval(id, decision string) {
	a.request(func(ctx context.Context, client *APIClient) (func(), error) {
		err := client.DecideApproval(ctx, id, decision)
		return func() { a.openPanel("approvals") }, err
	})
}
func (a *app) openMCPForm(id string) {
	a.mcpForm = true
	a.mcpID = id
	a.mcpName = ""
	a.mcpURL = ""
	a.mcpToken = ""
	a.mcpEnabled = true
	for _, server := range a.mcpServers {
		if server.ID == id {
			a.mcpName = server.Name
			a.mcpURL = server.URL
			a.mcpEnabled = server.Enabled
		}
	}
}
func (a *app) saveMCP() {
	id, name, rawURL, token, enabled := a.mcpID, strings.TrimSpace(a.mcpName), strings.TrimSpace(a.mcpURL), a.mcpToken, a.mcpEnabled
	u, err := url.Parse(rawURL)
	if name == "" || err != nil || u.Host == "" || (u.Scheme != "http" && u.Scheme != "https") {
		a.errorText = "MCP name and an HTTP(S) URL are required."
		return
	}
	a.request(func(ctx context.Context, client *APIClient) (func(), error) {
		var err error
		if id == "" {
			_, err = client.CreateMCPServer(ctx, MCPServer{Name: name, URL: rawURL, Enabled: enabled}, token)
		} else {
			patch := map[string]any{"name": name, "url": rawURL, "enabled": enabled}
			if token != "" {
				patch["token"] = token
			}
			_, err = client.UpdateMCPServer(ctx, id, patch)
		}
		return func() { a.mcpToken = ""; a.openPanel("mcp") }, err
	})
}
func (a *app) deleteMCP(id string) {
	a.request(func(ctx context.Context, client *APIClient) (func(), error) {
		err := client.DeleteMCPServer(ctx, id)
		return func() { a.openPanel("mcp") }, err
	})
}
func (a *app) saveSettings() {
	rawURL, token := strings.TrimRight(strings.TrimSpace(a.serverURL), "/"), strings.TrimSpace(a.token)
	parsed, err := url.Parse(rawURL)
	if err != nil || parsed.Host == "" || (parsed.Scheme != "http" && parsed.Scheme != "https") {
		a.errorText = "Enter a valid server URL."
		return
	}
	client := NewAPIClient(rawURL, token)
	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
		defer cancel()
		_, err := client.Agents(ctx)
		if err == nil {
			err = mygo.Secrets.Service("dev.crumble.desktop").Set("server-token", []byte(token))
		}
		if err == nil {
			err = mygo.Secrets.Service("dev.crumble.desktop").Set("server-url", []byte(rawURL))
		}
		a.update(func() {
			if err != nil {
				a.errorText = friendlyError(err)
				return
			}
			a.cancelStream()
			a.client = client
			a.activeRequests = 0
			a.settings = false
			a.selected = ""
			a.refresh()
		})
	}()
}
func (a *app) saveProviderKey() {
	provider, key := a.provider, strings.TrimSpace(a.providerKey)
	if key == "" {
		a.errorText = "Enter an API key."
		return
	}
	a.request(func(ctx context.Context, client *APIClient) (func(), error) {
		err := client.SetProviderKey(ctx, provider, key)
		return func() { a.providerKey = ""; a.notice = "Provider key saved" }, err
	})
}

func localTimezone() string {
 if zone:=os.Getenv("TZ");zone!="" {if _,err:=time.LoadLocation(zone);err==nil&&zone!="Local"{return zone}}
 if target,err:=os.Readlink("/etc/localtime");err==nil{if index:=strings.Index(target,"zoneinfo/");index>=0{return target[index+len("zoneinfo/"):]}}
 return "UTC"
}
