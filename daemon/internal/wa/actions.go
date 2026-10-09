package wa

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"go.mau.fi/whatsmeow"
	"go.mau.fi/whatsmeow/appstate"
	"go.mau.fi/whatsmeow/proto/waCommon"
	"go.mau.fi/whatsmeow/proto/waE2E"
	"go.mau.fi/whatsmeow/proto/waSyncAction"
	"go.mau.fi/whatsmeow/types"
	"go.mau.fi/whatsmeow/types/events"
	"google.golang.org/protobuf/proto"

	hs "github.com/aadit/hermes/daemon/internal/store"
)

func parseJID(s string) (types.JID, error) {
	j, err := types.ParseJID(s)
	if err != nil {
		return j, err
	}
	if j.User == "" && j.Server == "" {
		return j, fmt.Errorf("invalid jid %q", s)
	}
	return j, nil
}

// GetChat returns a chat with its display name resolved.
func (c *Core) GetChat(ctx context.Context, jid string) (*hs.Chat, error) {
	ch, err := c.Store.GetChat(ctx, jid)
	if err != nil || ch == nil {
		return ch, err
	}
	c.fillChatName(ctx, ch)
	return ch, nil
}

func (c *Core) fillChatName(ctx context.Context, ch *hs.Chat) {
	if ch.IsGroup && ch.Name != "" {
		return
	}
	if j, err := types.ParseJID(ch.JID); err == nil {
		ch.Name = c.DisplayName(ctx, j)
		if c.isMe(j) {
			ch.Name = "You (Message yourself)"
			if ch.SnoozeUntil == 0 && !ch.MarkedUnread {
				ch.Bucket = "done" // notes to self only show up via snooze / remind-me
			}
		}
	}
	if ch.IsGroup && ch.LastSender != "" && !ch.LastFromMe {
		ch.LastSender = hs.ShortName(ch.LastSender)
	}
}

func (c *Core) ListChats(ctx context.Context, archived bool) ([]*hs.Chat, error) {
	chats, err := c.Store.ListChats(ctx, archived)
	if err != nil {
		return nil, err
	}
	for _, ch := range chats {
		c.fillChatName(ctx, ch)
	}
	if chats == nil {
		chats = []*hs.Chat{}
	}
	return chats, nil
}

// MarkRead sends read receipts for unread incoming messages and clears the badge.
func (c *Core) MarkRead(ctx context.Context, chat string) error {
	c.clearDigest(chat)
	ch, err := c.Store.GetChat(ctx, chat)
	if err != nil || ch == nil {
		return err
	}
	n := ch.Unread
	_ = c.Store.SetChatField(ctx, chat, "unread", 0)
	if ch.MarkedUnread {
		_ = c.Store.SetChatField(ctx, chat, "marked_unread", 0)
		if jid, err := parseJID(chat); err == nil && c.loggedIn() == nil {
			_ = c.cli.SendAppState(ctx, appstate.BuildMarkChatAsRead(jid, true, time.Time{}, nil))
		}
	}
	if c.Notify != nil {
		c.Notify.Dismiss(chat)
	}
	c.emitChat(ctx, chat)
	if n <= 0 || c.loggedIn() != nil {
		return nil
	}
	if n > 100 {
		n = 100
	}
	rows, err := c.Store.DB.QueryContext(ctx, `SELECT id, sender, ts FROM hermes_messages
		WHERE chat=? AND from_me=0 ORDER BY ts DESC LIMIT ?`, chat, n)
	if err != nil {
		return err
	}
	type item struct {
		id string
		ts int64
	}
	bySender := map[string][]item{}
	for rows.Next() {
		var it item
		var sender string
		if rows.Scan(&it.id, &sender, &it.ts) == nil {
			bySender[sender] = append(bySender[sender], it)
		}
	}
	rows.Close()
	chatJID, err := parseJID(chat)
	if err != nil {
		return err
	}
	for sender, items := range bySender {
		ids := make([]types.MessageID, len(items))
		var newest int64
		for i, it := range items {
			ids[i] = it.id
			if it.ts > newest {
				newest = it.ts
			}
		}
		senderJID, _ := parseJID(sender)
		if !chatJID.IsEmpty() && chatJID.Server != types.GroupServer {
			senderJID = chatJID
		}
		if err := c.cli.MarkRead(ctx, ids, time.Unix(newest, 0), chatJID, senderJID); err != nil {
			c.Log.Warnf("mark read %s: %v", chat, err)
		}
	}
	return nil
}

