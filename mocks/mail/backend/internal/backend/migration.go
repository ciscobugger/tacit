package backend

import (
	"context"
	"encoding/json"
)

func (s *Store) migrateAttachments() error {
	ctx := context.Background()
	tx, e := s.db.BeginTx(ctx, nil)
	if e != nil {
		return e
	}
	defer tx.Rollback()
	if _, e = tx.ExecContext(ctx, `CREATE TABLE attachments(id TEXT PRIMARY KEY,account_id TEXT NOT NULL REFERENCES accounts(id),filename TEXT NOT NULL,media_type TEXT NOT NULL,size INTEGER NOT NULL CHECK(size>=0),digest TEXT NOT NULL); CREATE INDEX attachments_account_idx ON attachments(account_id);`); e != nil {
		return e
	}
	for _, table := range []string{"messages", "outbox", "mock_incoming", "mock_sent"} {
		rows, e := tx.QueryContext(ctx, "SELECT rowid,payload FROM "+table)
		if e != nil {
			return e
		}
		type entry struct {
			row int64
			raw []byte
		}
		all := []entry{}
		for rows.Next() {
			var x entry
			if e = rows.Scan(&x.row, &x.raw); e != nil {
				rows.Close()
				return e
			}
			all = append(all, x)
		}
		e = rows.Err()
		rows.Close()
		if e != nil {
			return e
		}
		for _, x := range all {
			var m Message
			if e = json.Unmarshal(x.raw, &m); e != nil {
				return e
			}
			var legacy struct {
				Attachments []struct {
					Data []byte `json:"data"`
				}
			}
			if e = json.Unmarshal(x.raw, &legacy); e != nil {
				return e
			}
			for i, a := range legacy.Attachments {
				m.Attachments[i].Data = append([]byte{}, a.Data...)
			}
			m, e = s.prepareAttachments(ctx, tx, m)
			if e != nil {
				return e
			}
			raw, e := json.Marshal(m)
			if e != nil {
				return e
			}
			if _, e = tx.ExecContext(ctx, "UPDATE "+table+" SET payload=? WHERE rowid=?", raw, x.row); e != nil {
				return e
			}
		}
	}
	if _, e = tx.ExecContext(ctx, `PRAGMA user_version=2`); e != nil {
		return e
	}
	return tx.Commit()
}
