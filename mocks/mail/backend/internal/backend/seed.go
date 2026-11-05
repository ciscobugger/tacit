package backend

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"time"
)

// Seed is deliberately one-shot: restarting never resets user edits.
func (s *Store) Seed(ctx context.Context) error {
	tx, e := s.db.BeginTx(ctx, nil)
	if e != nil {
		return e
	}
	defer tx.Rollback()
	var marker string
	e = tx.QueryRowContext(ctx, `SELECT value FROM metadata WHERE key='seed'`).Scan(&marker)
	if e == nil {
		return nil
	}
	if !errors.Is(e, sql.ErrNoRows) {
		return e
	}
	for _, a := range []Account{{"work", "Lorenz Rosenthal", "lorenz@tacit.example", "mock"}, {"personal", "Lorenz Rosenthal", "lorenz@example.com", "mock"}} {
		if _, e = tx.ExecContext(ctx, `INSERT INTO accounts VALUES(?,?,?,?) ON CONFLICT(id) DO NOTHING`, a.ID, a.Name, a.Email, a.Provider); e != nil {
			return e
		}
	}
	names := []string{"Lena Fischer", "Nils Berger", "Mara Klein", "Tactical Studio", "Nils Berger", "Quiet Hours", "Studio Newsletter", "Anna Richter", "Jonas Weber", "Clara Neumann", "Research circle", "Felix Braun", "Mara Klein", "Lea Hoffmann"}
	subjects := []string{"The Dusk and Moss pass", "The Dusk and Moss pass", "The Dusk and Moss pass", "Monday notes, prototype review", "Train details for Friday", "Your weekly summary", "A few things worth reading", "A small question about Tuesday", "Lunch next week?", "Dinner on Saturday", "Notes from our last session", "Photos from the coast", "Re: The Dusk and Moss pass", "Your booking confirmation"}
	bodies := []string{"Here are the two palettes as we left them on Friday.", "The moss reads well on dark. The header spacing still feels tight.", "Hi Lorenz,\n\nThe final design review is ready. I have attached the summary and palette notes. Can you send your feedback before Thursday?\n\nThanks,\nMara", "Good morning! Here is this week's prototype review. The next review is on Monday.", "Hi Lorenz, the train leaves at 08:32 on Friday. Your ticket is attached.", "Your week at a glance: three quiet mornings and a little more time for reading.", "This month: small tools, thoughtful interfaces and a few good books.", "Hello Lorenz, would Tuesday afternoon work for a short call?", "Would Wednesday work for lunch? Same place as last time?", "Shall we bring something for dinner? Looking forward to seeing everyone.", "Thanks for joining. These are the notes and references from our discussion.", "Here are the photographs from our walk along the coast.", "Hi Mara, thank you! I will send my notes tomorrow.", "Your reservation is confirmed. Arrival on Friday after 15:00."}
	for i, name := range names {
		account := "work"
		if i >= 5 && i != 6 && i != 10 && i != 12 {
			account = "personal"
		}
		conv := fmt.Sprintf("thread-%02d", i)
		if i < 3 || i == 12 {
			conv = "review"
		}
		date := time.Date(2026, 11, 2, 9, 42, 0, 0, time.UTC).Add(-time.Duration(i) * 7 * time.Hour)
		if i < 3 {
			date = time.Date(2026, 11, 2, 9, 42, 0, 0, time.UTC).Add(time.Duration(i-2) * 24 * time.Hour)
		}
		m := Message{ID: fmt.Sprintf("seed-%02d", i), AccountID: account, RemoteID: fmt.Sprintf("fixture-%02d", i), ConversationID: conv, From: Address{name, fmt.Sprintf("sender%d@example.com", i)}, To: []Address{{Name: "Lorenz", Email: "lorenz@tacit.example"}}, Subject: subjects[i], BodyText: bodies[i], Mailbox: "Inbox", Unread: i == 2 || i == 3 || i == 6, Flagged: i == 4, Date: date}
		if account == "personal" {
			m.To[0].Email = "lorenz@example.com"
		}
		if i == 2 {
			m.Cc = []Address{{"Nils Berger", "nils@example.com"}, {"Lena Fischer", "lena@example.com"}}
			m.Attachments = []Attachment{{Filename: "Review summary.md", MediaType: "text/markdown", Data: []byte("# Design review\n\nKeep the hierarchy quiet. Give the message room to speak.")}, {Filename: "palette-notes.txt", MediaType: "text/plain", Data: []byte("Dusk: warm neutral. Moss: soft green.")}}
		}
		if i == 4 {
			m.Attachments = []Attachment{{Filename: "journey.txt", MediaType: "text/plain", Data: []byte("Friday 08:32 — Platform 4")}}
		}
		if i == 12 {
			m.From = Address{"Lorenz Rosenthal", "lorenz@tacit.example"}
			m.To = []Address{{"Mara Klein", "mara@example.com"}}
			m.Mailbox = "Sent"
		}
		m = normalise(m)
		if e = s.write(ctx, tx, m); e != nil {
			return e
		}
	}
	if _, e = tx.ExecContext(ctx, `INSERT INTO metadata VALUES('seed','1')`); e != nil {
		return e
	}
	return tx.Commit()
}