func (c *Core) MarkUnread(ctx context.Context, chat string) error {
	jid, err := parseJID(chat)
	if err != nil {
		return err
	}
	_ = c.Store.SetChatField(ctx, chat, "marked_unread", 1)
	c.emitChat(ctx, chat)
	if c.loggedIn() == nil {
		return c.cli.SendAppState(ctx, appstate.BuildMarkChatAsRead(jid, false, time.Time{}, nil))
	}
	return nil
}

func (c *Core) lastKey(ctx context.Context, chat string) (time.Time, *waCommon.MessageKey) {
	ch, _ := c.Store.GetChat(ctx, chat)
	if ch == nil || ch.LastMsgID == "" {
		return time.Time{}, nil
	}
	m, _ := c.Store.GetMessage(ctx, chat, ch.LastMsgID)
	if m == nil {
		return time.Time{}, nil
	}
	key := &waCommon.MessageKey{RemoteJID: proto.String(chat), FromMe: proto.Bool(m.FromMe), ID: proto.String(m.ID)}
	if strings.HasSuffix(chat, "@g.us") && !m.FromMe {
		key.Participant = proto.String(m.Sender)
	}
	return time.Unix(m.TS, 0), key
}

func (c *Core) SetArchived(ctx context.Context, chat string, archived bool) error {
	jid, err := parseJID(chat)
	if err != nil {
		return err
	}
	if err := c.loggedIn(); err != nil {
		return err
	}
	ts, key := c.lastKey(ctx, chat)
	if err := c.cli.SendAppState(ctx, appstate.BuildArchive(jid, archived, ts, key)); err != nil {
		return err
	}
	_ = c.Store.SetChatField(ctx, chat, "archived", archived)
	if archived {
		_ = c.Store.SetChatField(ctx, chat, "pinned_ts", 0)
	}
	c.emitChat(ctx, chat)
	return nil
}

func (c *Core) SetPinned(ctx context.Context, chat string, pinned bool) error {
	jid, err := parseJID(chat)
	if err != nil {
		return err
	}
	if err := c.loggedIn(); err != nil {
		return err
	}
	if err := c.cli.SendAppState(ctx, appstate.BuildPin(jid, pinned)); err != nil {
		return err
	}
	var ts int64
	if pinned {
		ts = time.Now().Unix()
	}
	_ = c.Store.SetChatField(ctx, chat, "pinned_ts", ts)
	c.emitChat(ctx, chat)
	return nil
}

// SetMuted mutes for the given duration (0 = forever) or unmutes when mute is false.
func (c *Core) SetMuted(ctx context.Context, chat string, mute bool, dur time.Duration) error {
	jid, err := parseJID(chat)
	if err != nil {
		return err
	}
	if err := c.loggedIn(); err != nil {
		return err
	}
	if err := c.cli.SendAppState(ctx, appstate.BuildMute(jid, mute, dur)); err != nil {
		return err
	}
	var until int64
	if mute {
		until = 1 << 40
		if dur > 0 {
			until = time.Now().Add(dur).Unix()
		}
	}
	_ = c.Store.SetChatField(ctx, chat, "muted_until", until)
	c.emitChat(ctx, chat)
	return nil
}

// SetDone clears a chat out of the triage inbox until something new arrives.
// Marking done also reads it, like archiving an email.
func (c *Core) SetDone(ctx context.Context, chat string, done bool) error {
	var ts int64
	if done {
		ts = time.Now().Unix()
	}
	if err := c.Store.SetChatField(ctx, chat, "done_ts", ts); err != nil {
		return err
	}
	_ = c.Store.Snooze(ctx, chat, 0, "")
	if done {
		return c.MarkRead(ctx, chat) // emits the chat
	}
	c.emitChat(ctx, chat)
	return nil
}

