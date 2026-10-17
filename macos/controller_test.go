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

func TestControllerChatStreamRendersSnapshotOnUIQueue(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		switch r.URL.Path {
		case "/v1/agents/a1/chat":
			_, _ = io.WriteString(w, `{"agentId":"a1","messages":[],"status":"idle"}`)
		case "/v1/agents/a1/events":
			w.Header().Set("Content-Type", "text/event-stream")
			_, _ = io.WriteString(w, "event: snapshot\ndata: {\"agentId\":\"a1\",\"messages\":[{\"id\":\"a1:1:0\",\"entryId\":\"a1:1\",\"role\":\"user\",\"content\":\"hello from stream\"}],\"status\":\"failed\",\"error\":\"provider failed\"}\n\n")
			w.(http.Flusher).Flush()
			<-r.Context().Done()
		default:
			http.NotFound(w, r)
		}
	}))
	defer srv.Close()
	q := &dispatchQueue{}
	a := &app{client: NewAPIClient(srv.URL, ""), dispatch: q.push}
	a.selectAgent("a1")
	waitDispatch(t, q) // chat response; this starts the SSE worker.
	waitDispatch(t, q) // SSE snapshot callback.
	if a.snapshot == nil || a.snapshot.Error != "provider failed" {
		t.Fatalf("snapshot=%+v", a.snapshot)
	}
	if !ui.NewTester(a.view, 1120, 760).HasText("hello from stream") {
		t.Fatalf("view texts did not contain stream message")
	}
	a.cancelStream()
}

func TestControllerIgnoresStaleChatAfterAgentSwitch(t *testing.T) {
	release := make(chan struct{})
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		switch r.URL.Path {
		case "/v1/agents/a1/chat":
			<-release
			_, _ = io.WriteString(w, `{"agentId":"a1","messages":[{"id":"a1:1:0","role":"user","content":"stale"}]}`)
		case "/v1/agents/a2/chat":
			_, _ = io.WriteString(w, `{"agentId":"a2","messages":[]}`)
		case "/v1/agents/a1/events", "/v1/agents/a2/events":
			<-r.Context().Done()
		default:
			http.NotFound(w, r)
		}
	}))
	defer srv.Close()
	q := &dispatchQueue{}
	a := &app{client: NewAPIClient(srv.URL, ""), dispatch: q.push}
	a.selectAgent("a1")
	a.selectAgent("a2")
	close(release)
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) && a.activeRequests > 0 {
		q.drain()
		time.Sleep(time.Millisecond * 10)
	}
	if a.selected != "a2" || a.snapshot == nil || a.snapshot.AgentID != "a2" || len(a.messages) != 0 {
		t.Fatalf("selected=%s snapshot=%+v messages=%+v", a.selected, a.snapshot, a.messages)
	}
	a.cancelStream()
}

func TestControllerRetriesMessageWithSameRequestIDAndRestoresDraft(t *testing.T) {
	var mu sync.Mutex
	var requestIDs []string
	var replies []string
	attempts := 0
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/v1/agents/a1/messages" {
			http.NotFound(w, r)
			return
		}
		payload := map[string]string{}
		_ = json.NewDecoder(r.Body).Decode(&payload)
		mu.Lock()
		requestIDs = append(requestIDs, payload["requestId"])
		replies = append(replies, payload["replyTo"])
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
	a := &app{client: NewAPIClient(srv.URL, ""), dispatch: q.push, selected: "a1", snapshot: &ChatSnapshot{AgentID: "a1"}}
	a.startReply(Message{ID: "a1:4:0", EntryID: "a1:4", Role: "assistant", Content: "earlier"})
	a.draft = "retry me"
	a.sendMessage()
	waitDispatch(t, q)
	if a.draft != "retry me" || a.draftRequestID == "" || a.replyTo == nil {
		t.Fatalf("draft=%q requestID=%q reply=%v", a.draft, a.draftRequestID, a.replyTo)
	}
	first := a.draftRequestID
	a.sendMessage()
	waitDispatch(t, q)
	mu.Lock()
	defer mu.Unlock()
	if len(requestIDs) != 2 || requestIDs[0] != first || requestIDs[1] != first {
		t.Fatalf("request IDs=%v", requestIDs)
	}
	if replies[0] != "a1:4" || replies[1] != "a1:4" || a.replyTo != nil {
		t.Fatalf("replies=%v reply=%v", replies, a.replyTo)
	}
}

func TestControllerKeepsLoadedHistoryAcrossSnapshots(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/v1/agents/a1/chat/history" || r.URL.Query().Get("before") != "a1:10" {
			t.Errorf("unexpected %s", r.URL.RequestURI())
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = io.WriteString(w, `{"messages":[{"id":"a1:2:0","entryId":"a1:2","role":"user","content":"oldest"},{"id":"a1:3:0","entryId":"a1:3","role":"assistant","content":"older"}],"hasMore":false,"oldestEntryId":"a1:2"}`)
	}))
	defer srv.Close()
	q := &dispatchQueue{}
	a := &app{client: NewAPIClient(srv.URL, ""), dispatch: q.push, selected: "a1", hasMore: true, oldestEntryID: "a1:10"}
	a.applySnapshot(ChatSnapshot{AgentID: "a1", Messages: []Message{{ID: "a1:10:0", Role: "user", Content: "newer"}}})
	a.loadOlder()
	waitDispatch(t, q)
	// The next snapshot's newest page no longer includes "newer"; loaded rows must survive.
	a.applySnapshot(ChatSnapshot{AgentID: "a1", Messages: []Message{{ID: "a1:11:0", Role: "assistant", Content: "newest"}}})
	var got []string
	for _, message := range a.messages {
		got = append(got, contentText(message.Content))
	}
	if strings.Join(got, ",") != "oldest,older,newer,newest" || a.hasMore {
		t.Fatalf("messages=%v hasMore=%v", got, a.hasMore)
	}
	tester := ui.NewTester(a.view, 1120, 760)
	if !tester.HasText("oldest") || tester.HasText("Load earlier messages") {
		t.Fatal("history view did not render loaded page")
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
