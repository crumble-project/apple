package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
)

var ErrSSEClosed = errors.New("server-sent event stream closed")

type APIError struct {
	Method     string
	Path       string
	StatusCode int
	Body       string
}

func (e *APIError) Error() string {
	return fmt.Sprintf("api %s %s (%d): %s", e.Method, e.Path, e.StatusCode, e.Body)
}

type Agent struct {
	ID           string   `json:"id"`
	Name         string   `json:"name"`
	Description  string   `json:"description,omitempty"`
	Instructions string   `json:"instructions,omitempty"`
	Avatar       string   `json:"avatar,omitempty"`
	Enabled      bool     `json:"enabled"`
	Provider     string   `json:"provider,omitempty"`
	Model        string   `json:"model,omitempty"`
	Folder       string   `json:"folder,omitempty"`
	Tools        []string `json:"tools,omitempty"`
	Delegates    []string `json:"delegates,omitempty"`
	Skills       []Skill  `json:"skills,omitempty"`
	MCPServers   []string `json:"mcpServers,omitempty"`
}

type Skill struct {
	Name         string `json:"name"`
	Instructions string `json:"instructions"`
}

type Conversation struct {
	ID        string `json:"id"`
	AgentID   string `json:"agentId"`
	Title     string `json:"title"`
	UpdatedAt string `json:"updatedAt"`
}

type Message struct {
	ID        string `json:"id"`
	Role      string `json:"role"`
	Content   any    `json:"content"`
	CreatedAt string `json:"createdAt"`
}

type ConversationSnapshot struct {
	Conversation Conversation `json:"conversation"`
	Messages     []Message    `json:"messages"`
	Status       string       `json:"status,omitempty"`
	Live         any          `json:"live,omitempty"`
	Partial      string       `json:"partial,omitempty"`
	Error        string       `json:"error,omitempty"`
	Usage        any          `json:"usage,omitempty"`
}

type Memory struct {
	ID        string `json:"id"`
	Content   string `json:"content"`
	CreatedAt string `json:"createdAt"`
}

type Schedule struct {
	ID       string `json:"id"`
	AgentID  string `json:"agentId"`
	Name     string `json:"name"`
	Cron     string `json:"cron,omitempty"`
	Prompt   string `json:"prompt"`
	Timezone string `json:"timezone"`
	RunAt    string `json:"runAt,omitempty"`
	Enabled  bool   `json:"enabled"`
}

type Execution struct {
	ID             string `json:"id"`
	AgentID        string `json:"agentId"`
	ConversationID string `json:"conversationId"`
	Status         string `json:"status"`
	Prompt         string `json:"prompt"`
	Error          string `json:"error"`
	CreatedAt      string `json:"createdAt"`
	UpdatedAt      string `json:"updatedAt"`
}

type ProviderStatus struct {
	Provider   string `json:"provider"`
	Configured bool   `json:"configured"`
}

type MCPServer struct {
	ID            string `json:"id"`
	Name          string `json:"name"`
	URL           string `json:"url"`
	Enabled       bool   `json:"enabled"`
	Authenticated bool   `json:"authenticated,omitempty"`
}

type Approval struct {
	ID        string `json:"id"`
	AgentID   string `json:"agentId"`
	ToolName  string `json:"toolName"`
	Arguments any    `json:"arguments"`
	Status    string `json:"status"`
}

type APIClient struct {
	BaseURL string
	Token   string
	HTTP    *http.Client
}

func NewAPIClient(baseURL, token string) *APIClient {
	return &APIClient{BaseURL: strings.TrimRight(baseURL, "/"), Token: token, HTTP: http.DefaultClient}
}

func (c *APIClient) request(ctx context.Context, method, path string, body any, out any) error {
	var reader io.Reader
	if body != nil {
		payload, err := json.Marshal(body)
		if err != nil {
			return err
		}
		reader = bytes.NewReader(payload)
	}
	req, err := http.NewRequestWithContext(ctx, method, c.BaseURL+path, reader)
	if err != nil {
		return err
	}
	if c.Token != "" {
		req.Header.Set("Authorization", "Bearer "+c.Token)
	}
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	resp, err := c.HTTP.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		data, _ := io.ReadAll(io.LimitReader(resp.Body, 8<<10))
		return &APIError{Method: method, Path: path, StatusCode: resp.StatusCode, Body: strings.TrimSpace(string(data))}
	}
	if out == nil {
		return nil
	}
	return json.NewDecoder(resp.Body).Decode(out)
}