// Snooze hides a chat from the inbox until `until` (unix seconds; 0 cancels).
func (c *Core) Snooze(ctx context.Context, chat string, until int64, msgID string) error {
	if until != 0 && until <= time.Now().Unix() {
		return errors.New("snooze time is in the past")
	}
	if err := c.Store.Snooze(ctx, chat, until, msgID); err != nil {
		return err
	}
	if until != 0 {
		return c.MarkRead(ctx, chat)
	}
	c.emitChat(ctx, chat)
	return nil
}

// SetNote saves the chat's private note (local only; WhatsApp never sees it).
func (c *Core) SetNote(ctx context.Context, chat, text string) error {
	_ = c.Store.EnsureChat(ctx, chat, strings.HasSuffix(chat, "@g.us"))
	if err := c.Store.SetChatField(ctx, chat, "note", strings.TrimRight(text, " \n")); err != nil {
		return err
	}
	c.emitChat(ctx, chat)
	return nil
}

func (c *Core) SetDraft(ctx context.Context, chat, text string) error {
	_ = c.Store.EnsureChat(ctx, chat, strings.HasSuffix(chat, "@g.us"))
	return c.Store.SetChatField(ctx, chat, "draft", text)
}

func (c *Core) SetTyping(ctx context.Context, chat string, composing, recording bool) error {
	jid, err := parseJID(chat)
	if err != nil {
		return err
	}
	if err := c.loggedIn(); err != nil {
		return err
	}
	state, media := types.ChatPresencePaused, types.ChatPresenceMediaText
	if composing || recording {
		state = types.ChatPresenceComposing
	}
	if recording {
		media = types.ChatPresenceMediaAudio
	}
	return c.cli.SendChatPresence(ctx, jid, state, media)
}

// SetOnline marks us online while the UI is focused (like WhatsApp Web), offline otherwise
// so the phone keeps receiving push notifications.
func (c *Core) SetOnline(ctx context.Context, online bool) error {
	if c.loggedIn() != nil || c.cli.Store.PushName == "" {
		return nil
	}
	p := types.PresenceUnavailable
	if online {
		p = types.PresenceAvailable
	}
	return c.cli.SendPresence(ctx, p)
}

func (c *Core) SubscribePresence(ctx context.Context, chat string) error {
	jid, err := parseJID(chat)
	if err != nil || c.loggedIn() != nil || jid.Server == types.GroupServer {
		return err
	}
	return c.cli.SubscribePresence(ctx, jid)
}

type SendOpts struct {
	ReplyTo  string   `json:"replyTo"`
	Mentions []string `json:"mentions"`
}

func (c *Core) contextInfo(ctx context.Context, chat string, opts SendOpts) *waE2E.ContextInfo {
	var ci *waE2E.ContextInfo
	ensure := func() {
		if ci == nil {
			ci = &waE2E.ContextInfo{}
		}
	}
	if opts.ReplyTo != "" {
		if q, _ := c.Store.GetMessage(ctx, chat, opts.ReplyTo); q != nil {
			ensure()
			ci.StanzaID = proto.String(q.ID)
			participant := q.Sender
			if q.FromMe && c.cli.Store.ID != nil {
				participant = c.cli.Store.ID.ToNonAD().String()
			}
			ci.Participant = proto.String(participant)
			quoted := &waE2E.Message{Conversation: proto.String(q.Text)}
			if len(q.Raw) > 0 {
				var orig waE2E.Message
				if proto.Unmarshal(q.Raw, &orig) == nil {
					quoted = &orig
				}
			}
			ci.QuotedMessage = quoted
		}
	}
	if len(opts.Mentions) > 0 {
		ensure()
		ci.MentionedJID = opts.Mentions
	}
	if ch, _ := c.Store.GetChat(ctx, chat); ch != nil && ch.Ephemeral > 0 {
		ensure()
		ci.Expiration = proto.Uint32(uint32(ch.Ephemeral))
	}
	return ci
}

