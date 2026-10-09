package wa

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"time"

	"go.mau.fi/whatsmeow/proto/waE2E"
	"go.mau.fi/whatsmeow/proto/waHistorySync"
	"go.mau.fi/whatsmeow/types"
	"google.golang.org/protobuf/proto"

	hs "github.com/aadit/hermes/daemon/internal/store"
)

// ---- Status (stories) ----
//
// Statuses are ordinary messages in the status@broadcast chat, sender = author. They
// live for 24 hours. Viewing one sends a read receipt (that's what puts you in the
// author's "viewed by" list) unless the user turned that off (kv status_receipts=off).

const statusChat = "status@broadcast"

type StatusAuthor struct {
	Sender     string        `json:"sender"`
	Name       string        `json:"name"`
	AvatarPath string        `json:"avatarPath"`
	Unseen     int           `json:"unseen"`
	LastTS     int64         `json:"lastTs"`
	Items      []*hs.Message `json:"items"` // oldest first
}

type StatusFeed struct {
	Mine     *StatusAuthor   `json:"mine"`
	Authors  []*StatusAuthor `json:"authors"` // unseen first, then newest
	Receipts bool            `json:"receipts"`
}

// StatusList returns the last 24 hours of statuses grouped by author.
func (c *Core) StatusList(ctx context.Context) (*StatusFeed, error) {
	msgs, seen, err := c.Store.RecentStatuses(ctx, time.Now().Add(-24*time.Hour).Unix())
	if err != nil {
		return nil, err
	}
	feed := &StatusFeed{Authors: []*StatusAuthor{}, Receipts: c.Store.GetKV(ctx, "status_receipts") != "off"}
	by := map[string]*StatusAuthor{}
	for _, m := range msgs {
		key := m.Sender
		if m.FromMe {
			key = "me"
		}
		a := by[key]
		if a == nil {
			a = &StatusAuthor{Sender: m.Sender, Name: m.SenderName}
			if m.FromMe {
				a.Name = "My status"
				feed.Mine = a
			} else {
				if j, err := types.ParseJID(m.Sender); err == nil {
					a.Name = c.DisplayName(ctx, j)
				}
				if ch, _ := c.Store.GetChat(ctx, m.Sender); ch != nil {
					a.AvatarPath = ch.AvatarPath
				}
				feed.Authors = append(feed.Authors, a)
			}
			by[key] = a
		}
		a.Items = append(a.Items, m)
		a.LastTS = max(a.LastTS, m.TS)
		if !m.FromMe && !seen[m.ID] {
			a.Unseen++
		}
	}
	sortAuthors(feed.Authors)
	return feed, nil
}

func sortAuthors(list []*StatusAuthor) {
	less := func(a, b *StatusAuthor) bool {
		if (a.Unseen > 0) != (b.Unseen > 0) {
			return a.Unseen > 0
		}
		return a.LastTS > b.LastTS
	}
	for i := 1; i < len(list); i++ {
		for j := i; j > 0 && less(list[j], list[j-1]); j-- {
			list[j], list[j-1] = list[j-1], list[j]
		}
	}
}

// ViewStatus marks a status seen locally and, unless turned off, tells the author.
func (c *Core) ViewStatus(ctx context.Context, id string) error {
	m, err := c.Store.GetMessage(ctx, statusChat, id)
	if err != nil || m == nil {
		return errors.New("status not found")
	}
	if err := c.Store.MarkStatusSeen(ctx, id); err != nil {
		return err
	}
	if m.FromMe || c.Store.GetKV(ctx, "status_receipts") == "off" || c.loggedIn() != nil {
		return nil
	}
	sender, err := parseJID(m.Sender)
	if err != nil {
		return err
	}
	return c.cli.MarkRead(ctx, []types.MessageID{id}, time.Unix(m.TS, 0), types.StatusBroadcastJID, sender)
}

// ReplyToStatus sends a private message to the author, quoting their status (like the phone does).
func (c *Core) ReplyToStatus(ctx context.Context, id, text string) (*hs.Message, error) {
	m, err := c.Store.GetMessage(ctx, statusChat, id)
	if err != nil || m == nil {
		return nil, errors.New("status not found")
	}
	if m.FromMe {
		return nil, errors.New("that's your own status")
	}
	text = strings.TrimSpace(text)
	if text == "" {
		return nil, errors.New("empty message")
	}
	var quoted waE2E.Message
	if len(m.Raw) > 0 {
		_ = proto.Unmarshal(m.Raw, &quoted)
	} else {
		quoted.Conversation = proto.String(m.Text)
	}
	ci := &waE2E.ContextInfo{
		StanzaID:      proto.String(id),
		Participant:   proto.String(m.Sender),
		RemoteJID:     proto.String(statusChat),
		QuotedMessage: &quoted,
	}
	msg := &waE2E.Message{ExtendedTextMessage: &waE2E.ExtendedTextMessage{Text: proto.String(text), ContextInfo: ci}}
	local := &hs.Message{Type: "text", Text: text, QuotedID: id, QuotedSender: "Status", QuotedText: hs.Preview(m)}
	return c.sendAndTrack(ctx, m.Sender, msg, local)
}

// PostTextStatus posts a coloured text status to everyone your status privacy allows.
func (c *Core) PostTextStatus(ctx context.Context, text string, bg uint32) (*hs.Message, error) {
	text = strings.TrimSpace(text)
	if text == "" {
		return nil, errors.New("empty status")
	}
	if bg == 0 {
		bg = 0xFF1F6F8B
	}
	msg := &waE2E.Message{ExtendedTextMessage: &waE2E.ExtendedTextMessage{
		Text:           proto.String(text),
		BackgroundArgb: proto.Uint32(bg),
		TextArgb:       proto.Uint32(0xFFFFFFFF),
		Font:           waE2E.ExtendedTextMessage_SYSTEM.Enum(),
	}}
	local := &hs.Message{Type: "text", Text: text, Extra: hs.MarshalExtra(map[string]any{"bg": fmt.Sprintf("#%08X", bg)})}
	return c.sendAndTrack(ctx, statusChat, msg, local)
}

// storeHistoryStatuses ingests the statuses a phone sends in history sync (StatusV3Messages).
func (c *Core) storeHistoryStatuses(ctx context.Context, data *waHistorySync.HistorySync) {
	list := data.GetStatusV3Messages()
	if len(list) == 0 {
		return
	}
	n := 0
	for _, wm := range list {
		evt, err := c.cli.ParseWebMessage(types.StatusBroadcastJID, wm)
		if err != nil {
			continue
		}
		c.handleMessage(ctx, evt, false, -1)
		n++
	}
	c.Log.Infof("History sync: %d statuses", n)
	c.Emit("status.changed", nil)
}
