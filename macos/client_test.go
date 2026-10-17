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

func TestAPIClientEventsParsesSSEData(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		_, _ = w.Write([]byte("event: snapshot\ndata: {\"conversationId\":\"c1\",\ndata: \"status\":\"running\"}\n\n"))
	}))
	defer srv.Close()
	var got string
	err := NewAPIClient(srv.URL, "").Events(context.Background(), "c1", func(event string) { got = event })
	if !errors.Is(err, ErrSSEClosed) {
		t.Fatal(err)
	}
	if got != "{\"conversationId\":\"c1\",\n\"status\":\"running\"}" {
		t.Fatalf("event=%q", got)
	}
}

func TestAPIClientEventsIgnoresHeartbeatAndValidatesSnapshot(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		_, _ = w.Write([]byte("event: heartbeat\ndata: {}\n\nevent: snapshot\ndata: {\"conversationId\":\"c9\",\ndata: \"messages\": [1,2]}\n\n"))
	}))
	defer srv.Close()
	var events []string
	err := NewAPIClient(srv.URL, "").Events(context.Background(), "c9", func(event string) { events = append(events, event) })
	if !errors.Is(err, ErrSSEClosed) || len(events) != 1 || !strings.Contains(events[0], "c9") {
		t.Fatalf("err=%v events=%v", err, events)
	}
}

func TestAPIClientEventsCancellationReturnsContextError(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { <-r.Context().Done() }))
	defer srv.Close()
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	err := NewAPIClient(srv.URL, "").Events(ctx, "c1", func(string) {})
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

func TestScheduleRunEnvelopeAndMessageContract(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		switch {
		case r.Method == http.MethodPost && r.URL.Path == "/v1/schedules/s1/run":
			w.Header().Set("Content-Type", "application/json")
			_, _ = w.Write([]byte(`{"admitted":true,"result":{"id":"e1","status":"pending"}}`))
		case r.Method == http.MethodPost && r.URL.Path == "/v1/agents/a1/conversations":
			if !strings.Contains(string(body), `"title":"New conversation"`) {
				t.Fatalf("conversation body=%s", body)
			}
			w.Header().Set("Content-Type", "application/json")
			_, _ = w.Write([]byte(`{"id":"c1","title":"New conversation"}`))
		case r.Method == http.MethodPost && r.URL.Path == "/v1/conversations/c1/messages":
			if !strings.Contains(string(body), `"content":"hello"`) || !strings.Contains(string(body), `"requestId":"req"`) {
				t.Fatalf("message body=%s", body)
			}
			w.WriteHeader(http.StatusAccepted)
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
	if _, err = cli.CreateConversation(context.Background(), "a1"); err != nil {
		t.Fatal(err)
	}
	if err = cli.SendMessage(context.Background(), "c1", "hello", "req"); err != nil {
		t.Fatal(err)
	}
}
