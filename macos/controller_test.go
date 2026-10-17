package main

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/egoist/mygo/ui"
)

type dispatchQueue struct {
	mu     sync.Mutex
	values []func()
}

func (q *dispatchQueue) push(fn func()) { q.mu.Lock(); q.values = append(q.values, fn); q.mu.Unlock() }
func (q *dispatchQueue) drain() int {
	q.mu.Lock()
	values := append([]func(){}, q.values...)
	q.values = nil
	q.mu.Unlock()
	for _, fn := range values {
		fn()
	}
	return len(values)
}
func waitDispatch(t *testing.T, q *dispatchQueue) {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		if q.drain() > 0 {
			return
		}
		time.Sleep(time.Millisecond * 10)
	}
	t.Fatal("timed out waiting for UI dispatch")
}

func TestControllerConversationStreamRendersSnapshotOnUIQueue(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		switch r.URL.Path {
		case "/v1/conversations/c1":
			_, _ = io.WriteString(w, `{"conversation":{"id":"c1","title":"Chat"},"messages":[],"status":"idle"}`)
		case "/v1/conversations/c1/events":
			w.Header().Set("Content-Type", "text/event-stream")
			_, _ = io.WriteString(w, "event: snapshot\ndata: {\"conversationId\":\"c1\",\"messages\":[{\"role\":\"user\",\"content\":\"hello from stream\"}],\"status\":\"failed\",\"error\":\"provider failed\"}\n\n")
			w.(http.Flusher).Flush()
			<-r.Context().Done()
		default:
			http.NotFound(w, r)
		}
	}))
	defer srv.Close()
	q := &dispatchQueue{}
	a := &app{client: NewAPIClient(srv.URL, ""), conversationID: "c1", selected: "a1", dispatch: q.push}
	a.selectConversation("c1")
	waitDispatch(t, q) // snapshot response; this starts the SSE worker.
	waitDispatch(t, q) // SSE snapshot callback.
	if a.snapshot == nil || a.snapshot.Error != "provider failed" {
		t.Fatalf("snapshot=%+v", a.snapshot)
	}
	if !ui.NewTester(a.view, 1120, 760).HasText("hello from stream") {
		t.Fatalf("view texts did not contain stream message")
	}
	a.cancelStream()
}

func TestControllerIgnoresStaleStreamAfterConversationSwitch(t *testing.T) {
	release := make(chan struct{})
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		switch r.URL.Path {
		case "/v1/conversations/c1":
			<-release
			_, _ = io.WriteString(w, `{"conversation":{"id":"c1"},"messages":[]}`)
		case "/v1/conversations/c2":
			_, _ = io.WriteString(w, `{"conversation":{"id":"c2"},"messages":[]}`)
		default:
			http.NotFound(w, r)
		}
	}))
	defer srv.Close()
	q := &dispatchQueue{}
	a := &app{client: NewAPIClient(srv.URL, ""), dispatch: q.push}
	a.selectConversation("c1")
	a.selectConversation("c2")
	close(release)
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		q.drain()
		if a.snapshot != nil {
			break
		}
		time.Sleep(time.Millisecond * 10)
	}
	if a.conversationID != "c2" || a.snapshot == nil || a.snapshot.Conversation.ID != "c2" {
		t.Fatalf("selected=%s snapshot=%+v", a.conversationID, a.snapshot)
	}
}

func TestControllerRetriesMessageWithSameRequestIDAndRestoresDraft(t *testing.T) {
	var mu sync.Mutex
	var requestIDs []string
	attempts := 0
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/v1/conversations/c1/messages" {
			http.NotFound(w, r)
			return
		}
		payload := map[string]string{}
		_ = json.NewDecoder(r.Body).Decode(&payload)
		mu.Lock()
		requestIDs = append(requestIDs, payload["requestId"])
		attempts++
		n := attempts
		mu.Unlock()
		if n == 1 {
			http.Error(w, "temporary", http.StatusBadGateway)
			return
		}
		w.WriteHeader(http.StatusAccepted)
	}))
	defer srv.Close()
	q := &dispatchQueue{}
	a := &app{client: NewAPIClient(srv.URL, ""), dispatch: q.push, conversationID: "c1", snapshot: &ConversationSnapshot{Conversation: Conversation{ID: "c1"}}}
	a.draft = "retry me"
	a.sendMessage()
	waitDispatch(t, q)
	if a.draft != "retry me" || a.draftRequestID == "" {
		t.Fatalf("draft=%q requestID=%q", a.draft, a.draftRequestID)
	}
	first := a.draftRequestID
	a.sendMessage()
	waitDispatch(t, q)
	mu.Lock()
	defer mu.Unlock()
	if len(requestIDs) != 2 || requestIDs[0] != first || requestIDs[1] != first {
		t.Fatalf("request IDs=%v", requestIDs)
	}
}

func TestControllerSavesSkillInstructionsAndClearsCapabilities(t *testing.T) {
	var body string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		data, _ := io.ReadAll(r.Body)
		body = string(data)
		w.Header().Set("Content-Type", "application/json")
		_, _ = io.WriteString(w, `{"id":"a1","name":"Atlas","skills":[{"name":"Research","instructions":"Use primary sources"}],"tools":[],"delegates":[]}`)
	}))
	defer srv.Close()
	q := &dispatchQueue{}
	a := &app{client: NewAPIClient(srv.URL, ""), dispatch: q.push, selected: "a1", editName: "Atlas", editProvider: "openai", editModel: "gpt-4.1", editEnabled: true, editSkills: []Skill{{Name: "Research", Instructions: "Use primary sources"}}, editDelegates: map[string]bool{}, editMCP: map[string]bool{}}
	a.saveAgentEditor()
	waitDispatch(t, q)
	if !strings.Contains(body, `"skills":[{"name":"Research","instructions":"Use primary sources"}]`) || !strings.Contains(body, `"tools":[]`) || !strings.Contains(body, `"delegates":[]`) {
		t.Fatalf("payload=%s", body)
	}
}

func TestMemoryPanelRendersEntriesAndEditor(t *testing.T) {
	a := &app{selected: "a1", panel: "memory", memories: []Memory{{ID: "m1", Content: "Remember this"}}}
	if !ui.NewTester(a.view, 1120, 760).HasText("Remember this") {
		t.Fatal("memory entry missing from view")
	}
	a.memoryForm = true
	if !ui.NewTester(a.view, 1120, 760).HasText("Memory entry") {
		t.Fatal("memory editor missing from view")
	}
}
