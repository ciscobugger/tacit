package api

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"tacit.local/mailbackend/internal/backend"
	"testing"
	"time"
)

func apiTest(t *testing.T) (http.Handler, *backend.Store) {
	t.Helper()
	s, e := backend.Open(filepath.Join(t.TempDir(), "mail.sqlite"))
	if e != nil {
		t.Fatal(e)
	}
	t.Cleanup(func() { s.Close() })
	if e = s.Seed(context.Background()); e != nil {
		t.Fatal(e)
	}
	p := &backend.MockProvider{Store: s}
	return New(backend.NewService(s, p), p), s
}
func request(t *testing.T, h http.Handler, method, path string, body any, want int) *httptest.ResponseRecorder {
	t.Helper()
	var b bytes.Buffer
	if body != nil {
		json.NewEncoder(&b).Encode(body)
	}
	r := httptest.NewRequest(method, path, &b)
	if body != nil {
		r.Header.Set("Content-Type", "application/json")
	}
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)
	if w.Code != want {
		t.Fatalf("%s %s: %d %s", method, path, w.Code, w.Body.String())
	}
	return w
}
func decode[T any](t *testing.T, w *httptest.ResponseRecorder) T {
	t.Helper()
	var v T
	if e := json.Unmarshal(w.Body.Bytes(), &v); e != nil {
		t.Fatal(e)
	}
	return v
}
func TestAPIReceiveSearchDraftSendAndAttachments(t *testing.T) {
	h, s := apiTest(t)
	request(t, h, "GET", "/v1/health", nil, 200)
	a := upload(t, h, "work", "sample.txt", []byte("sample"))
	incoming := map[string]any{"account_id": "work", "message": map[string]any{"remote_id": "api-remote", "conversation_id": "api-thread", "from": map[string]string{"email": "new@example.org", "name": "New sender"}, "subject": "API search needle", "body_text": "A local received message", "mailbox": "Inbox", "unread": true, "attachments": []any{map[string]string{"id": a.ID}}}}
	request(t, h, "POST", "/v1/mock/incoming", incoming, 201)
	request(t, h, "POST", "/v1/sync", map[string]string{"account_id": "work"}, 200)
	p := decode[backend.Page](t, request(t, h, "GET", "/v1/messages?q=needle&account_id=work", nil, 200))
	if p.Total != 1 {
		t.Fatal("search did not receive message")
	}
	m := decode[backend.Message](t, request(t, h, "GET", "/v1/messages/"+p.Messages[0].ID, nil, 200))
	if len(m.Attachments) != 1 || len(m.Attachments[0].Data) != 0 {
		t.Fatal("message response should return attachment metadata, not blobs")
	}
	w := request(t, h, "GET", "/v1/messages/"+m.ID+"/attachments/"+m.Attachments[0].ID, nil, 200)
	if w.Body.String() != "sample" || w.Header().Get("Content-Disposition") == "" {
		t.Fatal("attachment content")
	}
	request(t, h, "PATCH", "/v1/messages/"+m.ID, map[string]any{"unread": false}, 200)
	conv := decode[[]backend.Message](t, request(t, h, "GET", "/v1/conversations/api-thread?account_id=work", nil, 200))
	if len(conv) != 1 {
		t.Fatal("conversation")
	}
	d := decode[backend.Message](t, request(t, h, "POST", "/v1/drafts", map[string]any{"account_id": "work", "conversation_id": "api-thread", "to": []any{map[string]string{"email": "new@example.org"}}, "subject": "Re: API search needle", "body_text": "An explicit mock reply"}, 201))
	job := decode[backend.Job](t, request(t, h, "POST", "/v1/send", map[string]string{"draft_id": d.ID, "idempotency_key": "api-send"}, 202))
	request(t, h, "POST", "/v1/mock/flush", map[string]any{}, 200)
	done := decode[backend.Job](t, request(t, h, "GET", "/v1/outbox/"+job.ID, nil, 200))
	if done.State != "sent" {
		t.Fatalf("job: %+v", done)
	}
	stored, _ := s.Get(context.Background(), d.ID)
	if stored.Mailbox != "Sent" {
		t.Fatal("not cached in Sent")
	}
}
func TestAPIRejectsBadInputAndBrowserOrigins(t *testing.T) {
	h, _ := apiTest(t)
	request(t, h, "GET", "/v1/messages?limit=no", nil, 400)
	request(t, h, "GET", "/v1/messages/missing", nil, 404)
	request(t, h, "POST", "/v1/send", map[string]string{"draft_id": "missing"}, 400)
	for _, body := range []string{`{"unknown":true}`, `{} {}`, `{"body_text":`} {
		r := httptest.NewRequest("POST", "/v1/drafts", bytes.NewBufferString(body))
		r.Header.Set("Content-Type", "application/json")
		w := httptest.NewRecorder()
		h.ServeHTTP(w, r)
		if w.Code != 400 {
			t.Fatalf("accepted %q: %d", body, w.Code)
		}
	}
	r := httptest.NewRequest("GET", "/v1/messages", nil)
	r.Header.Set("Origin", "https://example.org")
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)
	if w.Code != 403 {
		t.Fatal("browser origin accepted")
	}
	r = httptest.NewRequest("POST", "/v1/drafts", bytes.NewBufferString(`{}`))
	w = httptest.NewRecorder()
	h.ServeHTTP(w, r)
	if w.Code != 415 {
		t.Fatal("non-JSON accepted")
	}
}
func TestPrivateUnixSocketAndActualHTTPClient(t *testing.T) {
	h, _ := apiTest(t)
	dir, e := os.MkdirTemp("/tmp", "mail-ipc-")
	if e != nil {
		t.Fatal(e)
	}
	defer os.RemoveAll(dir)
	socket := filepath.Join(dir, "mail.sock")
	listener, e := Listen(socket)
	if e != nil {
		t.Fatal(e)
	}
	srv := &http.Server{Handler: h}
	go srv.Serve(listener)
	defer srv.Close()
	info, _ := os.Stat(socket)
	if info.Mode().Perm() != 0600 {
		t.Fatalf("socket mode %v", info.Mode())
	}
	if other, e := Listen(socket); e == nil {
		other.Close()
		t.Fatal("second server replaced live socket")
	}
	client := &http.Client{Transport: &http.Transport{DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
		return (&net.Dialer{}).DialContext(ctx, "unix", socket)
	}}, Timeout: time.Second}
	defer client.CloseIdleConnections()
	response, e := client.Get("http://localhost/v1/health")
	if e != nil {
		t.Fatal(e)
	}
	defer response.Body.Close()
	b, _ := io.ReadAll(response.Body)
	if response.StatusCode != 200 || !bytes.Contains(b, []byte("ok")) {
		t.Fatalf("real socket: %d %s", response.StatusCode, b)
	}
}
