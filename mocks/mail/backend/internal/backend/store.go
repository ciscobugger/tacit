package backend

import (
	"context"
	"crypto/rand"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	_ "modernc.org/sqlite"
	"net/mail"
	"os"
	"path/filepath"
	"strings"
	"time"
)

type Store struct {
	db   *sql.DB
	path string
}

func id() string {
	var b [16]byte
	if _, e := rand.Read(b[:]); e != nil {
		panic(e)
	}
	return hex.EncodeToString(b[:])
}
func Open(path string) (*Store, error) {
	if e := os.MkdirAll(filepath.Dir(path), 0700); e != nil {
		return nil, e
	}
	f, e := os.OpenFile(path, os.O_CREATE|os.O_RDWR, 0600)
	if e != nil {
		return nil, e
	}
	f.Close()
	if e = os.Chmod(path, 0600); e != nil {
		return nil, e
	}
	db, e := sql.Open("sqlite", path)
	if e != nil {
		return nil, e
	}
	db.SetMaxOpenConns(1)
	s := &Store{db, path}
	if e = s.init(); e != nil {
		db.Close()
		return nil, e
	}
	return s, nil
}
func (s *Store) Close() error { return s.db.Close() }
func (s *Store) init() error {
	if _, e := s.db.Exec(`PRAGMA foreign_keys=ON; PRAGMA busy_timeout=5000; PRAGMA journal_mode=WAL;`); e != nil {
		return e
	}
	var v int
	if e := s.db.QueryRow(`PRAGMA user_version`).Scan(&v); e != nil {
		return e
	}
	if v > 2 {
		return fmt.Errorf("database schema %d is newer than supported version 2", v)
	}
	if v == 2 {
		return nil
	}
	if v == 1 {
		return s.migrateAttachments()
	}
	tx, e := s.db.Begin()
	if e != nil {
		return e
	}
	defer tx.Rollback()
	_, e = tx.Exec(`
 CREATE TABLE accounts(id TEXT PRIMARY KEY,name TEXT NOT NULL,email TEXT NOT NULL,provider TEXT NOT NULL);
 CREATE TABLE metadata(key TEXT PRIMARY KEY,value TEXT NOT NULL);
 CREATE TABLE messages(id TEXT PRIMARY KEY,account_id TEXT NOT NULL REFERENCES accounts(id),remote_id TEXT,conversation_id TEXT NOT NULL,mailbox TEXT NOT NULL,date TEXT NOT NULL,payload BLOB NOT NULL,search_text TEXT NOT NULL,UNIQUE(account_id,remote_id));
 CREATE INDEX conversation_idx ON messages(account_id,conversation_id,date);
 CREATE INDEX mailbox_idx ON messages(account_id,mailbox,date);
 CREATE VIRTUAL TABLE search USING fts5(message_id UNINDEXED,content,tokenize='unicode61 remove_diacritics 2');
 CREATE TABLE cursors(account_id TEXT PRIMARY KEY REFERENCES accounts(id),cursor TEXT NOT NULL);
 CREATE TABLE outbox(id TEXT PRIMARY KEY,message_id TEXT NOT NULL REFERENCES messages(id),idempotency_key TEXT NOT NULL UNIQUE,state TEXT NOT NULL,attempts INTEGER NOT NULL DEFAULT 0,last_error TEXT NOT NULL DEFAULT '',payload BLOB NOT NULL);
 CREATE TABLE mock_incoming(seq INTEGER PRIMARY KEY AUTOINCREMENT,account_id TEXT NOT NULL REFERENCES accounts(id),payload BLOB NOT NULL);
 CREATE TABLE mock_sent(idempotency_key TEXT PRIMARY KEY,payload BLOB NOT NULL,receipt BLOB NOT NULL);
 CREATE TABLE mock_failures(account_id TEXT PRIMARY KEY REFERENCES accounts(id),pending INTEGER NOT NULL);
 PRAGMA user_version=1;`)
	if e != nil {
		return e
	}
	if e = tx.Commit(); e != nil {
		return e
	}
	return s.migrateAttachments()
}
func mapped(e error) error {
	if errors.Is(e, sql.ErrNoRows) {
		return ErrNotFound
	}
	return e
}
func (s *Store) Account(ctx context.Context, id string) (Account, error) {
	var a Account
	e := s.db.QueryRowContext(ctx, `SELECT id,name,email,provider FROM accounts WHERE id=?`, id).Scan(&a.ID, &a.Name, &a.Email, &a.Provider)
	return a, mapped(e)
}
func (s *Store) Accounts(ctx context.Context) ([]Account, error) {
	rows, e := s.db.QueryContext(ctx, `SELECT id,name,email,provider FROM accounts ORDER BY id`)
	if e != nil {
		return nil, e
	}
	defer rows.Close()
	a := []Account{}
	for rows.Next() {
		var x Account
		if e = rows.Scan(&x.ID, &x.Name, &x.Email, &x.Provider); e != nil {
			return nil, e
		}
		a = append(a, x)
	}
	return a, rows.Err()
}
func validAddress(a Address) bool {
	if strings.ContainsAny(a.Name+a.Email, "\r\n") {
		return false
	}
	parsed, e := mail.ParseAddress(a.Email)
	return e == nil && parsed.Address == a.Email
}
func validate(m Message) error {
	if !validAddress(m.From) || strings.ContainsAny(m.Subject, "\r\n") {
		return ErrInvalid
	}
	for _, list := range [][]Address{m.To, m.Cc, m.Bcc} {
		for _, a := range list {
			if !validAddress(a) {
				return ErrInvalid
			}
		}
	}
	for _, a := range m.Attachments {
		if a.ID == "" && !validAttachment(a.Filename, defaultMediaType(a.MediaType)) {
			return ErrInvalid
		}
	}
	return nil
}
func normalise(m Message) Message {
	if m.ID == "" {
		m.ID = id()
	}
	if m.ConversationID == "" {
		m.ConversationID = m.ID
	}
	if m.Date.IsZero() {
		m.Date = time.Now().UTC()
	}
	if m.Attachments == nil {
		m.Attachments = []Attachment{}
	}
	for i := range m.Attachments {
		a := &m.Attachments[i]
		if a.ID == "" {
			a.ID = id()
		}
		if a.Data != nil {
			a.Size = len(a.Data)
		}
		if a.MediaType == "" {
			a.MediaType = "application/octet-stream"
		}
	}
	return m
}
func (s *Store) write(ctx context.Context, tx *sql.Tx, m Message) error {
	var e error
	m, e = s.prepareAttachments(ctx, tx, m)
	if e != nil {
		return e
	}
	b, e := json.Marshal(m)
	if e != nil {
		return e
	}
	search := m.Subject + " " + m.BodyText + " " + m.From.Name + " " + m.From.Email
	for _, a := range append(append(append([]Address{}, m.To...), m.Cc...), m.Bcc...) {
		search += " " + a.Name + " " + a.Email
	}
	for _, a := range m.Attachments {
		search += " " + a.Filename
	}
	_, e = tx.ExecContext(ctx, `INSERT INTO messages(id,account_id,remote_id,conversation_id,mailbox,date,payload,search_text) VALUES(?,?,NULLIF(?,''),?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET remote_id=excluded.remote_id,conversation_id=excluded.conversation_id,mailbox=excluded.mailbox,date=excluded.date,payload=excluded.payload,search_text=excluded.search_text`, m.ID, m.AccountID, m.RemoteID, m.ConversationID, m.Mailbox, m.Date.UTC().Format(time.RFC3339Nano), b, search)
	if e != nil {
		return e
	}
	if _, e = tx.ExecContext(ctx, `DELETE FROM search WHERE message_id=?`, m.ID); e != nil {
		return e
	}
	_, e = tx.ExecContext(ctx, `INSERT INTO search(message_id,content) VALUES(?,?)`, m.ID, search)
	return e
}
func read(ctx context.Context, q interface {
	QueryRowContext(context.Context, string, ...any) *sql.Row
}, id string) (Message, error) {
	var b []byte
	var m Message
	e := q.QueryRowContext(ctx, `SELECT payload FROM messages WHERE id=?`, id).Scan(&b)
	if e != nil {
		return m, mapped(e)
	}
	e = json.Unmarshal(b, &m)
	return m, e
}
func (s *Store) Get(ctx context.Context, id string) (Message, error) { return read(ctx, s.db, id) }
func (s *Store) SaveDraft(ctx context.Context, m Message) (Message, error) {
	a, e := s.Account(ctx, m.AccountID)
	if e != nil {
		return m, e
	}
	if m.From.Email == "" {
		m.From = Address{a.Name, a.Email}
	}
	if m.From.Email != a.Email {
		return m, ErrInvalid
	}
	if e = validate(m); e != nil {
		return m, e
	}
	tx, e := s.db.BeginTx(ctx, nil)
	if e != nil {
		return m, e
	}
	defer tx.Rollback()
	if m.ID != "" {
		old, e := read(ctx, tx, m.ID)
		if e != nil {
			return m, e
		}
		if old.Mailbox != "Drafts" || old.AccountID != m.AccountID {
			return m, ErrConflict
		}
	}
	m = normalise(m)
	m.Mailbox = "Drafts"
	m.Unread = false
	m, e = s.prepareAttachments(ctx, tx, m)
	if e != nil {
		return m, e
	}
	if e = s.write(ctx, tx, m); e != nil {
		return m, e
	}
	return m, tx.Commit()
}
func (s *Store) Patch(ctx context.Context, id string, p MessagePatch) (Message, error) {
	tx, e := s.db.BeginTx(ctx, nil)
	if e != nil {
		return Message{}, e
	}
	defer tx.Rollback()
	m, e := read(ctx, tx, id)
	if e != nil {
		return m, e
	}
	if p.Unread != nil {
		m.Unread = *p.Unread
	}
	if p.Flagged != nil {
		m.Flagged = *p.Flagged
	}
	if p.Mailbox != "" {
		switch p.Mailbox {
		case "Inbox", "Archive", "Trash", "Junk":
		default:
			return m, ErrInvalid
		}
		if m.Mailbox == "Outbox" || m.Mailbox == "Drafts" {
			return m, ErrConflict
		}
		m.Mailbox = p.Mailbox
	}
	if e = s.write(ctx, tx, m); e != nil {
		return m, e
	}
	return m, tx.Commit()
}
func (s *Store) List(ctx context.Context, q Query) (Page, error) {
	p := Page{Messages: []Message{}, Limit: q.Limit, Offset: q.Offset}
	if p.Limit == 0 {
		p.Limit = 50
	}
	if p.Limit < 1 || p.Limit > 100 || p.Offset < 0 {
		return p, ErrInvalid
	}
	where := " WHERE 1=1"
	args := []any{}
	if q.AccountID != "" {
		where += " AND account_id=?"
		args = append(args, q.AccountID)
	}
	if q.Mailbox != "" {
		where += " AND mailbox=?"
		args = append(args, q.Mailbox)
	}
	if fields := strings.Fields(q.Search); len(fields) > 0 {
		for i, f := range fields {
			fields[i] = `"` + strings.ReplaceAll(f, `"`, `""`) + `"*`
		}
		where += ` AND id IN (SELECT message_id FROM search WHERE search MATCH ?)`
		args = append(args, strings.Join(fields, " AND "))
	}
	if e := s.db.QueryRowContext(ctx, `SELECT count(*) FROM messages`+where, args...).Scan(&p.Total); e != nil {
		return p, e
	}
	args = append(args, p.Limit, p.Offset)
	rows, e := s.db.QueryContext(ctx, `SELECT payload FROM messages`+where+` ORDER BY date DESC,id DESC LIMIT ? OFFSET ?`, args...)
	if e != nil {
		return p, e
	}
	defer rows.Close()
	for rows.Next() {
		var b []byte
		var m Message
		if e = rows.Scan(&b); e != nil {
			return p, e
		}
		if e = json.Unmarshal(b, &m); e != nil {
			return p, e
		}
		p.Messages = append(p.Messages, m)
	}
	return p, rows.Err()
}
func (s *Store) Conversation(ctx context.Context, account, conversation string) ([]Message, error) {
	if account == "" {
		return nil, ErrInvalid
	}
	rows, e := s.db.QueryContext(ctx, `SELECT payload FROM messages WHERE account_id=? AND conversation_id=? ORDER BY date,id`, account, conversation)
	if e != nil {
		return nil, e
	}
	defer rows.Close()
	out := []Message{}
	for rows.Next() {
		var b []byte
		var m Message
		if e = rows.Scan(&b); e != nil {
			return nil, e
		}
		if e = json.Unmarshal(b, &m); e != nil {
			return nil, e
		}
		out = append(out, m)
	}
	return out, rows.Err()
}
func (s *Store) Cursor(ctx context.Context, account string) (string, error) {
	var c string
	e := s.db.QueryRowContext(ctx, `SELECT cursor FROM cursors WHERE account_id=?`, account).Scan(&c)
	if errors.Is(e, sql.ErrNoRows) {
		return "0", nil
	}
	return c, e
}
func (s *Store) CacheBatch(ctx context.Context, account string, b Batch) (SyncResult, error) {
	r := SyncResult{Cursor: b.Cursor, HasMore: b.HasMore}
	if _, e := s.Account(ctx, account); e != nil {
		return r, e
	}
	for _, m := range b.Messages {
		if m.RemoteID == "" || validate(m) != nil {
			return r, ErrInvalid
		}
	}
	tx, e := s.db.BeginTx(ctx, nil)
	if e != nil {
		return r, e
	}
	defer tx.Rollback()
	for _, m := range b.Messages {
		m.AccountID = account
		var existing string
		e = tx.QueryRowContext(ctx, `SELECT id FROM messages WHERE account_id=? AND remote_id=?`, account, m.RemoteID).Scan(&existing)
		if e == nil {
			old, e := read(ctx, tx, existing)
			if e != nil {
				return r, e
			}
			m.ID = old.ID
			m.Unread = old.Unread
			m.Flagged = old.Flagged
			m.Mailbox = old.Mailbox
		} else if !errors.Is(e, sql.ErrNoRows) {
			return r, e
		} else {
			m.ID = id()
		}
		m = normalise(m)
		if m.Mailbox == "" {
			m.Mailbox = "Inbox"
		}
		if e = s.write(ctx, tx, m); e != nil {
			return r, e
		}
		r.Received++
	}
	_, e = tx.ExecContext(ctx, `INSERT INTO cursors VALUES(?,?) ON CONFLICT(account_id) DO UPDATE SET cursor=excluded.cursor`, account, b.Cursor)
	if e != nil {
		return r, e
	}
	return r, tx.Commit()
}
