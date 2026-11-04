package backend

import (
	"bytes"
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"mime"
	"os"
	"path/filepath"
	"strings"
)

const MaxAttachmentSize int64 = 256 << 20

var ErrTooLarge = errors.New("attachment exceeds size limit")

func validAttachment(name, mediaType string) bool {
	if name == "" || name == "." || name == ".." || len(name) > 255 || strings.ContainsAny(name, "/\\\r\n\x00") {
		return false
	}
	for _, r := range name {
		if r < 32 || r == 127 {
			return false
		}
	}
	_, _, e := mime.ParseMediaType(mediaType)
	return e == nil && !strings.ContainsAny(mediaType, "\r\n")
}

type contextReader struct {
	ctx context.Context
	r   io.Reader
}

func (r contextReader) Read(b []byte) (int, error) {
	if e := r.ctx.Err(); e != nil {
		return 0, e
	}
	return r.r.Read(b)
}

// putBlob publishes only complete, synced files. The digest is never a user-supplied path.
func (s *Store) putBlob(ctx context.Context, r io.Reader, limit int64) (string, int, error) {
	if limit < 0 || limit > MaxAttachmentSize {
		return "", 0, ErrInvalid
	}
	dir := s.path + ".blobs"
	if e := os.MkdirAll(dir, 0700); e != nil {
		return "", 0, e
	}
	f, e := os.CreateTemp(dir, ".upload-")
	if e != nil {
		return "", 0, e
	}
	defer os.Remove(f.Name())
	defer f.Close()
	h := sha256.New()
	n, e := io.CopyBuffer(io.MultiWriter(f, h), io.LimitReader(contextReader{ctx, r}, limit+1), make([]byte, 64<<10))
	if e != nil {
		return "", 0, e
	}
	if n > limit {
		return "", 0, ErrTooLarge
	}
	if e = ctx.Err(); e != nil {
		return "", 0, e
	}
	if e = f.Sync(); e != nil {
		return "", 0, e
	}
	if e = f.Close(); e != nil {
		return "", 0, e
	}
	digest := hex.EncodeToString(h.Sum(nil))
	target := filepath.Join(dir, digest)
	if e = os.Link(f.Name(), target); e != nil && !errors.Is(e, os.ErrExist) {
		return "", 0, e
	}
	if e = os.Remove(f.Name()); e != nil {
		return "", 0, e
	}
	d, e := os.Open(dir)
	if e != nil {
		return "", 0, e
	}
	e = d.Sync()
	closeErr := d.Close()
	if e != nil {
		return "", 0, e
	}
	if closeErr != nil {
		return "", 0, closeErr
	}
	return digest, int(n), nil
}
func attachment(ctx context.Context, q interface {
	QueryRowContext(context.Context, string, ...any) *sql.Row
}, account, id string) (Attachment, string, error) {
	var a Attachment
	var hash string
	e := q.QueryRowContext(ctx, `SELECT id,filename,media_type,size,digest FROM attachments WHERE id=? AND account_id=?`, id, account).Scan(&a.ID, &a.Filename, &a.MediaType, &a.Size, &hash)
	return a, hash, mapped(e)
}
func (s *Store) insertAttachment(ctx context.Context, tx *sql.Tx, account string, a Attachment, r io.Reader, limit int64) (Attachment, error) {
	if a.MediaType == "" {
		a.MediaType = "application/octet-stream"
	}
	if !validAttachment(a.Filename, a.MediaType) {
		return Attachment{}, ErrInvalid
	}
	digest, size, e := s.putBlob(ctx, r, limit)
	if e != nil {
		return Attachment{}, e
	}
	if a.ID == "" {
		a.ID = id()
	}
	old, hash, e := attachment(ctx, tx, account, a.ID)
	if e == nil {
		if hash != digest || old.Filename != a.Filename || old.MediaType != a.MediaType {
			return Attachment{}, ErrConflict
		}
		return old, nil
	}
	if e != ErrNotFound {
		return Attachment{}, e
	}
	a.Data = nil
	a.Size = size
	_, e = tx.ExecContext(ctx, `INSERT INTO attachments(id,account_id,filename,media_type,size,digest) VALUES(?,?,?,?,?,?)`, a.ID, account, a.Filename, a.MediaType, a.Size, digest)
	return a, e
}

// UploadAttachment streams raw bytes into the private cache and returns an immutable reference.
func (s *Store) UploadAttachment(ctx context.Context, account, name, mediaType string, r io.Reader, limit int64) (Attachment, error) {
	if _, e := s.Account(ctx, account); e != nil {
		return Attachment{}, e
	}
	if mediaType == "" {
		mediaType = "application/octet-stream"
	}
	if !validAttachment(name, mediaType) {
		return Attachment{}, ErrInvalid
	}
	// Copy before opening a transaction, so slow uploads do not hold the SQLite connection.
	digest, size, e := s.putBlob(ctx, r, limit)
	if e != nil {
		return Attachment{}, e
	}
	a := Attachment{ID: id(), Filename: name, MediaType: mediaType, Size: size}
	_, e = s.db.ExecContext(ctx, `INSERT INTO attachments(id,account_id,filename,media_type,size,digest) VALUES(?,?,?,?,?,?)`, a.ID, account, name, mediaType, size, digest)
	return a, e
}
func (s *Store) prepareAttachments(ctx context.Context, tx *sql.Tx, m Message) (Message, error) {
	result := make([]Attachment, 0, len(m.Attachments))
	seen := map[string]bool{}
	for _, a := range m.Attachments {
		var e error
		if a.Data != nil || a.ID == "" {
			a, e = s.insertAttachment(ctx, tx, m.AccountID, a, bytes.NewReader(a.Data), MaxAttachmentSize)
		} else {
			a, _, e = attachment(ctx, tx, m.AccountID, a.ID)
		}
		if e != nil {
			return m, e
		}
		if seen[a.ID] {
			return m, ErrInvalid
		}
		seen[a.ID] = true
		result = append(result, a)
	}
	m.Attachments = result
	return m, nil
}

// OpenAttachment is the streaming boundary for future provider/MIME adapters.
func (s *Store) OpenAttachment(ctx context.Context, account, id string) (Attachment, *os.File, error) {
	a, digest, e := attachment(ctx, s.db, account, id)
	if e != nil {
		return a, nil, e
	}
	decoded, e := hex.DecodeString(digest)
	if e != nil || len(decoded) != sha256.Size {
		return a, nil, fmt.Errorf("invalid blob digest")
	}
	f, e := os.Open(filepath.Join(s.path+".blobs", digest))
	if e != nil {
		return a, nil, e
	}
	info, e := f.Stat()
	if e != nil || !info.Mode().IsRegular() || info.Size() != int64(a.Size) {
		f.Close()
		return a, nil, fmt.Errorf("attachment cache is incomplete")
	}
	return a, f, nil
}
func (s *Store) MessageAttachment(ctx context.Context, messageID, attachmentID string) (Attachment, *os.File, error) {
	m, e := s.Get(ctx, messageID)
	if e != nil {
		return Attachment{}, nil, e
	}
	for _, a := range m.Attachments {
		if a.ID == attachmentID {
			return s.OpenAttachment(ctx, m.AccountID, a.ID)
		}
	}
	return Attachment{}, nil, ErrNotFound
}

func defaultMediaType(v string) string {
	if v == "" {
		return "application/octet-stream"
	}
	return v
}