// sendAndTrack stores an optimistic pending copy, sends, and updates its status.
func (c *Core) sendAndTrack(ctx context.Context, chat string, msg *waE2E.Message, local *hs.Message) (*hs.Message, error) {
	if err := c.loggedIn(); err != nil {
		return nil, err
	}
	jid, err := parseJID(chat)
	if err != nil {
		return nil, err
	}
	id := c.cli.GenerateMessageID()
	local.Chat, local.ID, local.FromMe = chat, id, true
	local.Sender = c.cli.Store.ID.ToNonAD().String()
	local.SenderName = "You"
	local.TS = time.Now().Unix()
	local.Status = hs.StatusPending
	local.Reactions = []hs.Reaction{}
	if local.Raw == nil {
		local.Raw, _ = proto.Marshal(msg)
	}
	_ = c.Store.EnsureChat(ctx, chat, jid.Server == types.GroupServer)
	if _, err := c.Store.UpsertMessage(ctx, local); err != nil {
		return nil, err
	}
	_ = c.Store.BumpChat(ctx, chat, id, local.TS, false)
	_ = c.Store.SetChatField(ctx, chat, "draft", "")
	c.Emit("message", local)
	c.emitChat(ctx, chat)

	resp, err := c.cli.SendMessage(ctx, jid, msg, whatsmeow.SendRequestExtra{ID: id})
	if err != nil {
		_ = c.Store.ForceStatus(ctx, chat, id, hs.StatusFailed)
		local.Status = hs.StatusFailed
		c.Emit("message", local)
		return local, err
	}
	if !resp.Timestamp.IsZero() {
		_, _ = c.Store.DB.ExecContext(ctx, `UPDATE hermes_messages SET ts=? WHERE chat=? AND id=?`, resp.Timestamp.Unix(), chat, id)
		local.TS = resp.Timestamp.Unix()
	}
	_ = c.Store.SetStatus(ctx, chat, []string{id}, hs.StatusSent)
	local.Status = hs.StatusSent
	c.Emit("message", local)
	c.emitChat(ctx, chat)
	return local, nil
}

func (c *Core) SendText(ctx context.Context, chat, text string, opts SendOpts) (*hs.Message, error) {
	text = strings.TrimRight(text, " \n\t")
	if text == "" {
		return nil, errors.New("empty message")
	}
	ci := c.contextInfo(ctx, chat, opts)
	msg := &waE2E.Message{}
	if ci == nil {
		msg.Conversation = proto.String(text)
	} else {
		msg.ExtendedTextMessage = &waE2E.ExtendedTextMessage{Text: proto.String(text), ContextInfo: ci}
	}
	local := &hs.Message{Type: "text", Text: text}
	if opts.ReplyTo != "" {
		if q, _ := c.Store.GetMessage(ctx, chat, opts.ReplyTo); q != nil {
			local.QuotedID, local.QuotedSender, local.QuotedText = q.ID, q.SenderName, hs.Preview(q)
		}
	}
	return c.sendAndTrack(ctx, chat, msg, local)
}

func (c *Core) messageKey(ctx context.Context, chat, id string) (*hs.Message, types.JID, types.JID, error) {
	m, err := c.Store.GetMessage(ctx, chat, id)
	if err != nil {
		return nil, types.JID{}, types.JID{}, err
	} else if m == nil {
		return nil, types.JID{}, types.JID{}, fmt.Errorf("message not found")
	}
	chatJID, err := parseJID(chat)
	if err != nil {
		return nil, types.JID{}, types.JID{}, err
	}
	sender, _ := parseJID(m.Sender)
	if m.FromMe {
		sender = c.cli.Store.ID.ToNonAD()
	}
	return m, chatJID, sender, nil
}

func (c *Core) React(ctx context.Context, chat, id, emoji string) error {
	if err := c.loggedIn(); err != nil {
		return err
	}
	_, chatJID, sender, err := c.messageKey(ctx, chat, id)
	if err != nil {
		return err
	}
	if _, err := c.cli.SendMessage(ctx, chatJID, c.cli.BuildReaction(chatJID, sender, id, emoji)); err != nil {
		return err
	}
	_ = c.Store.SetReaction(ctx, chat, id, c.cli.Store.ID.ToNonAD().String(), emoji, time.Now().Unix())
	c.emitMessage(ctx, chat, id)
	return nil
}

func (c *Core) Edit(ctx context.Context, chat, id, text string) error {
	if err := c.loggedIn(); err != nil {
		return err
	}
	m, chatJID, _, err := c.messageKey(ctx, chat, id)
	if err != nil {
		return err
	}
	if !m.FromMe {
		return errors.New("can only edit your own messages")
	}
	if time.Since(time.Unix(m.TS, 0)) > 15*time.Minute {
		return errors.New("messages can only be edited within 15 minutes")
	}
	edit := c.cli.BuildEdit(chatJID, id, &waE2E.Message{Conversation: proto.String(text)})
	if _, err := c.cli.SendMessage(ctx, chatJID, edit); err != nil {
		return err
	}
	_ = c.Store.EditMessage(ctx, chat, id, text)
	c.emitMessage(ctx, chat, id)
	c.emitChat(ctx, chat)
	return nil
}

