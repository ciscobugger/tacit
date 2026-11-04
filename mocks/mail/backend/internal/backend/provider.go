package backend

import (
	"context"
	"encoding/json"
	"fmt"
	"strconv"
	"sync"
	"time"
)

// Provider isolates remote transport from the durable local cache.
type Provider interface {
	Receive(context.Context, Account, string) (Batch, error)
	Send(context.Context, Account, Message, string) (Receipt, error)
}
type MockProvider struct{ Store *Store }

func (p *MockProvider) Inject(ctx context.Context, account string, m Message) error {
	if _, e := p.Store.Account(ctx, account); e != nil {
		return e
	}
	if m.RemoteID == "" || validate(m) != nil {
		return ErrInvalid
	}
	m.AccountID = account
	m = normalise(m)
	tx, e := p.Store.db.BeginTx(ctx, nil)
	if e != nil {
		return e
	}
	defer tx.Rollback()
	m, e = p.Store.prepareAttachments(ctx, tx, m)
	if e != nil {
		return e
	}
	b, e := json.Marshal(m)
	if e != nil {
		return e
	}
	if _, e = tx.ExecContext(ctx, `INSERT INTO mock_incoming(account_id,payload) VALUES(?,?)`, account, b); e != nil {
		return e
	}
	return tx.Commit()
}
func (p *MockProvider) Receive(ctx context.Context, a Account, cursor string) (Batch, error) {
	b := Batch{Cursor: cursor, Messages: []Message{}}
	n, e := strconv.ParseInt(cursor, 10, 64)
	if e != nil || n < 0 {
		return b, ErrInvalid
	}
	rows, e := p.Store.db.QueryContext(ctx, `SELECT seq,payload FROM mock_incoming WHERE account_id=? AND seq>? ORDER BY seq LIMIT 101`, a.ID, n)
	if e != nil {
		return b, e
	}
	defer rows.Close()
	for rows.Next() {
		var seq int64
		var data []byte
		if e = rows.Scan(&seq, &data); e != nil {
			return b, e
		}
		if len(b.Messages) == 100 {
			b.HasMore = true
			break
		}
		var m Message
		if e = json.Unmarshal(data, &m); e != nil {
			return b, e
		}
		b.Messages = append(b.Messages, m)
		b.Cursor = strconv.FormatInt(seq, 10)
	}
	return b, rows.Err()
}
func (p *MockProvider) FailNext(ctx context.Context, account string) error {
	if _, e := p.Store.Account(ctx, account); e != nil {
		return e
	}
	_, e := p.Store.db.ExecContext(ctx, `INSERT INTO mock_failures VALUES(?,1) ON CONFLICT(account_id) DO UPDATE SET pending=pending+1`, account)
	return e
}
func (p *MockProvider) Send(ctx context.Context, a Account, m Message, key string) (Receipt, error) {
	tx, e := p.Store.db.BeginTx(ctx, nil)
	if e != nil {
		return Receipt{}, e
	}
	defer tx.Rollback()
	var data []byte
	e = tx.QueryRowContext(ctx, `SELECT receipt FROM mock_sent WHERE idempotency_key=?`, key).Scan(&data)
	if e == nil {
		var r Receipt
		e = json.Unmarshal(data, &r)
		return r, e
	}
	if mapped(e) != ErrNotFound {
		return Receipt{}, e
	}
	var pending int
	e = tx.QueryRowContext(ctx, `SELECT pending FROM mock_failures WHERE account_id=?`, a.ID).Scan(&pending)
	if e != nil && mapped(e) != ErrNotFound {
		return Receipt{}, e
	}
	if pending > 0 {
		if _, e = tx.ExecContext(ctx, `UPDATE mock_failures SET pending=pending-1 WHERE account_id=?`, a.ID); e != nil {
			return Receipt{}, e
		}
		if e = tx.Commit(); e != nil {
			return Receipt{}, e
		}
		return Receipt{}, fmt.Errorf("simulated provider failure")
	}
	r := Receipt{RemoteID: "mock-sent-" + id(), SentAt: time.Now().UTC()}
	data, e = json.Marshal(r)
	if e != nil {
		return r, e
	}
	payload, e := json.Marshal(m)
	if e != nil {
		return r, e
	}
	_, e = tx.ExecContext(ctx, `INSERT INTO mock_sent VALUES(?,?,?)`, key, payload, data)
	if e != nil {
		return r, e
	}
	return r, tx.Commit()
}

type Service struct {
	Store    *Store
	provider Provider
	flushMu  sync.Mutex
	syncMu   sync.Mutex
}

func NewService(s *Store, p Provider) *Service { return &Service{Store: s, provider: p} }
func (s *Service) Sync(ctx context.Context, account string) (SyncResult, error) {
	s.syncMu.Lock()
	defer s.syncMu.Unlock()
	a, e := s.Store.Account(ctx, account)
	if e != nil {
		return SyncResult{}, e
	}
	c, e := s.Store.Cursor(ctx, account)
	if e != nil {
		return SyncResult{}, e
	}
	b, e := s.provider.Receive(ctx, a, c)
	if e != nil {
		return SyncResult{}, e
	}
	return s.Store.CacheBatch(ctx, account, b)
}
func (s *Service) SendDraft(ctx context.Context, draft, key string) (Job, error) {
	return s.Store.Queue(ctx, draft, key)
}
func (s *Service) Flush(ctx context.Context) (int, error) {
	s.flushMu.Lock()
	defer s.flushMu.Unlock()
	count := 0
	for {
		if e := ctx.Err(); e != nil {
			return count, e
		}
		j, e := s.Store.Claim(ctx)
		if e == ErrNotFound {
			return count, nil
		}
		if e != nil {
			return count, e
		}
		a, e := s.Store.Account(ctx, j.Message.AccountID)
		if e != nil {
			return count, e
		}
		r, sendErr := s.provider.Send(ctx, a, j.Message, j.Key)
		if e = s.Store.finish(ctx, j, r, sendErr); e != nil {
			return count, e
		}
		count++
	}
}
