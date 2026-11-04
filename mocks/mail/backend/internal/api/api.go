// Package api exposes the backend through versioned HTTP over a private Unix socket.
package api

import (
	"encoding/json"
	"errors"
	"io"
	"mime"
	"net/http"
	"strconv"
	"tacit.local/mailbackend/internal/backend"
	"time"
)

func metadata(m backend.Message) backend.Message {
	a := append([]backend.Attachment{}, m.Attachments...)
	for i := range a {
		a[i].Data = nil
	}
	m.Attachments = a
	return m
}
func New(s *backend.Service, p *backend.MockProvider) http.Handler {
	mux := http.NewServeMux()
	store := s.Store
	respond := func(w http.ResponseWriter, v any, e error) {
		if e != nil {
			status := 500
			switch {
			case errors.Is(e, backend.ErrTooLarge):
				status = 413
			case errors.Is(e, backend.ErrInvalid):
				status = 400
			case errors.Is(e, backend.ErrNotFound):
				status = 404
			case errors.Is(e, backend.ErrConflict):
				status = 409
			}
			message := http.StatusText(status)
			if status != 500 {
				message = e.Error()
			}
			http.Error(w, message, status)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(v)
	}
	parse := func(w http.ResponseWriter, r *http.Request, v any) bool {
		kind, _, e := mime.ParseMediaType(r.Header.Get("Content-Type"))
		if e != nil || kind != "application/json" {
			http.Error(w, "application/json required", 415)
			return false
		}
		r.Body = http.MaxBytesReader(w, r.Body, 8<<20)
		d := json.NewDecoder(r.Body)
		d.DisallowUnknownFields()
		if e = d.Decode(v); e != nil {
			http.Error(w, "invalid JSON", 400)
			return false
		}
		if e = d.Decode(&struct{}{}); e != io.EOF {
			http.Error(w, "one JSON object required", 400)
			return false
		}
		return true
	}
	mux.HandleFunc("GET /v1/health", func(w http.ResponseWriter, r *http.Request) {
		respond(w, map[string]any{"status": "ok", "api_version": 1, "provider": "mock"}, nil)
	})
	mux.HandleFunc("GET /v1/accounts", func(w http.ResponseWriter, r *http.Request) { v, e := store.Accounts(r.Context()); respond(w, v, e) })
	mux.HandleFunc("GET /v1/messages", func(w http.ResponseWriter, r *http.Request) {
		q := r.URL.Query()
		query := backend.Query{AccountID: q.Get("account_id"), Mailbox: q.Get("mailbox"), Search: q.Get("q")}
		for name, target := range map[string]*int{"limit": &query.Limit, "offset": &query.Offset} {
			if raw := q.Get(name); raw != "" {
				n, e := strconv.Atoi(raw)
				if e != nil {
					respond(w, nil, backend.ErrInvalid)
					return
				}
				*target = n
			}
		}
		v, e := store.List(r.Context(), query)
		for i := range v.Messages {
			v.Messages[i] = metadata(v.Messages[i])
		}
		respond(w, v, e)
	})
	mux.HandleFunc("GET /v1/messages/{id}", func(w http.ResponseWriter, r *http.Request) {
		v, e := store.Get(r.Context(), r.PathValue("id"))
		respond(w, metadata(v), e)
	})
	mux.HandleFunc("PATCH /v1/messages/{id}", func(w http.ResponseWriter, r *http.Request) {
		var patch backend.MessagePatch
		if !parse(w, r, &patch) {
			return
		}
		v, e := store.Patch(r.Context(), r.PathValue("id"), patch)
		respond(w, metadata(v), e)
	})
	mux.HandleFunc("GET /v1/conversations/{id}", func(w http.ResponseWriter, r *http.Request) {
		v, e := store.Conversation(r.Context(), r.URL.Query().Get("account_id"), r.PathValue("id"))
		for i := range v {
			v[i] = metadata(v[i])
		}
		respond(w, v, e)
	})
	mux.HandleFunc("POST /v1/accounts/{account}/attachments", func(w http.ResponseWriter, r *http.Request) {
		kind, params, e := mime.ParseMediaType(r.Header.Get("Content-Type"))
		if e != nil {
			http.Error(w, "valid Content-Type required", 415)
			return
		}
		if r.ContentLength > backend.MaxAttachmentSize {
			respond(w, nil, backend.ErrTooLarge)
			return
		}
		a, e := store.UploadAttachment(r.Context(), r.PathValue("account"), r.URL.Query().Get("filename"), mime.FormatMediaType(kind, params), r.Body, backend.MaxAttachmentSize)
		if e != nil {
			respond(w, nil, e)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(201)
		json.NewEncoder(w).Encode(a)
	})
	mux.HandleFunc("GET /v1/messages/{id}/attachments/{attachment}", func(w http.ResponseWriter, r *http.Request) {
		a, f, e := store.MessageAttachment(r.Context(), r.PathValue("id"), r.PathValue("attachment"))
		if e != nil {
			respond(w, nil, e)
			return
		}
		defer f.Close()
		w.Header().Set("Content-Type", a.MediaType)
		w.Header().Set("Content-Disposition", mime.FormatMediaType("attachment", map[string]string{"filename": a.Filename}))
		w.Header().Set("X-Content-Type-Options", "nosniff")
		http.ServeContent(w, r, a.Filename, time.Time{}, f)
	})

	save := func(w http.ResponseWriter, r *http.Request) {
		var m backend.Message
		if !parse(w, r, &m) {
			return
		}
		if r.Method == "PUT" {
			m.ID = r.PathValue("id")
		} else if m.ID != "" {
			respond(w, nil, backend.ErrInvalid)
			return
		}
		if m.AccountID == "" {
			respond(w, nil, backend.ErrInvalid)
			return
		}
		v, e := store.SaveDraft(r.Context(), m)
		if e != nil {
			respond(w, nil, e)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		if r.Method == "POST" {
			w.WriteHeader(201)
		}
		json.NewEncoder(w).Encode(metadata(v))
	}
	mux.HandleFunc("POST /v1/drafts", save)
	mux.HandleFunc("PUT /v1/drafts/{id}", save)
	mux.HandleFunc("POST /v1/send", func(w http.ResponseWriter, r *http.Request) {
		var in struct {
			DraftID string `json:"draft_id"`
			Key     string `json:"idempotency_key"`
		}
		if !parse(w, r, &in) {
			return
		}
		v, e := s.SendDraft(r.Context(), in.DraftID, in.Key)
		if e != nil {
			respond(w, nil, e)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(202)
		json.NewEncoder(w).Encode(v)
	})
	mux.HandleFunc("GET /v1/outbox/{id}", func(w http.ResponseWriter, r *http.Request) {
		v, e := store.Job(r.Context(), r.PathValue("id"))
		respond(w, v, e)
	})
	mux.HandleFunc("POST /v1/outbox/{id}/retry", func(w http.ResponseWriter, r *http.Request) {
		var in struct{}
		if !parse(w, r, &in) {
			return
		}
		e := store.Retry(r.Context(), r.PathValue("id"))
		respond(w, map[string]bool{"queued": e == nil}, e)
	})
	mux.HandleFunc("POST /v1/sync", func(w http.ResponseWriter, r *http.Request) {
		var in struct {
			AccountID string `json:"account_id"`
		}
		if !parse(w, r, &in) {
			return
		}
		v, e := s.Sync(r.Context(), in.AccountID)
		respond(w, v, e)
	})
	mux.HandleFunc("POST /v1/mock/incoming", func(w http.ResponseWriter, r *http.Request) {
		var in struct {
			AccountID string          `json:"account_id"`
			Message   backend.Message `json:"message"`
		}
		if !parse(w, r, &in) {
			return
		}
		e := p.Inject(r.Context(), in.AccountID, in.Message)
		if e != nil {
			respond(w, nil, e)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(201)
		json.NewEncoder(w).Encode(map[string]bool{"accepted": true})
	})
	mux.HandleFunc("POST /v1/mock/fail-next-send", func(w http.ResponseWriter, r *http.Request) {
		var in struct {
			AccountID string `json:"account_id"`
		}
		if !parse(w, r, &in) {
			return
		}
		e := p.FailNext(r.Context(), in.AccountID)
		respond(w, map[string]bool{"armed": e == nil}, e)
	})
	mux.HandleFunc("POST /v1/mock/flush", func(w http.ResponseWriter, r *http.Request) {
		var in struct{}
		if !parse(w, r, &in) {
			return
		}
		n, e := s.Flush(r.Context())
		respond(w, map[string]int{"processed": n}, e)
	})
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Cache-Control", "no-store")
		if r.Header.Get("Origin") != "" {
			http.Error(w, "browser origins are not supported", 403)
			return
		}
		mux.ServeHTTP(w, r)
	})
}