func (c *APIClient) Health(ctx context.Context) error {
	return c.request(ctx, http.MethodGet, "/health", nil, nil)
}
func (c *APIClient) Agents(ctx context.Context) ([]Agent, error) {
	var out []Agent
	return out, c.request(ctx, http.MethodGet, "/v1/agents", nil, &out)
}
func (c *APIClient) CreateAgent(ctx context.Context, agent Agent) (Agent, error) {
	var out Agent
	return out, c.request(ctx, http.MethodPost, "/v1/agents", agent, &out)
}
func (c *APIClient) UpdateAgent(ctx context.Context, id string, patch map[string]any) (Agent, error) {
	var out Agent
	return out, c.request(ctx, http.MethodPatch, "/v1/agents/"+id, patch, &out)
}
func (c *APIClient) DeleteAgent(ctx context.Context, id string) error {
	return c.request(ctx, http.MethodDelete, "/v1/agents/"+id, nil, nil)
}
func (c *APIClient) DuplicateAgent(ctx context.Context, id string) (Agent, error) {
	var out Agent
	return out, c.request(ctx, http.MethodPost, "/v1/agents/"+id+"/duplicate", nil, &out)
}
func (c *APIClient) Conversations(ctx context.Context, agentID string) ([]Conversation, error) {
	var out []Conversation
	return out, c.request(ctx, http.MethodGet, "/v1/agents/"+agentID+"/conversations", nil, &out)
}
func (c *APIClient) UpdateConversation(ctx context.Context, id, title string) (Conversation, error) {
	var out Conversation
	return out, c.request(ctx, http.MethodPatch, "/v1/conversations/"+id, map[string]string{"title": title}, &out)
}
func (c *APIClient) DeleteConversation(ctx context.Context, id string) error {
	return c.request(ctx, http.MethodDelete, "/v1/conversations/"+id, nil, nil)
}
func (c *APIClient) CreateConversation(ctx context.Context, agentID string) (Conversation, error) {
	var out Conversation
	return out, c.request(ctx, http.MethodPost, "/v1/agents/"+agentID+"/conversations", map[string]string{"title": "New conversation"}, &out)
}
func (c *APIClient) Snapshot(ctx context.Context, id string) (ConversationSnapshot, error) {
	var out ConversationSnapshot
	return out, c.request(ctx, http.MethodGet, "/v1/conversations/"+id, nil, &out)
}
func (c *APIClient) SendMessage(ctx context.Context, conversationID, content, requestID string) error {
	return c.request(ctx, http.MethodPost, "/v1/conversations/"+conversationID+"/messages", map[string]string{"content": content, "requestId": requestID}, nil)
}
func (c *APIClient) Abort(ctx context.Context, id string) error {
	return c.request(ctx, http.MethodPost, "/v1/conversations/"+id+"/abort", nil, nil)
}

// Events consumes the server-sent event stream. It returns after the context is
// canceled or the stream closes; each event payload is passed to onEvent.
func (c *APIClient) Events(ctx context.Context, id string, onEvent func(string)) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, c.BaseURL+"/v1/conversations/"+id+"/events", nil)
	if err != nil {
		return err
	}
	if c.Token != "" {
		req.Header.Set("Authorization", "Bearer "+c.Token)
	}
	resp, err := c.HTTP.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		data, _ := io.ReadAll(io.LimitReader(resp.Body, 8<<10))
		return &APIError{Method: http.MethodGet, Path: "/v1/conversations/" + id + "/events", StatusCode: resp.StatusCode, Body: strings.TrimSpace(string(data))}
	}
	scanner := bufio.NewScanner(resp.Body)
	scanner.Buffer(make([]byte, 64<<10), 8<<20)
	var data []string
	eventType := "message"
	dispatch := func() error {
		if len(data) == 0 {
			eventType = "message"
			return nil
		}
		payload := strings.Join(data, "\n")
		data = nil
		if eventType == "heartbeat" {
			eventType = "message"
			return nil
		}
		if eventType != "snapshot" && eventType != "message" {
			eventType = "message"
			return nil
		}
		var envelope struct {
			ConversationID string `json:"conversationId"`
		}
		if err := json.Unmarshal([]byte(payload), &envelope); err != nil {
			return fmt.Errorf("invalid SSE payload: %w", err)
		}
		if envelope.ConversationID == "" {
			return errors.New("snapshot event missing conversationId")
		}
		onEvent(payload)
		eventType = "message"
		return nil
	}
	for scanner.Scan() {
		line := scanner.Text()
		switch {
		case strings.HasPrefix(line, "event:"):
			eventType = strings.TrimSpace(strings.TrimPrefix(line, "event:"))
		case strings.HasPrefix(line, "data:"):
			data = append(data, strings.TrimSpace(strings.TrimPrefix(line, "data:")))
		case line == "":
			if err := dispatch(); err != nil {
				return err
			}
		case strings.HasPrefix(line, ":"):
		}
	}
	if err := scanner.Err(); err != nil {
		if ctx.Err() != nil {
			return ctx.Err()
		}
		return err
	}
	if ctx.Err() != nil {
		return ctx.Err()
	}
	if err := dispatch(); err != nil {
		return err
	}
	return ErrSSEClosed
}

