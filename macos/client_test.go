package main

import (
	"context"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"regexp"
	"strings"
	"testing"
)

func TestNewRequestIDIsUUID(t *testing.T) {
	if !regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$`).MatchString(newRequestID()) {
		t.Fatalf("invalid UUID: %s", newRequestID())
	}
}

func TestValidateTaskRequiresExactlyOneScheduleMode(t *testing.T) {
	if validateTask("", "", "", "") == "" {
		t.Fatal("empty task should fail")
	}
	if validateTask("Daily", "Check inbox", "0 9 * * *", "2026-10-18T09:00:00Z") == "" {
		t.Fatal("cron and runAt together should fail")
	}
	if validateTask("Daily", "Check inbox", "0 9 * * *", "") != "" {
		t.Fatal("valid cron task rejected")
	}
	if validateTask("Once", "Check inbox", "", "2026-10-18T09:00:00Z") != "" {
		t.Fatal("valid one-time task rejected")
	}
}

func TestUpdateAgentCanClearCapabilities(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		if !strings.Contains(string(body), `"tools":[]`) || !strings.Contains(string(body), `"skills":[]`) {
			t.Fatalf("body=%s", body)
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"id":"a1"}`))
	}))
	defer srv.Close()
	_, err := NewAPIClient(srv.URL, "").UpdateAgent(context.Background(), "a1", map[string]any{"tools": []string{}, "skills": []Skill{}})
	if err != nil {
		t.Fatal(err)
	}
}

func TestAPIClientAgentsAddsBearerAndDecodes(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/v1/agents" || r.Header.Get("Authorization") != "Bearer test-token" {
			t.Fatalf("request %s auth=%q", r.URL, r.Header.Get("Authorization"))
		}
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(`[{"id":"a1","name":"Atlas","enabled":true}]`))
	}))
	defer srv.Close()
	agents, err := NewAPIClient(srv.URL, "test-token").Agents(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if len(agents) != 1 || agents[0].ID != "a1" || agents[0].Name != "Atlas" {
		t.Fatalf("agents=%+v", agents)
	}
}

func TestAgentInference(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.URL.Path == "/v1/agents" && r.Method == http.MethodPost:
			w.Header().Set("Content-Type", "application/json")
			_, _ = io.WriteString(w, `{"id":"a1","name":"A","inference":{"thinkingLevel":"max","temperature":0.2,"maxOutputTokens":42}}`)
		default:
			t.Fatalf("unexpected %s %s", r.Method, r.URL.RequestURI())
		}
	}))
	defer srv.Close()
	cli := NewAPIClient(srv.URL, "")
	level := "max"
	temp := 0.2
	tokens := 42
	agent, err := cli.CreateAgent(context.Background(), Agent{Inference: &Inference{ThinkingLevel: level, Temperature: &temp, MaxOutputTokens: &tokens}})
	if err != nil || agent.Inference == nil || agent.Inference.ThinkingLevel != level {
		t.Fatalf("agent=%+v err=%v", agent, err)
	}
}

func TestAPIClientModelsEscapesProvider(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Query().Get("provider") != "open ai" {
			t.Fatalf("query=%s", r.URL.RawQuery)
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = io.WriteString(w, `[{"provider":"open ai","id":"m1","name":"Model","contextWindow":1000,"reasoning":true}]`)
	}))
	defer srv.Close()
	models, err := NewAPIClient(srv.URL, "").Models(context.Background(), "open ai")
	if err != nil || len(models) != 1 || !models[0].Reasoning {
		t.Fatalf("models=%+v err=%v", models, err)
	}
}

func TestAPIClientEventsParsesSSEData(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		_, _ = w.Write([]byte("event: snapshot\ndata: {\"agentId\":\"a1\",\ndata: \"status\":\"running\"}\n\n"))
	}))
	defer srv.Close()
	var got string
	err := NewAPIClient(srv.URL, "").ChatEvents(context.Background(), "a1", func(event string) { got = event })
	if !errors.Is(err, ErrSSEClosed) {
		t.Fatal(err)
	}
	if got != "{\"agentId\":\"a1\",\n\"status\":\"running\"}" {
		t.Fatalf("event=%q", got)
	}
}

func TestAPIClientEventsIgnoresHeartbeatAndValidatesSnapshot(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		_, _ = w.Write([]byte("event: heartbeat\ndata: {}\n\nevent: snapshot\ndata: {\"agentId\":\"a9\",\ndata: \"messages\": [1,2]}\n\n"))
	}))
	defer srv.Close()
	var events []string
	err := NewAPIClient(srv.URL, "").ChatEvents(context.Background(), "a9", func(event string) { events = append(events, event) })
	if !errors.Is(err, ErrSSEClosed) || len(events) != 1 || !strings.Contains(events[0], "a9") {
		t.Fatalf("err=%v events=%v", err, events)
	}
}

