package backend

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestStreamedAttachmentsRemainOutsideJSON(t *testing.T) {
	s, _, svc := openTest(t)
	content := bytes.Repeat([]byte{0, 255, 17, 31}, 3<<20)
	a, e := s.UploadAttachment(ctx, "work", "large.bin", "application/octet-stream", bytes.NewReader(content), int64(len(content)))
	if e != nil {
		t.Fatal(e)
	}
	d, e := s.SaveDraft(ctx, Message{AccountID: "work", To: []Address{{Email: "mara@example.com"}}, Subject: "Binary stream", Attachments: []Attachment{{ID: a.ID}}})
	if e != nil {
		t.Fatal(e)
	}
	if len(d.Attachments) != 1 || d.Attachments[0].Size != len(content) || len(d.Attachments[0].Data) != 0 {
		t.Fatalf("metadata: %+v", d.Attachments)
	}
	readAttachment(t, s, d.ID, a.ID, content)
	job, e := svc.SendDraft(ctx, d.ID, "binary-send")
	if e != nil {
		t.Fatal(e)
	}
	if _, e = svc.Flush(ctx); e != nil {
		t.Fatal(e)
	}
	for _, table := range []string{"messages", "outbox", "mock_incoming", "mock_sent"} {
		rows, e := s.db.Query("SELECT payload FROM " + table)
		if e != nil {
			t.Fatal(e)
		}
		for rows.Next() {
			var raw []byte
			if e = rows.Scan(&raw); e != nil {
				t.Fatal(e)
			}
			if bytes.Contains(raw, []byte(`"data":`)) || len(raw) > 20000 {
				t.Fatalf("binary in %s JSON", table)
			}
		}
		if e = rows.Err(); e != nil {
			t.Fatal(e)
		}
		rows.Close()
	}
	path := s.path
	s.Close()
	r, e := Open(path)
	if e != nil {
		t.Fatal(e)
	}
	defer r.Close()
	readAttachment(t, r, d.ID, a.ID, content)
	got, e := r.Job(ctx, job.ID)
	if e != nil || got.State != "sent" {
		t.Fatal(got, e)
	}
	files, e := os.ReadDir(path + ".blobs")
	if e != nil {
		t.Fatal(e)
	}
	for _, f := range files {
		info, _ := f.Info()
		if info.Mode().Perm() != 0600 {
			t.Fatalf("blob permissions: %v", info.Mode())
		}
	}
}
func readAttachment(t *testing.T, s *Store, message, attachment string, want []byte) {
	t.Helper()
	meta, r, e := s.MessageAttachment(ctx, message, attachment)
	if e != nil {
		t.Fatal(e)
	}
	defer r.Close()
	got, e := io.ReadAll(r)
	if e != nil || !bytes.Equal(got, want) || meta.Size != len(want) {
		t.Fatalf("download mismatch: %v", e)
	}
}

type brokenReader struct{}