func (c *APIClient) Memories(ctx context.Context, agentID string) ([]Memory, error) {
	var out []Memory
	return out, c.request(ctx, http.MethodGet, "/v1/agents/"+agentID+"/memories", nil, &out)
}
func (c *APIClient) AddMemory(ctx context.Context, agentID string, content string) (Memory, error) {
	var out Memory
	return out, c.request(ctx, http.MethodPost, "/v1/agents/"+agentID+"/memories", map[string]string{"content": content}, &out)
}
func (c *APIClient) UpdateMemory(ctx context.Context, agentID, memoryID, content string) (Memory, error) {
	var out Memory
	return out, c.request(ctx, http.MethodPatch, "/v1/agents/"+agentID+"/memories/"+memoryID, map[string]string{"content": content}, &out)
}
func (c *APIClient) DeleteMemory(ctx context.Context, agentID, memoryID string) error {
	return c.request(ctx, http.MethodDelete, "/v1/agents/"+agentID+"/memories/"+memoryID, nil, nil)
}
func (c *APIClient) Schedules(ctx context.Context) ([]Schedule, error) {
	var out []Schedule
	return out, c.request(ctx, http.MethodGet, "/v1/schedules", nil, &out)
}
func (c *APIClient) CreateSchedule(ctx context.Context, schedule Schedule) (Schedule, error) {
	var out Schedule
	return out, c.request(ctx, http.MethodPost, "/v1/schedules", schedule, &out)
}
func (c *APIClient) UpdateSchedule(ctx context.Context, id string, patch map[string]any) (Schedule, error) {
	var out Schedule
	return out, c.request(ctx, http.MethodPatch, "/v1/schedules/"+id, patch, &out)
}
func (c *APIClient) DeleteSchedule(ctx context.Context, id string) error {
	return c.request(ctx, http.MethodDelete, "/v1/schedules/"+id, nil, nil)
}
func (c *APIClient) RunSchedule(ctx context.Context, id string) (Execution, error) {
	var envelope struct {
		Admitted bool      `json:"admitted"`
		Result   Execution `json:"result"`
	}
	return envelope.Result, c.request(ctx, http.MethodPost, "/v1/schedules/"+id+"/run", nil, &envelope)
}
func (c *APIClient) Executions(ctx context.Context) ([]Execution, error) {
	var out []Execution
	return out, c.request(ctx, http.MethodGet, "/v1/executions", nil, &out)
}
func (c *APIClient) Providers(ctx context.Context) ([]ProviderStatus, error) {
	var out []ProviderStatus
	return out, c.request(ctx, http.MethodGet, "/v1/providers", nil, &out)
}
func (c *APIClient) SetProviderKey(ctx context.Context, provider, apiKey string) error {
	return c.request(ctx, http.MethodPut, "/v1/providers/"+provider, map[string]string{"apiKey": apiKey}, nil)
}
func (c *APIClient) DeleteProviderKey(ctx context.Context, provider string) error {
	return c.request(ctx, http.MethodDelete, "/v1/providers/"+provider, nil, nil)
}
func (c *APIClient) Approvals(ctx context.Context) ([]Approval, error) {
	var out []Approval
	return out, c.request(ctx, http.MethodGet, "/v1/approvals", nil, &out)
}
func (c *APIClient) DecideApproval(ctx context.Context, id, decision string) error {
	return c.request(ctx, http.MethodPost, "/v1/approvals/"+id, map[string]string{"decision": decision}, nil)
}
func (c *APIClient) MCPServers(ctx context.Context) ([]MCPServer, error) {
	var out []MCPServer
	return out, c.request(ctx, http.MethodGet, "/v1/mcp-servers", nil, &out)
}
func (c *APIClient) CreateMCPServer(ctx context.Context, server MCPServer, token string) (MCPServer, error) {
	var out MCPServer
	body := map[string]any{"name": server.Name, "url": server.URL, "enabled": server.Enabled}
	if token != "" {
		body["token"] = token
	}
	return out, c.request(ctx, http.MethodPost, "/v1/mcp-servers", body, &out)
}
func (c *APIClient) UpdateMCPServer(ctx context.Context, id string, patch map[string]any) (MCPServer, error) {
	var out MCPServer
	return out, c.request(ctx, http.MethodPatch, "/v1/mcp-servers/"+id, patch, &out)
}
func (c *APIClient) DeleteMCPServer(ctx context.Context, id string) error {
	return c.request(ctx, http.MethodDelete, "/v1/mcp-servers/"+id, nil, nil)
}