func TestAPIClientEventsCancellationReturnsContextError(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { <-r.Context().Done() }))
	defer srv.Close()
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	err := NewAPIClient(srv.URL, "").ChatEvents(ctx, "a1", func(string) {})
	if !errors.Is(err, context.Canceled) {
		t.Fatalf("err=%v", err)
	}
}

func TestAPIErrorContainsStatusAndBody(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { http.Error(w, "bad token", http.StatusUnauthorized) }))
	defer srv.Close()
	_, err := NewAPIClient(srv.URL, "").Agents(context.Background())
	var apiErr *APIError
	if !errors.As(err, &apiErr) || apiErr.StatusCode != http.StatusUnauthorized || apiErr.Body != "bad token" {
		t.Fatalf("err=%#v", err)
	}
}

func TestScheduleRunEnvelope(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.Method == http.MethodPost && r.URL.Path == "/v1/schedules/s1/run":
			w.Header().Set("Content-Type", "application/json")
			_, _ = w.Write([]byte(`{"admitted":true,"result":{"id":"e1","status":"pending"}}`))
		default:
			t.Fatalf("unexpected %s %s", r.Method, r.URL.Path)
		}
	}))
	defer srv.Close()
	cli := NewAPIClient(srv.URL, "")
	execution, err := cli.RunSchedule(context.Background(), "s1")
	if err != nil || execution.ID != "e1" {
		t.Fatalf("execution=%+v err=%v", execution, err)
	}
}

func TestCanonicalChatContracts(t *testing.T) {
	var historyQuery string
	var messageBody string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		switch r.URL.Path {
		case "/v1/agents/a1/chat":
			w.Header().Set("Content-Type", "application/json")
			_, _ = io.WriteString(w, `{"agentId":"a1","messages":[],"status":"idle","hasMore":true,"oldestEntryId":"a1:9"}`)
		case "/v1/agents/a1/chat/history":
			historyQuery = r.URL.RawQuery
			w.Header().Set("Content-Type", "application/json")
			_, _ = io.WriteString(w, `{"messages":[{"entryId":"a1:8","role":"user","content":"older"}],"hasMore":false,"oldestEntryId":"a1:8"}`)
		case "/v1/agents/a1/messages":
			messageBody = string(body)
			w.WriteHeader(http.StatusAccepted)
		case "/v1/agents/a1/abort", "/v1/agents/a1/compact":
			w.WriteHeader(http.StatusNoContent)
		default:
			http.NotFound(w, r)
		}
	}))
	defer srv.Close()
	cli := NewAPIClient(srv.URL, "")
	chat, err := cli.Chat(context.Background(), "a1")
	if err != nil || chat.AgentID != "a1" || !chat.HasMore || chat.OldestEntryID != "a1:9" {
		t.Fatalf("chat=%+v err=%v", chat, err)
	}
	history, err := cli.ChatHistory(context.Background(), "a1", "a1:42", 100)
	if err != nil || history.Messages[0].EntryID != "a1:8" || history.HasMore {
		t.Fatalf("history=%+v err=%v", history, err)
	}
	if historyQuery != "before=a1%3A42&limit=100" {
		t.Fatalf("query=%q", historyQuery)
	}
	if err = cli.SendChatMessage(context.Background(), "a1", "hello", "req", "a1:41"); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(messageBody, `"replyTo":"a1:41"`) {
		t.Fatalf("body=%s", messageBody)
	}
	if err = cli.AbortChat(context.Background(), "a1"); err != nil {
		t.Fatal(err)
	}
	if err = cli.CompactChat(context.Background(), "a1"); err != nil {
		t.Fatal(err)
	}
}

func TestCanonicalChatEventsUseAgentRoute(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/v1/agents/a7/events" {
			t.Fatalf("path=%s", r.URL.Path)
		}
		w.Header().Set("Content-Type", "text/event-stream")
		_, _ = io.WriteString(w, "event: snapshot\ndata: {\"agentId\":\"a7\",\"messages\":[]}\n\n")
		w.(http.Flusher).Flush()
	}))
	defer srv.Close()
	var payload string
	err := NewAPIClient(srv.URL, "").ChatEvents(context.Background(), "a7", func(data string) { payload = data })
	if !errors.Is(err, ErrSSEClosed) || !strings.Contains(payload, `"agentId":"a7"`) {
		t.Fatalf("err=%v payload=%q", err, payload)
	}
}
