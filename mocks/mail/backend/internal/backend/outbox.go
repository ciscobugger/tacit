package backend

import (
	"context"
	"database/sql"
	"encoding/json"
	"strings"
)

func job(ctx context.Context, q interface {
	QueryRowContext(context.Context, string, ...any) *sql.Row
}, where string, arg string) (Job, error) {
	var j Job
	var b []byte
	e := q.QueryRowContext(ctx, `SELECT id,message_id,idempotency_key,state,attempts,last_error,payload FROM outbox WHERE `+where+`=?`, arg).Scan(&j.ID, &j.MessageID, &j.Key, &j.State, &j.Attempts, &j.LastError, &b)
	if e != nil {
		return j, mapped(e)
	}
	e = json.Unmarshal(b, &j.Message)
	return j, e
}
func (s *Store) Job(ctx context.Context, id string) (Job, error) { return job(ctx, s.db, "id", id) }
func (s *Store) Queue(ctx context.Context, draft, key string) (Job, error) {
	if strings.TrimSpace(key) == "" || len(key) > 200 {
		return Job{}, ErrInvalid
	}
	tx, e := s.db.BeginTx(ctx, nil)
	if e != nil {
		return Job{}, e
	}
	defer tx.Rollback()
	existing, e := job(ctx, tx, "idempotency_key", key)
	if e == nil {
		if existing.MessageID != draft {
			return Job{}, ErrConflict
		}
		return existing, nil
	}
	if e != ErrNotFound {
		return Job{}, e
	}
	m, e := read(ctx, tx, draft)
	if e != nil {
		return Job{}, e
	}
	if m.Mailbox != "Drafts" {
		return Job{}, ErrConflict
	}
	if len(m.To)+len(m.Cc)+len(m.Bcc) == 0 || validate(m) != nil {
		return Job{}, ErrInvalid
	}
	j := Job{ID: id(), MessageID: m.ID, Key: key, State: "queued", Message: m}
	b, e := json.Marshal(m)
	if e != nil {
		return j, e
	}
	_, e = tx.ExecContext(ctx, `INSERT INTO outbox(id,message_id,idempotency_key,state,payload) VALUES(?,?,?,?,?)`, j.ID, m.ID, key, j.State, b)
	if e != nil {
		return j, e
	}
	m.Mailbox = "Outbox"
	if e = s.write(ctx, tx, m); e != nil {
		return j, e
	}
	return j, tx.Commit()
}
func (s *Store) Claim(ctx context.Context) (Job, error) {
	tx, e := s.db.BeginTx(ctx, nil)
	if e != nil {
		return Job{}, e
	}
	defer tx.Rollback()
	var next string
	if e = tx.QueryRowContext(ctx, `SELECT id FROM outbox WHERE state='queued' ORDER BY rowid LIMIT 1`).Scan(&next); e != nil {
		return Job{}, mapped(e)
	}
	if _, e = tx.ExecContext(ctx, `UPDATE outbox SET state='sending',attempts=attempts+1 WHERE id=?`, next); e != nil {
		return Job{}, e
	}
	j, e := job(ctx, tx, "id", next)
	if e != nil {
		return j, e
	}
	return j, tx.Commit()
}
func (s *Store) finish(ctx context.Context, j Job, r Receipt, sendErr error) error {
	tx, e := s.db.BeginTx(ctx, nil)
	if e != nil {
		return e
	}
	defer tx.Rollback()
	state, last := "sent", ""
	if sendErr != nil {
		state = "failed"
		last = sendErr.Error()
	} else {
		m, e := read(ctx, tx, j.MessageID)
		if e != nil {
			return e
		}
		m.Mailbox = "Sent"
		m.RemoteID = r.RemoteID
		m.Date = r.SentAt
		m.Unread = false
		if e = s.write(ctx, tx, m); e != nil {
			return e
		}
	}
	if _, e = tx.ExecContext(ctx, `UPDATE outbox SET state=?,last_error=? WHERE id=? AND state='sending'`, state, last, j.ID); e != nil {
		return e
	}
	return tx.Commit()
}
func (s *Store) Retry(ctx context.Context, id string) error {
	r, e := s.db.ExecContext(ctx, `UPDATE outbox SET state='queued',last_error='' WHERE id=? AND state IN ('failed','uncertain')`, id)
	if e != nil {
		return e
	}
	n, e := r.RowsAffected()
	if e != nil {
		return e
	}
	if n == 0 {
		if _, e = s.Job(ctx, id); e != nil {
			return e
		}
		return ErrConflict
	}
	return nil
}

// Recover must run only after this process has acquired the exclusive socket.
func (s *Store) Recover(ctx context.Context) error {
	_, e := s.db.ExecContext(ctx, `UPDATE outbox SET state='uncertain',last_error='Delivery outcome unknown after interruption; explicit retry required' WHERE state='sending'`)
	return e
}
