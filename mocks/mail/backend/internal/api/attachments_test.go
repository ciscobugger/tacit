package api

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"tacit.local/mailbackend/internal/backend"
	"testing"
)

func upload(t *testing.T, h http.Handler, account, name string, data []byte) backend.Attachment {
	t.Helper()
	r := httptest.NewRequest("POST", "/v1/accounts/"+account+"/attachments?filename="+name, bytes.NewReader(data))
	r.Header.Set("Content-Type", "application/octet-stream")
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)
	if w.Code != 201 {
		t.Fatalf("upload: %d %s", w.Code, w.Body.String())
	}
	return decode[backend.Attachment](t, w)
}
func TestRawUploadLargeDownloadRangeAndReference(t *testing.T) {
	h, _ := apiTest(t)
	data := bytes.Repeat([]byte{0, 17, 255}, 4<<20)
	a := upload(t, h, "work", "large.bin", data)
	if a.Size != len(data) || a.ID == "" {
		t.Fatal(a)
	}
	d := decode[backend.Message](t, request(t, h, "POST", "/v1/drafts", map[string]any{"account_id": "work", "attachments": []any{map[string]string{"id": a.ID}}}, 201))
	path := "/v1/messages/" + d.ID + "/attachments/" + a.ID
	w := request(t, h, "GET", path, nil, 200)
	if !bytes.Equal(w.Body.Bytes(), data) {
		t.Fatal("binary changed")
	}
	r := httptest.NewRequest("GET", path, nil)
	r.Header.Set("Range", "bytes=5-19")
	w = httptest.NewRecorder()
	h.ServeHTTP(w, r)
	if w.Code != 206 || !bytes.Equal(w.Body.Bytes(), data[5:20]) {
		t.Fatalf("range: %d", w.Code)
	}
	w = request(t, h, "HEAD", path, nil, 200)
	if w.Body.Len() != 0 || w.Header().Get("Content-Length") == "" {
		t.Fatal("HEAD response")
	}
	raw, _ := json.Marshal(d)
	if strings.Contains(string(raw), `"data"`) {
		t.Fatal("binary in metadata")
	}
}
func TestUploadErrorsAndInlineDataRejected(t *testing.T) {
	h, _ := apiTest(t)
	for _, tc := range []struct {
		path, media string
		length      int64
		status      int
	}{{"/v1/accounts/work/attachments?filename=../secret", "application/octet-stream", 1, 400}, {"/v1/accounts/missing/attachments?filename=a", "application/octet-stream", 1, 404}, {"/v1/accounts/work/attachments?filename=a", "bad type", 1, 415}, {"/v1/accounts/work/attachments?filename=a", "application/octet-stream", backend.MaxAttachmentSize + 1, 413}} {
		r := httptest.NewRequest("POST", tc.path, strings.NewReader("a"))
		r.Header.Set("Content-Type", tc.media)
		r.ContentLength = tc.length
		w := httptest.NewRecorder()
		h.ServeHTTP(w, r)
		if w.Code != tc.status {
			t.Fatalf("%s: %d %s", tc.path, w.Code, w.Body.String())
		}
	}
	request(t, h, "POST", "/v1/drafts", map[string]any{"account_id": "work", "attachments": []any{map[string]any{"filename": "inline", "data": "YQ=="}}}, 400)
}