func (c *Core) Delete(ctx context.Context, chat, id string, forEveryone bool) error {
	if err := c.loggedIn(); err != nil {
		return err
	}
	m, chatJID, sender, err := c.messageKey(ctx, chat, id)
	if err != nil {
		return err
	}
	if forEveryone {
		if !m.FromMe && chatJID.Server != types.GroupServer {
			return errors.New("can only delete your own messages for everyone")
		}
		if _, err := c.cli.SendMessage(ctx, chatJID, c.cli.BuildRevoke(chatJID, sender, id)); err != nil {
			return err
		}
		_ = c.Store.RevokeMessage(ctx, chat, id)
		c.emitMessage(ctx, chat, id)
	} else {
		patch := buildDeleteForMe(chatJID, sender, id, m.FromMe, time.Unix(m.TS, 0))
		if err := c.cli.SendAppState(ctx, patch); err != nil {
			c.Log.Warnf("delete-for-me sync: %v", err)
		}
		_ = c.Store.DeleteMessage(ctx, chat, id)
		c.Emit("message.deleted", map[string]any{"chat": chat, "id": id})
	}
	_ = c.Store.RecomputeLast(ctx, chat)
	c.emitChat(ctx, chat)
	return nil
}

// buildDeleteForMe mirrors appstate.BuildStar for the deleteMessageForMe mutation,
// which whatsmeow doesn't provide a builder for.
func buildDeleteForMe(chat, sender types.JID, id types.MessageID, fromMe bool, ts time.Time) appstate.PatchInfo {
	isFromMe, senderJID := "0", sender.String()
	if fromMe {
		isFromMe = "1"
	}
	if chat.User == sender.User || fromMe {
		senderJID = "0"
	}
	return appstate.PatchInfo{
		Type: appstate.WAPatchRegularHigh,
		Mutations: []appstate.MutationInfo{{
			Index:   []string{appstate.IndexDeleteMessageForMe, chat.String(), id, isFromMe, senderJID},
			Version: 3,
			Value: &waSyncAction.SyncActionValue{
				DeleteMessageForMeAction: &waSyncAction.DeleteMessageForMeAction{
					DeleteMedia:      proto.Bool(true),
					MessageTimestamp: proto.Int64(ts.Unix()),
				},
			},
		}},
	}
}

func (c *Core) Star(ctx context.Context, chat, id string, starred bool) error {
	if err := c.loggedIn(); err != nil {
		return err
	}
	m, chatJID, sender, err := c.messageKey(ctx, chat, id)
	if err != nil {
		return err
	}
	if err := c.cli.SendAppState(ctx, appstate.BuildStar(chatJID, sender, id, m.FromMe, starred)); err != nil {
		return err
	}
	_ = c.Store.SetStarred(ctx, chat, id, starred)
	c.emitMessage(ctx, chat, id)
	return nil
}

// Forward re-sends a stored message (text or media) to another chat.
func (c *Core) Forward(ctx context.Context, chat, id, to string) (*hs.Message, error) {
	m, err := c.Store.GetMessage(ctx, chat, id)
	if err != nil || m == nil {
		return nil, fmt.Errorf("message not found")
	}
	var msg waE2E.Message
	if len(m.Raw) > 0 {
		if err := proto.Unmarshal(m.Raw, &msg); err != nil {
			return nil, err
		}
	} else {
		msg.Conversation = proto.String(m.Text)
	}
	fwd := &waE2E.ContextInfo{IsForwarded: proto.Bool(true), ForwardingScore: proto.Uint32(1)}
	switch {
	case msg.Conversation != nil:
		msg = waE2E.Message{ExtendedTextMessage: &waE2E.ExtendedTextMessage{Text: msg.Conversation, ContextInfo: fwd}}
	case msg.ExtendedTextMessage != nil:
		msg.ExtendedTextMessage.ContextInfo = fwd
	case msg.ImageMessage != nil:
		msg.ImageMessage.ContextInfo = fwd
	case msg.VideoMessage != nil:
		msg.VideoMessage.ContextInfo = fwd
	case msg.AudioMessage != nil:
		msg.AudioMessage.ContextInfo = fwd
	case msg.DocumentMessage != nil:
		msg.DocumentMessage.ContextInfo = fwd
	case msg.StickerMessage != nil:
		msg.StickerMessage.ContextInfo = fwd
	}
	local := *m
	local.QuotedID, local.QuotedSender, local.QuotedText = "", "", ""
	local.Raw = nil
	local.Starred = false
	return c.sendAndTrack(ctx, to, &msg, &local)
}