func (brokenReader) Read(p []byte) (int, error) { return 0, io.ErrUnexpectedEOF }
func TestAttachmentValidationAndFailedUploads(t *testing.T) {
	s, _, _ := openTest(t)
	for _, tc := range []struct {
		name  string
		r     io.Reader
		limit int64
		want  error
	}{{"over limit", strings.NewReader("12345"), 4, ErrTooLarge}, {"interrupted", brokenReader{}, 100, io.ErrUnexpectedEOF}} {
		_, e := s.UploadAttachment(ctx, "work", "file.txt", "text/plain", tc.r, tc.limit)
		if !errors.Is(e, tc.want) {
			t.Fatalf("%s: %v", tc.name, e)
		}
	}
	var n int
	if e := s.db.QueryRow("SELECT count(*) FROM attachments WHERE filename='file.txt'").Scan(&n); e != nil || n != 0 {
		t.Fatal("partial upload was published", e)
	}
	matches, _ := filepath.Glob(s.path + ".blobs/.upload-*")
	if len(matches) != 0 {
		t.Fatal("temporary uploads leaked")
	}
	for _, name := range []string{"../secret", "/tmp/file", "bad\r\nname", "a\\b", ""} {
		if _, e := s.UploadAttachment(ctx, "work", name, "text/plain", strings.NewReader("a"), 10); !errors.Is(e, ErrInvalid) {
			t.Fatalf("filename %q: %v", name, e)
		}
	}
	if _, e := s.UploadAttachment(ctx, "missing", "file", "text/plain", strings.NewReader("a"), 10); !errors.Is(e, ErrNotFound) {
		t.Fatal(e)
	}
	a, e := s.UploadAttachment(ctx, "personal", "private.txt", "text/plain", strings.NewReader("private"), 100)
	if e != nil {
		t.Fatal(e)
	}
	if _, e = s.SaveDraft(ctx, Message{AccountID: "work", Attachments: []Attachment{{ID: a.ID}}}); !errors.Is(e, ErrNotFound) {
		t.Fatalf("cross-account attachment: %v", e)
	}
	d := draft(t, s, "Unrelated")
	if _, r, e := s.MessageAttachment(ctx, d.ID, a.ID); !errors.Is(e, ErrNotFound) {
		if r != nil {
			r.Close()
		}
		t.Fatal("unrelated attachment accessible", e)
	}
}
func TestMetadataDraftUpdateRetainsAttachmentBytes(t *testing.T) {
	s, _, _ := openTest(t)
	d := draft(t, s, "Original")
	raw, e := json.Marshal(d)
	if e != nil {
		t.Fatal(e)
	}
	if bytes.Contains(raw, []byte(`"data":`)) {
		t.Fatal("attachment serialised inline")
	}
	var updated Message
	if e = json.Unmarshal(raw, &updated); e != nil {
		t.Fatal(e)
	}
	updated.Subject = "Edited"
	got, e := s.SaveDraft(ctx, updated)
	if e != nil {
		t.Fatal(e)
	}
	readAttachment(t, s, got.ID, got.Attachments[0].ID, []byte("# Useful notes"))
}
func TestMigrationExtractsLegacyAttachmentsFromEveryPayload(t *testing.T) {
	path := filepath.Join(t.TempDir(), "legacy.sqlite")
	s, e := Open(path)
	if e != nil {
		t.Fatal(e)
	}
	if e = s.Seed(ctx); e != nil {
		t.Fatal(e)
	}
	d := draft(t, s, "Legacy")
	j, e := s.Queue(ctx, d.ID, "legacy-key")
	if e != nil {
		t.Fatal(e)
	}
	legacy := map[string]any{"id": d.ID, "account_id": "work", "conversation_id": "review", "from": map[string]string{"email": "lorenz@tacit.example"}, "to": []any{map[string]string{"email": "mara@example.com"}}, "subject": "Legacy", "mailbox": "Outbox", "attachments": []any{map[string]any{"id": "legacy-attachment", "filename": "old.bin", "media_type": "application/octet-stream", "size": 4, "data": base64.StdEncoding.EncodeToString([]byte{0, 1, 2, 255})}}}
	legacy["attachments"] = append(legacy["attachments"].([]any), map[string]any{"id": "legacy-empty", "filename": "empty.txt", "media_type": "text/plain", "size": 0})
	raw, _ := json.Marshal(legacy)
	for _, table := range []string{"messages", "outbox"} {
		value := d.ID
		if table == "outbox" {
			value = j.ID
		}
		if _, e = s.db.Exec("UPDATE "+table+" SET payload=? WHERE id=?", raw, value); e != nil {
			t.Fatal(e)
		}
	}
	if _, e = s.db.Exec("INSERT INTO mock_incoming(account_id,payload) VALUES('work',?)", raw); e != nil {
		t.Fatal(e)
	}
	if _, e = s.db.Exec("INSERT INTO mock_sent VALUES('legacy-sent',?, '{}')", raw); e != nil {
		t.Fatal(e)
	}
	if _, e = s.db.Exec("DELETE FROM messages WHERE id<>?", d.ID); e != nil {
		t.Fatal(e)
	}
	if _, e = s.db.Exec("DROP TABLE IF EXISTS attachments; PRAGMA user_version=1;"); e != nil {
		t.Fatal(e)
	}
	s.Close()
	s, e = Open(path)
	if e != nil {
		t.Fatal(e)
	}
	defer s.Close()
	readAttachment(t, s, d.ID, "legacy-attachment", []byte{0, 1, 2, 255})
	readAttachment(t, s, d.ID, "legacy-empty", []byte{})
	for _, table := range []string{"messages", "outbox", "mock_incoming", "mock_sent"} {
		rows, e := s.db.Query("SELECT payload FROM " + table)
		if e != nil {
			t.Fatal(e)
		}
		for rows.Next() {
			var b []byte
			rows.Scan(&b)
			if bytes.Contains(b, []byte(`"data":`)) {
				t.Fatalf("legacy data retained in %s", table)
			}
		}
		rows.Close()
	}
	var version int
	s.db.QueryRow("PRAGMA user_version").Scan(&version)
	if version != 2 {
		t.Fatal("schema version", version)
	}
}

