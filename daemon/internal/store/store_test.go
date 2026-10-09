package store

import (
	"context"
	"database/sql"
	"path/filepath"
	"testing"

	_ "modernc.org/sqlite"
)

func open(t *testing.T) *Store {
	t.Helper()
	db, err := sql.Open("sqlite", "file:"+filepath.Join(t.TempDir(), "t.db")+"?_pragma=foreign_keys(1)")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { db.Close() })
	s, err := Open(context.Background(), db)
	if err != nil {
		t.Fatal(err)
	}
	return s
}

func TestMessagesAndChats(t *testing.T) {
	ctx := context.Background()
	s := open(t)
	chat := "123@s.whatsapp.net"
	if err := s.EnsureChat(ctx, chat, false); err != nil {
		t.Fatal(err)
	}
	for i, text := range []string{"hello there", "dinner at eight?", "bring the invoice"} {
		m := &Message{Chat: chat, ID: string(rune('a' + i)), Sender: chat, TS: int64(100 + i), Type: "text", Text: text, Status: StatusSent, FromMe: i == 0}
		ins, err := s.UpsertMessage(ctx, m)
		if err != nil || !ins {
			t.Fatalf("insert %d: %v %v", i, ins, err)
		}
		if err := s.BumpChat(ctx, chat, m.ID, m.TS, !m.FromMe); err != nil {
			t.Fatal(err)
		}
	}
	// Re-delivery must not duplicate or downgrade status.
	_ = s.SetStatus(ctx, chat, []string{"a"}, StatusRead)
	if ins, _ := s.UpsertMessage(ctx, &Message{Chat: chat, ID: "a", TS: 100, Type: "text", Status: StatusSent, FromMe: true}); ins {
		t.Fatal("duplicate insert")
	}

	msgs, err := s.ListMessages(ctx, chat, 0, 10)
	if err != nil || len(msgs) != 3 || msgs[0].ID != "a" || msgs[2].ID != "c" {
		t.Fatalf("list: %v %+v", err, msgs)
	}
	older, _ := s.ListMessages(ctx, chat, 102, 10)
	if len(older) != 2 {
		t.Fatalf("pagination: got %d", len(older))
	}

	ch, _ := s.GetChat(ctx, chat)
	if ch.Unread != 2 || ch.LastMsgID != "c" || ch.LastPreview != "bring the invoice" {
		t.Fatalf("chat: %+v", ch)
	}

	hits, err := s.Search(ctx, "invo", "", 10)
	if err != nil || len(hits) != 1 || hits[0].ID != "c" {
		t.Fatalf("search: %v %+v", err, hits)
	}
	// FTS must follow edits.
	_ = s.EditMessage(ctx, chat, "c", "bring the receipt")
	if hits, _ := s.Search(ctx, "invoice", "", 10); len(hits) != 0 {
		t.Fatal("stale FTS after edit")
	}
	if hits, _ := s.Search(ctx, `receipt"`, "", 10); len(hits) != 1 {
		t.Fatal("search with quote in input should still work")
	}

	_ = s.SetReaction(ctx, chat, "a", "999@s.whatsapp.net", "👍", 1)
	_ = s.SetReaction(ctx, chat, "a", "999@s.whatsapp.net", "❤️", 2)
	m, _ := s.GetMessage(ctx, chat, "a")
	if len(m.Reactions) != 1 || m.Reactions[0].Emoji != "❤️" || m.Status != StatusRead {
		t.Fatalf("reactions/status: %+v", m)
	}

	_ = s.RevokeMessage(ctx, chat, "b")
	m, _ = s.GetMessage(ctx, chat, "b")
	if !m.Revoked || Preview(m) != "🚫 This message was deleted" {
		t.Fatalf("revoke: %+v", m)
	}
	c, n, _ := s.TotalUnread(ctx)
	if c != 1 || n != 2 {
		t.Fatalf("unread totals %d %d", c, n)
	}
}