func (c *Core) SendPoll(ctx context.Context, chat, question string, options []string, multi bool) (*hs.Message, error) {
	if len(options) < 2 {
		return nil, errors.New("a poll needs at least two options")
	}
	sel := 1
	if multi {
		sel = 0
	}
	msg := c.cli.BuildPollCreation(question, options, sel)
	local := &hs.Message{Type: "poll", Text: question,
		Extra: hs.MarshalExtra(pollExtra{options, uint32(sel)})}
	return c.sendAndTrack(ctx, chat, msg, local)
}

func (c *Core) VotePoll(ctx context.Context, chat, id string, options []string) error {
	if err := c.loggedIn(); err != nil {
		return err
	}
	m, chatJID, sender, err := c.messageKey(ctx, chat, id)
	if err != nil {
		return err
	}
	info := &types.MessageInfo{
		MessageSource: types.MessageSource{Chat: chatJID, Sender: sender, IsFromMe: m.FromMe, IsGroup: chatJID.Server == types.GroupServer},
		ID:            id,
	}
	vote, err := c.cli.BuildPollVote(ctx, info, options)
	if err != nil {
		return err
	}
	if _, err := c.cli.SendMessage(ctx, chatJID, vote); err != nil {
		return err
	}
	return c.recordVote(ctx, chat, id, c.cli.Store.ID.ToNonAD().String(), options)
}

func (c *Core) handlePollVote(ctx context.Context, evt *events.Message, chat, sender string) {
	pollID := evt.Message.GetPollUpdateMessage().GetPollCreationMessageKey().GetID()
	poll, _ := c.Store.GetMessage(ctx, chat, pollID)
	if poll == nil {
		return
	}
	vote, err := c.cli.DecryptPollVote(ctx, evt)
	if err != nil {
		c.Log.Warnf("decrypt poll vote: %v", err)
		return
	}
	var pe pollExtra
	_ = json.Unmarshal([]byte(poll.Extra), &pe)
	hashes := whatsmeow.HashPollOptions(pe.Options)
	var chosen []string
	for _, sel := range vote.GetSelectedOptions() {
		for i, h := range hashes {
			if string(h) == string(sel) {
				chosen = append(chosen, pe.Options[i])
			}
		}
	}
	_ = c.recordVote(ctx, chat, pollID, sender, chosen)
}

// recordVote keeps votes inside the poll's extra JSON as {voter: [options]}.
func (c *Core) recordVote(ctx context.Context, chat, pollID, voter string, options []string) error {
	poll, _ := c.Store.GetMessage(ctx, chat, pollID)
	if poll == nil {
		return nil
	}
	var extra map[string]any
	_ = json.Unmarshal([]byte(poll.Extra), &extra)
	if extra == nil {
		extra = map[string]any{}
	}
	votes, _ := extra["votes"].(map[string]any)
	if votes == nil {
		votes = map[string]any{}
	}
	if len(options) == 0 {
		delete(votes, voter)
	} else {
		sort.Strings(options)
		votes[voter] = options
	}
	extra["votes"] = votes
	_, err := c.Store.DB.ExecContext(ctx, `UPDATE hermes_messages SET extra=? WHERE chat=? AND id=?`, hs.MarshalExtra(extra), chat, pollID)
	c.emitMessage(ctx, chat, pollID)
	return err
}