func TestIdenticalUploadsShareOneFileButNotReferences(t *testing.T) {
	s, _, _ := openTest(t)
	before, _ := os.ReadDir(s.path + ".blobs")
	a, e := s.UploadAttachment(ctx, "work", "one.bin", "application/octet-stream", strings.NewReader("deduplicated binary"), 100)
	if e != nil {
		t.Fatal(e)
	}
	b, e := s.UploadAttachment(ctx, "personal", "two.bin", "application/octet-stream", strings.NewReader("deduplicated binary"), 100)
	if e != nil {
		t.Fatal(e)
	}
	after, _ := os.ReadDir(s.path + ".blobs")
	if a.ID == b.ID || len(after) != len(before)+1 {
		t.Fatal("content was not deduplicated with separate references")
	}
}
func TestCancelledUploadAndEmptyAttachment(t *testing.T) {
	s, _, _ := openTest(t)
	cancelled, cancel := context.WithCancel(ctx)
	cancel()
	if _, e := s.UploadAttachment(cancelled, "work", "cancelled", "text/plain", strings.NewReader("cancelled"), 100); !errors.Is(e, context.Canceled) {
		t.Fatal(e)
	}
	a, e := s.UploadAttachment(ctx, "work", "empty", "application/octet-stream", strings.NewReader(""), 0)
	if e != nil {
		t.Fatal(e)
	}
	d, e := s.SaveDraft(ctx, Message{AccountID: "work", Attachments: []Attachment{{ID: a.ID}}})
	if e != nil {
		t.Fatal(e)
	}
	readAttachment(t, s, d.ID, a.ID, []byte{})
}

func TestMigrationFailureLeavesLegacyPayloadIntact(t *testing.T) {
	path := filepath.Join(t.TempDir(), "broken-legacy.sqlite")
	s, e := Open(path)
	if e != nil {
		t.Fatal(e)
	}
	if e = s.Seed(ctx); e != nil {
		t.Fatal(e)
	}
	raw := []byte(`{"account_id":"work","attachments":[{"id":"bad","filename":"bad.bin","media_type":"application/octet-stream","data":"INVALID!"}]}`)
	if _, e = s.db.Exec("DELETE FROM messages"); e != nil {
		t.Fatal(e)
	}
	if _, e = s.db.Exec("INSERT INTO mock_incoming(account_id,payload) VALUES('work',?)", raw); e != nil {
		t.Fatal(e)
	}
	if _, e = s.db.Exec("DROP TABLE attachments; PRAGMA user_version=1"); e != nil {
		t.Fatal(e)
	}
	s.Close()
	if r, e := Open(path); e == nil {
		r.Close()
		t.Fatal("corrupt legacy data accepted")
	}
	db, e := sql.Open("sqlite", path)
	if e != nil {
		t.Fatal(e)
	}
	defer db.Close()
	var version int
	if e = db.QueryRow("PRAGMA user_version").Scan(&version); e != nil || version != 1 {
		t.Fatal("migration partially committed", version, e)
	}
	var got []byte
	if e = db.QueryRow("SELECT payload FROM mock_incoming").Scan(&got); e != nil || !bytes.Equal(got, raw) {
		t.Fatal("legacy payload changed", e)
	}
}
