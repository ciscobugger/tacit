package backend

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"
)

var ctx = context.Background()

func openTest(t *testing.T) (*Store, *MockProvider, *Service) {
	t.Helper()
	s, e := Open(filepath.Join(t.TempDir(), "mail.sqlite"))
	if e != nil {
		t.Fatal(e)
	}
	t.Cleanup(func() { s.Close() })
	if e = s.Seed(ctx); e != nil {
		t.Fatal(e)
	}
	p := &MockProvider{Store: s}
	return s, p, NewService(s, p)
}
func draft(t *testing.T, s *Store, subject string) Message {
	t.Helper()
	m, e := s.SaveDraft(ctx, Message{AccountID: "work", ConversationID: "review", From: Address{Name: "Lorenz", Email: "lorenz@tacit.example"}, To: []Address{{Email: "mara@example.com"}}, Subject: subject, BodyText: "Thanks for the palette notes.", Attachments: []Attachment{{Filename: "notes.md", MediaType: "text/markdown", Data: []byte("# Useful notes")}}})
	if e != nil {
		t.Fatal(e)
	}
	return m
}
func incoming(uid string) Message {
	return Message{RemoteID: uid, ConversationID: "external-thread", From: Address{Name: "Élodie", Email: "elodie@example.org"}, To: []Address{{Email: "lorenz@tacit.example"}}, Subject: "Ärztliche Unterlagen", BodyText: "Überweisung für Dienstag", Mailbox: "Inbox", Unread: true, Date: time.Date(2026, 11, 4, 11, 0, 0, 0, time.UTC), Attachments: []Attachment{{Filename: "Befund.pdf", MediaType: "application/pdf", Data: []byte("sample attachment")}}}
}
func TestSeedPersistsWithoutResettingLocalState(t *testing.T) {
	s, _, _ := openTest(t)
	p, e := s.List(ctx, Query{Limit: 100})
	if e != nil || p.Total < 10 {
		t.Fatalf("seed: %+v %v", p, e)
	}
	before := p.Total
	m := p.Messages[0]
	read := false
	if _, e = s.Patch(ctx, m.ID, MessagePatch{Unread: &read, Mailbox: "Archive"}); e != nil {
		t.Fatal(e)
	}
	d := draft(t, s, "Persistent draft")
	if e = s.Seed(ctx); e != nil {
		t.Fatal(e)
	}
	got, e := s.Get(ctx, m.ID)
	if e != nil || got.Unread || got.Mailbox != "Archive" {
		t.Fatalf("seed reset state: %+v %v", got, e)
	}
	after, _ := s.List(ctx, Query{Limit: 100})
	if after.Total != before+1 {
		t.Fatal("duplicate seed")
	}
	path := s.path
	s.Close()
	r, e := Open(path)
	if e != nil {
		t.Fatal(e)
	}
	defer r.Close()
	got, e = r.Get(ctx, d.ID)
	if e != nil || len(got.Attachments) != 1 {
		t.Fatalf("restart: %+v %v", got, e)
	}
	readAttachment(t, r, got.ID, got.Attachments[0].ID, []byte("# Useful notes"))
	info, _ := os.Stat(path)
	if info.Mode().Perm() != 0600 {
		t.Fatalf("database mode: %v", info.Mode())
	}
}
func TestFTSSearchFiltersAndUpdates(t *testing.T) {
	s, p, svc := openTest(t)
	if e := p.Inject(ctx, "work", incoming("search-1")); e != nil {
		t.Fatal(e)
	}
	if _, e := svc.Sync(ctx, "work"); e != nil {
		t.Fatal(e)
	}
	for _, q := range []string{"arzt", "uberweis", "Befund.pdf", "elodie"} {
		r, e := s.List(ctx, Query{AccountID: "work", Search: q})
		if e != nil || r.Total != 1 {
			t.Fatalf("%q: %+v %v", q, r, e)
		}
	}
	r, e := s.List(ctx, Query{AccountID: "personal", Search: "Befund"})
	if e != nil || r.Total != 0 {
		t.Fatal("account leaked")
	}
	for _, q := range []string{`" OR *`, `') DROP TABLE messages; --`, "", "\t  "} {
		if _, e = s.List(ctx, Query{Search: q}); e != nil {
			t.Fatalf("literal %q: %v", q, e)
		}
	}
	d := draft(t, s, "UniqueDraftWord")
	d.Subject = "ReplacementWord"
	if _, e = s.SaveDraft(ctx, d); e != nil {
		t.Fatal(e)
	}
	old, _ := s.List(ctx, Query{Search: "UniqueDraftWord"})
	fresh, _ := s.List(ctx, Query{Search: "ReplacementWord"})
	if old.Total != 0 || fresh.Total != 1 {
		t.Fatal("stale FTS index")
	}
	first, _ := s.List(ctx, Query{Limit: 2})
	next, _ := s.List(ctx, Query{Limit: 2, Offset: 2})
	if len(first.Messages) != 2 || len(next.Messages) != 2 || first.Messages[0].ID == next.Messages[0].ID {
		t.Fatal("pagination")
	}
}
func TestReceiveDeduplicatesAndCommitsCursorAtomically(t *testing.T) {
	s, p, svc := openTest(t)
	m := incoming("receive-1")
	p.Inject(ctx, "work", m)
	r, e := svc.Sync(ctx, "work")
	if e != nil || r.Received != 1 {
		t.Fatalf("sync: %+v %v", r, e)
	}
	page, _ := s.List(ctx, Query{Search: "arzt"})
	id := page.Messages[0].ID
	read := false
	s.Patch(ctx, id, MessagePatch{Unread: &read})
	m.Subject = "Updated remote subject"
	p.Inject(ctx, "work", m)
	svc.Sync(ctx, "work")
	got, _ := s.Get(ctx, id)
	if got.Subject != m.Subject || got.Unread {
		t.Fatalf("cache update: %+v", got)
	}
	r, e = svc.Sync(ctx, "work")
	if e != nil || r.Received != 0 {
		t.Fatal("cursor replayed")
	}
	cursor, _ := s.Cursor(ctx, "work")
	bad := incoming("bad")
	bad.From.Email = "invalid"
	if _, e = s.CacheBatch(ctx, "work", Batch{Messages: []Message{incoming("must-roll-back"), bad}, Cursor: "999"}); !errors.Is(e, ErrInvalid) {
		t.Fatalf("invalid batch: %v", e)
	}
	after, _ := s.Cursor(ctx, "work")
	var n int
	s.db.QueryRow("SELECT count(*) FROM messages WHERE remote_id='must-roll-back'").Scan(&n)
	if after != cursor || n != 0 {
		t.Fatal("partial cache transaction")
	}
}
func TestOutboxIsDurableAndIdempotent(t *testing.T) {
	s, _, svc := openTest(t)
	d := draft(t, s, "Send test")
	job, e := svc.SendDraft(ctx, d.ID, "send-key")
	if e != nil {
		t.Fatal(e)
	}
	same, e := svc.SendDraft(ctx, d.ID, "send-key")
	if e != nil || same.ID != job.ID {
		t.Fatal("not idempotent")
	}
	another := draft(t, s, "Other")
	if _, e = svc.SendDraft(ctx, another.ID, "send-key"); !errors.Is(e, ErrConflict) {
		t.Fatalf("key reused: %v", e)
	}
	path := s.path
	s.Close()
	r, e := Open(path)
	if e != nil {
		t.Fatal(e)
	}
	defer r.Close()
	svc = NewService(r, &MockProvider{Store: r})
	if _, e = svc.Flush(ctx); e != nil {
		t.Fatal(e)
	}
	done, _ := r.Job(ctx, job.ID)
	sent, _ := r.Get(ctx, d.ID)
	if done.State != "sent" || done.Attempts != 1 || sent.Mailbox != "Sent" || len(sent.Attachments) != 1 {
		t.Fatalf("delivery: %+v %+v", done, sent)
	}
	readAttachment(t, r, sent.ID, sent.Attachments[0].ID, []byte("# Useful notes"))
}
func TestFailureRetryAndUnknownCrashOutcome(t *testing.T) {
	s, p, svc := openTest(t)
	p.FailNext(ctx, "work")
	d := draft(t, s, "Retry")
	job, _ := svc.SendDraft(ctx, d.ID, "retry-key")
	svc.Flush(ctx)
	failed, _ := s.Job(ctx, job.ID)
	if failed.State != "failed" || failed.LastError == "" {
		t.Fatalf("failure: %+v", failed)
	}
	if e := s.Retry(ctx, job.ID); e != nil {
		t.Fatal(e)
	}
	svc.Flush(ctx)
	done, _ := s.Job(ctx, job.ID)
	if done.State != "sent" || done.Attempts != 2 {
		t.Fatal("retry failed")
	}
	d = draft(t, s, "Crash")
	job, _ = svc.SendDraft(ctx, d.ID, "crash-key")
	claimed, e := s.Claim(ctx)
	if e != nil {
		t.Fatal(e)
	}
	a, _ := s.Account(ctx, claimed.Message.AccountID)
	if _, e = p.Send(ctx, a, claimed.Message, claimed.Key); e != nil {
		t.Fatal(e)
	}
	if e = s.Recover(ctx); e != nil {
		t.Fatal(e)
	}
	svc.Flush(ctx)
	uncertain, _ := s.Job(ctx, job.ID)
	if uncertain.State != "uncertain" {
		t.Fatal("blind retry after crash")
	}
	s.Retry(ctx, job.ID)
	svc.Flush(ctx)
	var n int
	s.db.QueryRow("SELECT count(*) FROM mock_sent WHERE idempotency_key='crash-key'").Scan(&n)
	if n != 1 {
		t.Fatal("duplicate mock delivery")
	}
}
func TestConcurrentSendClaimsOnce(t *testing.T) {
	s, _, svc := openTest(t)
	d := draft(t, s, "Concurrent")
	var wg sync.WaitGroup
	errs := make(chan error, 12)
	for i := 0; i < 12; i++ {
		wg.Add(1)
		go func() { defer wg.Done(); _, e := svc.SendDraft(ctx, d.ID, "one-key"); errs <- e }()
	}
	wg.Wait()
	close(errs)
	for e := range errs {
		if e != nil {
			t.Fatal(e)
		}
	}
	for i := 0; i < 4; i++ {
		wg.Add(1)
		go func() { defer wg.Done(); svc.Flush(ctx) }()
	}
	wg.Wait()
	var n int
	s.db.QueryRow("SELECT count(*) FROM mock_sent WHERE idempotency_key='one-key'").Scan(&n)
	if n != 1 {
		t.Fatalf("sent %d copies", n)
	}
}
func TestValidationAndFutureSchema(t *testing.T) {
	s, _, _ := openTest(t)
	if _, e := s.SaveDraft(ctx, Message{AccountID: "missing"}); !errors.Is(e, ErrNotFound) {
		t.Fatalf("unknown account: %v", e)
	}
	d := draft(t, s, "Validation")
	d.To = []Address{{Email: "broken\r\nBcc: anyone@example.com"}}
	if _, e := s.SaveDraft(ctx, d); !errors.Is(e, ErrInvalid) {
		t.Fatal("header injection accepted")
	}
	s.db.Exec("PRAGMA user_version=999")
	path := s.path
	s.Close()
	if r, e := Open(path); e == nil {
		r.Close()
		t.Fatal("future schema accepted")
	}
}