// Avatar returns a cached local path for a chat's profile picture (may be empty).
func (c *Core) Avatar(ctx context.Context, chat string) (string, error) {
	ch, _ := c.Store.GetChat(ctx, chat)
	c.mu.Lock()
	last, seen := avatarFetched[chat]
	if !seen || time.Since(last) > 12*time.Hour {
		avatarFetched[chat] = time.Now()
	}
	c.mu.Unlock()
	if ch != nil && ch.AvatarPath != "" {
		if _, err := os.Stat(ch.AvatarPath); err == nil && seen && time.Since(last) < 12*time.Hour {
			return ch.AvatarPath, nil
		}
	}
	if seen && time.Since(last) < 12*time.Hour {
		if ch != nil {
			return ch.AvatarPath, nil
		}
		return "", nil
	}
	if err := c.loggedIn(); err != nil {
		return "", err
	}
	jid, err := parseJID(chat)
	if err != nil {
		return "", err
	}
	params := &whatsmeow.GetProfilePictureParams{Preview: false}
	if ch != nil && ch.AvatarID != "" {
		params.ExistingID = ch.AvatarID
	}
	info, err := c.cli.GetProfilePictureInfo(ctx, jid, params)
	if errors.Is(err, whatsmeow.ErrProfilePictureNotSet) || errors.Is(err, whatsmeow.ErrProfilePictureUnauthorized) {
		_ = c.Store.SetChatAvatar(ctx, chat, "", "")
		return "", nil
	} else if err != nil {
		return "", err
	}
	if info == nil { // unchanged
		if ch != nil {
			return ch.AvatarPath, nil
		}
		return "", nil
	}
	req, _ := http.NewRequestWithContext(ctx, http.MethodGet, info.URL, nil)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	data, err := io.ReadAll(io.LimitReader(resp.Body, 5<<20))
	if err != nil {
		return "", err
	}
	path := filepath.Join(c.Paths.AvatarDir(), safeName(chat)+"-"+safeName(info.ID)+".jpg")
	if err := os.WriteFile(path, data, 0o600); err != nil {
		return "", err
	}
	if ch != nil && ch.AvatarPath != "" && ch.AvatarPath != path {
		_ = os.Remove(ch.AvatarPath)
	}
	_ = c.Store.EnsureChat(ctx, chat, jid.Server == types.GroupServer)
	_ = c.Store.SetChatAvatar(ctx, chat, path, info.ID)
	return path, nil
}

type ContactResult struct {
	JID  string `json:"jid"`
	Name string `json:"name"`
	Push string `json:"push,omitempty"`
}

// SearchContacts finds saved contacts and groups by name or number for "new chat".
func (c *Core) SearchContacts(ctx context.Context, q string) ([]ContactResult, error) {
	if err := c.loggedIn(); err != nil {
		return nil, err
	}
	q = strings.ToLower(strings.TrimSpace(q))
	out := []ContactResult{}
	all, err := c.cli.Store.Contacts.GetAllContacts(ctx)
	if err != nil {
		return nil, err
	}
	for jid, info := range all {
		if jid.Server != types.DefaultUserServer {
			continue
		}
		name := info.FullName
		if name == "" {
			name = info.FirstName
		}
		if name == "" {
			continue // only saved contacts
		}
		if q == "" || strings.Contains(strings.ToLower(name), q) || strings.Contains(jid.User, q) {
			out = append(out, ContactResult{JID: jid.String(), Name: name, Push: info.PushName})
		}
	}
	rows, err := c.Store.DB.QueryContext(ctx, `SELECT jid, name FROM hermes_chats WHERE is_group=1 AND name != ''`)
	if err == nil {
		for rows.Next() {
			var jid, name string
			if rows.Scan(&jid, &name) == nil && (q == "" || strings.Contains(strings.ToLower(name), q)) {
				out = append(out, ContactResult{JID: jid, Name: name})
			}
		}
		rows.Close()
	}
	sort.Slice(out, func(i, j int) bool { return strings.ToLower(out[i].Name) < strings.ToLower(out[j].Name) })
	if len(out) > 200 {
		out = out[:200]
	}
	return out, nil
}

