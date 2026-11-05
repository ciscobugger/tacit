package backend

import (
	"errors"
	"time"
)

var ErrInvalid = errors.New("invalid input")
var ErrNotFound = errors.New("not found")
var ErrConflict = errors.New("conflict")

type Address struct {
	Name  string `json:"name,omitempty"`
	Email string `json:"email"`
}
type Attachment struct {
	ID        string `json:"id"`
	Filename  string `json:"filename"`
	MediaType string `json:"media_type"`
	Size      int    `json:"size"`
	// Data is only an in-process fixture/import convenience. JSON uses immutable IDs.
	Data []byte `json:"-"`
}
type Message struct {
	ID             string       `json:"id"`
	AccountID      string       `json:"account_id"`
	RemoteID       string       `json:"remote_id,omitempty"`
	ConversationID string       `json:"conversation_id"`
	MessageID      string       `json:"message_id,omitempty"`
	InReplyTo      string       `json:"in_reply_to,omitempty"`
	References     []string     `json:"references,omitempty"`
	From           Address      `json:"from"`
	To             []Address    `json:"to"`
	Cc             []Address    `json:"cc,omitempty"`
	Bcc            []Address    `json:"bcc,omitempty"`
	Subject        string       `json:"subject"`
	BodyText       string       `json:"body_text"`
	BodyHTML       string       `json:"body_html,omitempty"`
	Mailbox        string       `json:"mailbox"`
	Unread         bool         `json:"unread"`
	Flagged        bool         `json:"flagged"`
	Date           time.Time    `json:"date"`
	Attachments    []Attachment `json:"attachments"`
}
type Account struct {
	ID       string `json:"id"`
	Name     string `json:"name"`
	Email    string `json:"email"`
	Provider string `json:"provider"`
}
type MessagePatch struct {
	Unread  *bool  `json:"unread,omitempty"`
	Flagged *bool  `json:"flagged,omitempty"`
	Mailbox string `json:"mailbox,omitempty"`
}
type Query struct {
	AccountID, Mailbox, Search string
	Limit, Offset              int
}
type Page struct {
	Messages []Message `json:"messages"`
	Total    int       `json:"total"`
	Limit    int       `json:"limit"`
	Offset   int       `json:"offset"`
}
type Batch struct {
	Messages []Message
	Cursor   string
	HasMore  bool
}
type SyncResult struct {
	Received int    `json:"received"`
	Cursor   string `json:"cursor"`
	HasMore  bool   `json:"has_more"`
}
type Job struct {
	ID        string  `json:"id"`
	MessageID string  `json:"message_id"`
	Key       string  `json:"idempotency_key"`
	State     string  `json:"state"`
	Attempts  int     `json:"attempts"`
	LastError string  `json:"last_error,omitempty"`
	Message   Message `json:"-"`
}
type Receipt struct {
	RemoteID string
	SentAt   time.Time
}