func TestRemoteIdentityCannotOverwriteAnotherMessage(t *testing.T) {
	s, p, svc := openTest(t)
	page, _ := s.List(ctx, Query{Limit: 1})
	original := page.Messages[0]
	m := incoming("foreign-id")
	m.ID = original.ID
	m.AccountID = "personal"
	if e := p.Inject(ctx, "work", m); e != nil {
		t.Fatal(e)
	}
	if _, e := svc.Sync(ctx, "work"); e != nil {
		t.Fatal(e)
	}
	unchanged, _ := s.Get(ctx, original.ID)
	if unchanged.Subject != original.Subject {
		t.Fatal("remote input overwrote local identity")
	}
}
func TestPaginationValidationAndDraftLock(t *testing.T) {
	s, _, svc := openTest(t)
	for _, q := range []Query{{Limit: -1}, {Limit: 101}, {Offset: -1}} {
		if _, e := s.List(ctx, q); !errors.Is(e, ErrInvalid) {
			t.Fatal("invalid pagination accepted")
		}
	}
	d := draft(t, s, "Locked snapshot")
	if _, e := svc.SendDraft(ctx, d.ID, "locked"); e != nil {
		t.Fatal(e)
	}
	d.BodyText = "changed"
	if _, e := s.SaveDraft(ctx, d); !errors.Is(e, ErrConflict) {
		t.Fatal("queued draft remained editable")
	}
}