// ResolvePhone checks a phone number is on WhatsApp and returns its JID.
func (c *Core) ResolvePhone(ctx context.Context, phone string) (string, error) {
	if err := c.loggedIn(); err != nil {
		return "", err
	}
	phone = strings.Map(func(r rune) rune {
		if r >= '0' && r <= '9' {
			return r
		}
		return -1
	}, phone)
	res, err := c.cli.IsOnWhatsApp(ctx, []string{"+" + phone})
	if err != nil {
		return "", err
	}
	if len(res) == 0 || !res[0].IsIn {
		return "", fmt.Errorf("+%s is not on WhatsApp", phone)
	}
	jid := res[0].JID.ToNonAD().String()
	_ = c.Store.EnsureChat(ctx, jid, false)
	return jid, nil
}

type GroupInfo struct {
	JID          string        `json:"jid"`
	Name         string        `json:"name"`
	Topic        string        `json:"topic"`
	Participants []Participant `json:"participants"`
	Announce     bool          `json:"announce"`
	Locked       bool          `json:"locked"`
	IsCommunity  bool          `json:"isCommunity"`
	Created      int64         `json:"created"`
	TopicID      string        `json:"topicId"`
	IAmAdmin     bool          `json:"iAmAdmin"`
	IAmMember    bool          `json:"iAmMember"`
}

type Participant struct {
	JID     string `json:"jid"`
	Name    string `json:"name"`
	IsAdmin bool   `json:"isAdmin"`
	IsSuper bool   `json:"isSuper"`
	IsMe    bool   `json:"isMe"`
	// ID is the address WhatsApp uses for this member (often a LID); admin actions need it.
	ID string `json:"id"`
}

func (c *Core) GroupInfo(ctx context.Context, chat string) (*GroupInfo, error) {
	if err := c.loggedIn(); err != nil {
		return nil, err
	}
	jid, err := parseJID(chat)
	if err != nil {
		return nil, err
	}
	gi, err := c.cli.GetGroupInfo(ctx, jid)
	if err != nil {
		return nil, err
	}
	out := &GroupInfo{JID: chat, Name: gi.Name, Topic: gi.Topic, Announce: gi.IsAnnounce, Locked: gi.IsLocked,
		IsCommunity: gi.IsParent, Created: unixOrZero(gi.GroupCreated), TopicID: gi.TopicID}
	for _, p := range gi.Participants {
		pj := p.JID
		if !p.PhoneNumber.IsEmpty() {
			pj = p.PhoneNumber
		}
		pj = c.canon(ctx, pj)
		me := c.isMe(p.JID) || c.isMe(pj)
		if me {
			out.IAmMember = true
			out.IAmAdmin = p.IsAdmin || p.IsSuperAdmin
		}
		out.Participants = append(out.Participants, Participant{JID: pj.String(), Name: c.DisplayName(ctx, pj),
			IsAdmin: p.IsAdmin || p.IsSuperAdmin, IsSuper: p.IsSuperAdmin, IsMe: me, ID: p.JID.ToNonAD().String()})
	}
	sort.Slice(out.Participants, func(i, j int) bool {
		a, b := out.Participants[i], out.Participants[j]
		if a.IsAdmin != b.IsAdmin {
			return a.IsAdmin
		}
		return strings.ToLower(a.Name) < strings.ToLower(b.Name)
	})
	return out, nil
}

// LoadOlder asks the phone for older history in a chat (on-demand history sync).
func (c *Core) LoadOlder(ctx context.Context, chat string) error {
	if err := c.loggedIn(); err != nil {
		return err
	}
	var id string
	var ts int64
	var fromMe bool
	var sender string
	err := c.Store.DB.QueryRowContext(ctx, `SELECT id, ts, from_me, sender FROM hermes_messages WHERE chat=? ORDER BY ts ASC LIMIT 1`, chat).
		Scan(&id, &ts, &fromMe, &sender)
	if err != nil {
		return fmt.Errorf("no messages to anchor on")
	}
	chatJID, _ := parseJID(chat)
	senderJID, _ := parseJID(sender)
	info := &types.MessageInfo{
		MessageSource: types.MessageSource{Chat: chatJID, Sender: senderJID, IsFromMe: fromMe, IsGroup: chatJID.Server == types.GroupServer},
		ID:            id, Timestamp: time.Unix(ts, 0),
	}
	req := c.cli.BuildHistorySyncRequest(info, 50)
	_, err = c.cli.SendMessage(ctx, c.cli.Store.ID.ToNonAD(), req, whatsmeow.SendRequestExtra{Peer: true})
	return err
}
