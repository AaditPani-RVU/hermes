package store

import (
	"context"
	"testing"
)

func TestBucket(t *testing.T) {
	const now = 1_800_000_000
	const hour = 3600
	dm := func(mod func(c *Chat)) *Chat {
		c := &Chat{JID: "1@s.whatsapp.net", LastTS: now - hour, Unread: 1, RepliedTS: now - 100*hour}
		mod(c)
		return c
	}
	group := func(mod func(c *Chat)) *Chat {
		c := &Chat{JID: "1@g.us", IsGroup: true, LastTS: now - hour, Unread: 3}
		mod(c)
		return c
	}
	cases := []struct {
		name string
		c    *Chat
		want string
	}{
		{"dm from a friend", dm(func(c *Chat) {}), "reply"},
		{"dm already read still needs reply", dm(func(c *Chat) { c.Unread = 0 }), "reply"},
		{"dm marked done", dm(func(c *Chat) { c.DoneTS = now - hour/2 }), "done"},
		{"dm new message after done", dm(func(c *Chat) { c.DoneTS = now - 2*hour }), "reply"},
		{"dm I answered", dm(func(c *Chat) { c.LastFromMe = true }), "waiting"},
		{"dm I answered long ago", dm(func(c *Chat) { c.LastFromMe = true; c.LastTS = now - 96*hour }), "done"},
		{"dm stale", dm(func(c *Chat) { c.LastTS = now - 8*24*hour }), "done"},
		{"dm from a shop I never wrote to", dm(func(c *Chat) { c.RepliedTS = 0 }), "fyi"},
		{"dm muted", dm(func(c *Chat) { c.MutedUntil = now + hour }), "fyi"},
		{"dm snoozed", dm(func(c *Chat) { c.SnoozeUntil = now + hour }), "snoozed"},
		{"snooze expired before the scheduler ran", dm(func(c *Chat) { c.SnoozeUntil = now - 1; c.DoneTS = now }), "reply"},
		{"dm marked unread overrides done", dm(func(c *Chat) { c.DoneTS = now; c.MarkedUnread = true }), "reply"},
		{"archived", dm(func(c *Chat) { c.Archived = true }), "done"},
		{"group chatter", group(func(c *Chat) {}), "fyi"},
		{"group read", group(func(c *Chat) { c.Unread = 0 }), "done"},
		{"group muted", group(func(c *Chat) { c.MutedUntil = now + hour }), "done"},
		{"group mention", group(func(c *Chat) { c.MentionTS = now - hour; c.MutedUntil = now + hour }), "mention"},
		{"group mention answered", group(func(c *Chat) { c.MentionTS = now - 2*hour; c.RepliedTS = now - hour }), "fyi"},
		{"group mention cleared", group(func(c *Chat) { c.MentionTS = now - 2*hour; c.DoneTS = now - hour; c.LastTS = now - hour }), "done"},
		{"status broadcast", &Chat{JID: "status@broadcast", LastTS: now}, "done"},
	}
	for _, tc := range cases {
		if got := Bucket(tc.c, now); got != tc.want {
			t.Errorf("%s: got %q, want %q", tc.name, got, tc.want)
		}
	}
}

func TestTriageColumns(t *testing.T) {
	ctx := context.Background()
	s := open(t)
	chat := "9@g.us"
	if err := s.EnsureChat(ctx, chat, true); err != nil {
		t.Fatal(err)
	}
	if _, err := s.UpsertMessage(ctx, &Message{Chat: chat, ID: "a", TS: 100, Type: "text", Text: "@me", MentionsMe: true}); err != nil {
		t.Fatal(err)
	}
	if _, err := s.UpsertMessage(ctx, &Message{Chat: chat, ID: "b", TS: 90, Type: "text", FromMe: true}); err != nil {
		t.Fatal(err)
	}
	c, err := s.GetChat(ctx, chat)
	if err != nil {
		t.Fatal(err)
	}
	if c.MentionTS != 100 || c.RepliedTS != 90 {
		t.Fatalf("mention=%d replied=%d", c.MentionTS, c.RepliedTS)
	}
	if err := s.Snooze(ctx, chat, 50, "a"); err != nil {
		t.Fatal(err)
	}
	due, err := s.DueSnoozes(ctx, 60)
	if err != nil || len(due) != 1 || due[0].SnoozeMsg != "a" {
		t.Fatalf("due=%v err=%v", due, err)
	}
	c, _ = s.GetChat(ctx, chat)
	if c.SnoozeUntil != 0 || !c.MarkedUnread {
		t.Fatalf("snooze not cleared: %+v", c)
	}
	// Reopening the store must not fail on the already-applied migrations.
	if _, err := Open(ctx, s.DB); err != nil {
		t.Fatal(err)
	}
}

func TestNotesAndSnippets(t *testing.T) {
	ctx := context.Background()
	s := open(t)
	chat := "5@s.whatsapp.net"
	_ = s.EnsureChat(ctx, chat, false)
	if err := s.SetChatField(ctx, chat, "note", "birthday 12 March"); err != nil {
		t.Fatal(err)
	}
	if c, _ := s.GetChat(ctx, chat); c.Note != "birthday 12 March" {
		t.Fatalf("note = %q", c.Note)
	}
	if err := s.SetSnippet(ctx, ";Addr", "221B Baker Street"); err != nil {
		t.Fatal(err)
	}
	if err := s.SetSnippet(ctx, "two words", "x"); err == nil {
		t.Fatal("expected an error for a name with a space")
	}
	list, _ := s.Snippets(ctx)
	if len(list) != 1 || list[0].Trigger != "addr" {
		t.Fatalf("snippets = %+v", list)
	}
	_ = s.SetSnippet(ctx, "addr", "")
	if list, _ := s.Snippets(ctx); len(list) != 0 {
		t.Fatalf("delete failed: %+v", list)
	}
}

func TestRecentStatuses(t *testing.T) {
	ctx := context.Background()
	s := open(t)
	_ = s.EnsureChat(ctx, "status@broadcast", false)
	for i, ts := range []int64{100, 5000, 6000} {
		id := string(rune('a' + i))
		if _, err := s.UpsertMessage(ctx, &Message{Chat: "status@broadcast", ID: id, Sender: "1@s.whatsapp.net", TS: ts, Type: "text", Text: id}); err != nil {
			t.Fatal(err)
		}
	}
	_ = s.MarkStatusSeen(ctx, "b")
	msgs, seen, err := s.RecentStatuses(ctx, 1000)
	if err != nil {
		t.Fatal(err)
	}
	if len(msgs) != 2 || msgs[0].ID != "b" || msgs[1].ID != "c" {
		t.Fatalf("want b,c oldest first; got %d", len(msgs))
	}
	if !seen["b"] || seen["c"] {
		t.Fatalf("seen = %v", seen)
	}
}
