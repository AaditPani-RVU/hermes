package wa

import (
	"context"
	"time"

	"go.mau.fi/whatsmeow/proto/waE2E"
	"go.mau.fi/whatsmeow/proto/waHistorySync"
	"go.mau.fi/whatsmeow/proto/waWeb"
	"go.mau.fi/whatsmeow/store"
	"go.mau.fi/whatsmeow/types"
	"go.mau.fi/whatsmeow/types/events"

	hs "github.com/aadit/hermes/daemon/internal/store"
)

const autoDownloadMax = 16 << 20

func (c *Core) handleEvent(rawEvt any) {
	ctx := context.Background()
	switch evt := rawEvt.(type) {
	case *events.Message:
		c.handleMessage(ctx, evt, true, -1)
	case *events.HistorySync:
		c.handleHistory(ctx, evt.Data)
	case *events.MediaRetry:
		c.handleMediaRetry(evt)
	case *events.Receipt:
		c.handleReceipt(ctx, evt)
	case *events.ChatPresence:
		chat := c.canonFromSource(ctx, evt.Chat, evt.SenderAlt)
		sender := c.canonFromSource(ctx, evt.Sender, evt.SenderAlt)
		c.Emit("typing", map[string]any{
			"chat": chat.String(), "sender": sender.String(), "name": c.DisplayName(ctx, sender),
			"composing": evt.State == types.ChatPresenceComposing, "recording": evt.Media == types.ChatPresenceMediaAudio,
		})
	case *events.Presence:
		c.Emit("presence", map[string]any{
			"jid": c.canon(ctx, evt.From).String(), "online": !evt.Unavailable, "lastSeen": unixOrZero(evt.LastSeen),
		})
	case *events.Archive:
		c.updateChatField(ctx, evt.JID, "archived", evt.Action.GetArchived())
	case *events.Pin:
		var ts int64
		if evt.Action.GetPinned() {
			ts = evt.Timestamp.Unix()
		}
		c.updateChatField(ctx, evt.JID, "pinned_ts", ts)
	case *events.Mute:
		var until int64
		if evt.Action.GetMuted() {
			until = evt.Action.GetMuteEndTimestamp()
			if until <= 0 {
				until = 1 << 40 // muted forever
			}
			if until > 1e12 {
				until /= 1000
			}
		}
		c.updateChatField(ctx, evt.JID, "muted_until", until)
	case *events.MarkChatAsRead:
		read := evt.Action.GetRead()
		chat := c.canon(ctx, evt.JID).String()
		if read {
			_ = c.Store.SetChatField(ctx, chat, "unread", 0)
			_ = c.Store.SetChatField(ctx, chat, "marked_unread", 0)
			if c.Notify != nil {
				c.Notify.Dismiss(chat)
			}
		} else {
			_ = c.Store.SetChatField(ctx, chat, "marked_unread", 1)
		}
		c.emitChat(ctx, chat)
	case *events.DeleteForMe:
		chat := c.canon(ctx, evt.ChatJID).String()
		_ = c.Store.DeleteMessage(ctx, chat, evt.MessageID)
		c.Emit("message.deleted", map[string]any{"chat": chat, "id": evt.MessageID})
		c.emitChat(ctx, chat)
	case *events.Star:
		chat := c.canon(ctx, evt.ChatJID).String()
		_ = c.Store.SetStarred(ctx, chat, evt.MessageID, evt.Action.GetStarred())
		c.emitMessage(ctx, chat, evt.MessageID)
	case *events.ClearChat:
		// Rare; a full refresh is simpler than tracking what was cleared.
		c.Emit("chats.changed", nil)
	case *events.Contact:
		c.forgetName(evt.JID)
		c.forgetName(c.canon(ctx, evt.JID))
		c.Emit("chats.changed", nil)
		if !evt.FromFullSync {
			go c.refreshSenders(context.Background(), evt.JID)
		}
	case *events.AppStateSyncComplete:
		// Full syncs store contact names in bulk without per-contact events,
		// so cached fallbacks (phone numbers) would otherwise stick until restart.
		c.forgetAllNames()
		c.Emit("chats.changed", nil)
		go c.refreshSenders(context.Background())
	case *events.PushName:
		c.forgetName(evt.JID)
		c.forgetName(c.canon(ctx, evt.JID))
		go c.refreshSenders(context.Background(), evt.JID)
	case *events.JoinedGroup:
		jid := evt.JID.String()
		_ = c.Store.EnsureChat(ctx, jid, true)
		_ = c.Store.SetChatName(ctx, jid, evt.Name)
		c.forgetName(evt.JID)
		c.emitChat(ctx, jid)
	case *events.GroupInfo:
		if evt.Name != nil {
			_ = c.Store.SetChatName(ctx, evt.JID.String(), evt.Name.Name)
			c.forgetName(evt.JID)
			c.emitChat(ctx, evt.JID.String())
		}
	case *events.Picture:
		jid := c.canon(ctx, evt.JID).String()
		_ = c.Store.SetChatAvatar(ctx, jid, "", "")
		c.mu.Lock()
		delete(avatarFetched, jid)
		c.mu.Unlock()
		c.Emit("avatar.changed", map[string]any{"jid": jid})
	case *events.Connected:
		c.setState("connected")
		go c.afterConnect(ctx)
	case *events.PairSuccess:
		c.Log.Infof("Paired as %s (%s)", evt.ID, evt.Platform)
		c.setState("connecting")
	case *events.OfflineSyncPreview:
		c.setSyncing(true)
	case *events.OfflineSyncCompleted:
		c.setSyncing(false)
	case *events.Disconnected:
		c.setState("disconnected")
	case *events.KeepAliveTimeout:
		c.setState("disconnected")
	case *events.KeepAliveRestored:
		c.setState("connected")
	case *events.StreamReplaced:
		c.setState("disconnected")
		c.notifySystem("WhatsApp session replaced", "Hermes was disconnected because the same session connected elsewhere.")
	case *events.LoggedOut:
		c.setState("logged_out")
		c.notifySystem("Logged out of WhatsApp", "This device was unlinked. Open Hermes to pair again.")
	case *events.ClientOutdated:
		c.Log.Warnf("Server says client is outdated; refreshing version and reconnecting")
		c.notifySystem("Hermes: WhatsApp client outdated",
			"WhatsApp rejected our client version. Hermes is retrying with the newest version; if it keeps failing run `hermes-update`.")
		go func() {
			c.refreshWAVersion(ctx)
			c.cli.Disconnect()
			time.Sleep(3 * time.Second)
			if err := c.cli.Connect(); err != nil {
				c.Log.Errorf("Reconnect after outdated failed: %v", err)
			}
		}()
	case *events.TemporaryBan:
		c.setState("banned")
		c.notifySystem("WhatsApp temporary ban", evt.String())
	case *events.ConnectFailure:
		c.Log.Errorf("Connect failure: %s %s", evt.Reason, evt.Message)
		c.setState("disconnected")
	case *events.CallOffer:
		from := c.canon(ctx, evt.From)
		video := evt.Data != nil && evt.Data.GetChildByTag("video").Tag == "video"
		c.Emit("call", map[string]any{"from": from.String(), "name": c.DisplayName(ctx, from), "id": evt.CallID, "video": video})
		if c.Notify != nil {
			c.Notify.NotifyCall(c.DisplayName(ctx, from), video)
		}
	case *events.CallTerminate:
		c.Emit("call.ended", map[string]any{"from": c.canon(ctx, evt.From).String(), "id": evt.CallID})
	}
}

func unixOrZero(t time.Time) int64 {
	if t.IsZero() {
		return 0
	}
	return t.Unix()
}

func (c *Core) setSyncing(v bool) {
	c.mu.Lock()
	c.syncing = v
	c.mu.Unlock()
	c.Emit("state", c.Status())
	if !v {
		c.Emit("chats.changed", nil)
	}
}

func (c *Core) notifySystem(summary, body string) {
	if c.Notify != nil {
		c.Notify.NotifySystem(summary, body)
	}
}

func (c *Core) updateChatField(ctx context.Context, jid types.JID, field string, value any) {
	chat := c.canon(ctx, jid).String()
	_ = c.Store.EnsureChat(ctx, chat, jid.Server == types.GroupServer)
	if err := c.Store.SetChatField(ctx, chat, field, value); err != nil {
		c.Log.Warnf("update chat %s %s: %v", chat, field, err)
	}
	c.emitChat(ctx, chat)
}

func (c *Core) emitChat(ctx context.Context, jid string) {
	if ch, _ := c.GetChat(ctx, jid); ch != nil {
		c.Emit("chat", ch)
	}
	c.emitUnread(ctx)
}

func (c *Core) emitUnread(ctx context.Context) {
	chats, msgs, err := c.Store.TotalUnread(ctx)
	if err == nil {
		c.Emit("unread", map[string]int{"chats": chats, "messages": msgs})
	}
}

func (c *Core) emitMessage(ctx context.Context, chat, id string) {
	if m, _ := c.Store.GetMessage(ctx, chat, id); m != nil {
		c.Emit("message", m)
	}
}

// handleMessage processes live (live=true) or history messages. histStatus is the
// delivery status from history sync, or -1 for live messages.
func (c *Core) handleMessage(ctx context.Context, evt *events.Message, live bool, histStatus int) {
	msg := evt.Message
	if msg == nil {
		return
	}
	info := evt.Info
	chatJID := c.canonFromSource(ctx, info.Chat, info.RecipientAlt)
	if !info.IsGroup && !info.IsFromMe {
		chatJID = c.canonFromSource(ctx, info.Chat, info.SenderAlt)
	}
	chat := chatJID.String()
	sender := c.canonFromSource(ctx, info.Sender, info.SenderAlt).String()

	if pm := msg.GetProtocolMessage(); pm != nil {
		target := pm.GetKey().GetID()
		switch pm.GetType() {
		case waE2E.ProtocolMessage_REVOKE:
			_ = c.Store.RevokeMessage(ctx, chat, target)
			c.emitMessage(ctx, chat, target)
			c.emitChat(ctx, chat)
		case waE2E.ProtocolMessage_MESSAGE_EDIT:
			if text := textOf(pm.GetEditedMessage()); text != "" {
				_ = c.Store.EditMessage(ctx, chat, target, text)
				c.emitMessage(ctx, chat, target)
				c.emitChat(ctx, chat)
			}
		case waE2E.ProtocolMessage_EPHEMERAL_SETTING:
			_ = c.Store.SetChatField(ctx, chat, "ephemeral", int64(pm.GetEphemeralExpiration()))
			c.emitChat(ctx, chat)
		}
		return
	}
	if evt.IsEdit {
		if text := textOf(msg); text != "" {
			_ = c.Store.EditMessage(ctx, chat, info.ID, text)
			c.emitMessage(ctx, chat, info.ID)
		}
		return
	}
	if rm := msg.GetReactionMessage(); rm != nil {
		target := rm.GetKey().GetID()
		_ = c.Store.SetReaction(ctx, chat, target, sender, rm.GetText(), info.Timestamp.Unix())
		c.emitMessage(ctx, chat, target)
		return
	}
	if msg.GetPollUpdateMessage() != nil {
		c.handlePollVote(ctx, evt, chat, sender)
		return
	}

	m := c.convert(ctx, evt)
	if m == nil {
		return
	}
	if histStatus >= 0 {
		m.Status = histStatus
	} else if m.FromMe {
		m.Status = hs.StatusSent
	}
	_ = c.Store.EnsureChat(ctx, chat, info.IsGroup)
	inserted, err := c.Store.UpsertMessage(ctx, m)
	if err != nil {
		c.Log.Errorf("store message %s: %v", info.ID, err)
		return
	}
	if !live {
		return
	}
	incUnread := inserted && !m.FromMe && !c.focused(chat) && chat != "status@broadcast"
	_ = c.Store.BumpChat(ctx, chat, m.ID, m.TS, incUnread)
	if m.FromMe {
		// Replying from the phone implies the chat was read there.
		_ = c.Store.SetChatField(ctx, chat, "unread", 0)
	} else if inserted && (!info.IsGroup || m.MentionsMe) {
		// Someone needs you again: a snooze shouldn't hide a fresh DM or mention.
		_ = c.Store.Snooze(ctx, chat, 0, "")
	}
	m.Reactions = []hs.Reaction{}
	c.Emit("message", m)
	c.emitChat(ctx, chat)

	if inserted && !m.FromMe && m.MediaSize <= autoDownloadMax {
		switch m.Type {
		case "image", "sticker", "voice", "audio", "gif":
			if !m.ViewOnce {
				go func() {
					if _, err := c.DownloadMedia(context.Background(), chat, m.ID); err != nil {
						c.Log.Warnf("auto-download %s: %v", m.ID, err)
						return
					}
					c.autoTranscribe(context.Background(), m)
				}()
			}
		}
	}
	if incUnread && c.Notify != nil {
		if ch, _ := c.GetChat(ctx, chat); ch != nil && ch.MutedUntil <= time.Now().Unix() {
			c.Notify.NotifyMessage(ch, m)
		}
	}
}

func (c *Core) handleReceipt(ctx context.Context, evt *events.Receipt) {
	chat := c.canonFromSource(ctx, evt.Chat, evt.RecipientAlt).String()
	if evt.IsFromMe {
		// One of our other devices read this chat.
		if evt.Type == types.ReceiptTypeRead || evt.Type == types.ReceiptTypeReadSelf {
			_ = c.Store.SetChatField(ctx, chat, "unread", 0)
			if c.Notify != nil {
				c.Notify.Dismiss(chat)
			}
			c.emitChat(ctx, chat)
		}
		return
	}
	var status int
	switch evt.Type {
	case types.ReceiptTypeDelivered:
		status = hs.StatusDelivered
	case types.ReceiptTypeRead, types.ReceiptTypeReadSelf:
		status = hs.StatusRead
	case types.ReceiptTypePlayed, types.ReceiptTypePlayedSelf:
		status = hs.StatusPlayed
	default:
		return
	}
	if evt.IsGroup {
		// Group ticks need every participant; approximate with "anyone" for now.
		chat = evt.Chat.String()
	}
	_ = c.Store.SetStatus(ctx, chat, evt.MessageIDs, status)
	c.Emit("receipt", map[string]any{"chat": chat, "ids": evt.MessageIDs, "status": status})
	c.emitChat(ctx, chat)
}

func histStatusOf(wm *waWeb.WebMessageInfo) int {
	switch wm.GetStatus() {
	case waWeb.WebMessageInfo_ERROR:
		return hs.StatusFailed
	case waWeb.WebMessageInfo_PENDING:
		return hs.StatusPending
	case waWeb.WebMessageInfo_SERVER_ACK:
		return hs.StatusSent
	case waWeb.WebMessageInfo_DELIVERY_ACK:
		return hs.StatusDelivered
	case waWeb.WebMessageInfo_READ:
		return hs.StatusRead
	case waWeb.WebMessageInfo_PLAYED:
		return hs.StatusPlayed
	}
	return hs.StatusSent
}

func (c *Core) handleHistory(ctx context.Context, data *waHistorySync.HistorySync) {
	if data == nil {
		return
	}
	c.setSyncing(true)
	defer func() {
		c.mu.Lock()
		c.syncing = false
		c.mu.Unlock()
		c.Emit("state", c.Status())
	}()
	c.Log.Infof("History sync %s: %d conversations, progress %d%%", data.GetSyncType(), len(data.GetConversations()), data.GetProgress())
	c.storeInlineContacts(ctx, data)
	// Profile names on history messages; whatsmeow only stores live ones.
	pushed := map[types.JID]bool{}
	defer func() {
		if len(pushed) > 0 {
			jids := make([]types.JID, 0, len(pushed))
			for j := range pushed {
				jids = append(jids, j)
			}
			c.forgetAllNames()
			c.refreshSenders(ctx, jids...)
		}
	}()
	for _, conv := range data.GetConversations() {
		rawJID, err := types.ParseJID(conv.GetID())
		if err != nil {
			continue
		}
		jid := c.canon(ctx, rawJID)
		if pn := conv.GetPnJID(); pn != "" && jid.Server == types.HiddenUserServer {
			if pj, err := types.ParseJID(pn); err == nil {
				jid = pj.ToNonAD()
			}
		}
		chat := jid.String()
		isGroup := jid.Server == types.GroupServer
		_ = c.Store.EnsureChat(ctx, chat, isGroup)
		if name := conv.GetName(); name != "" && isGroup {
			_ = c.Store.SetChatName(ctx, chat, name)
		} else if !isGroup {
			c.storeConvName(ctx, jid, conv)
		}
		if data.GetSyncType() == waHistorySync.HistorySync_INITIAL_BOOTSTRAP || data.GetSyncType() == waHistorySync.HistorySync_RECENT {
			_ = c.Store.SetChatField(ctx, chat, "unread", int(conv.GetUnreadCount()))
			_ = c.Store.SetChatField(ctx, chat, "marked_unread", conv.GetMarkedAsUnread())
			_ = c.Store.SetChatField(ctx, chat, "archived", conv.GetArchived())
			_ = c.Store.SetChatField(ctx, chat, "pinned_ts", int64(conv.GetPinned()))
			mute := int64(conv.GetMuteEndTime())
			if mute > 1e12 {
				mute /= 1000
			}
			_ = c.Store.SetChatField(ctx, chat, "muted_until", mute)
			_ = c.Store.SetChatField(ctx, chat, "ephemeral", int64(conv.GetEphemeralExpiration()))
		}
		for _, hm := range conv.GetMessages() {
			wm := hm.GetMessage()
			if wm == nil {
				continue
			}
			evt, err := c.cli.ParseWebMessage(rawJID, wm)
			if err != nil {
				continue
			}
			if pn := wm.GetPushName(); pn != "" && !evt.Info.IsFromMe && !pushed[evt.Info.Sender] {
				pushed[evt.Info.Sender] = true
				c.savePushName(ctx, evt.Info.Sender, evt.Info.SenderAlt, pn)
			}
			c.handleMessage(ctx, evt, false, histStatusOf(wm))
			for _, r := range wm.GetReactions() {
				if r.GetKey() == nil {
					continue
				}
				sender := evt.Info.Sender
				if r.GetKey().GetFromMe() {
					sender = c.cli.Store.ID.ToNonAD()
				} else if p := r.GetKey().GetParticipant(); p != "" {
					if pj, err := types.ParseJID(p); err == nil {
						sender = pj
					}
				} else if !isGroup {
					sender = jid
				}
				_ = c.Store.SetReaction(ctx, chat, evt.Info.ID, c.canon(ctx, sender).String(), r.GetText(), r.GetSenderTimestampMS()/1000)
			}
		}
		_ = c.Store.RecomputeLast(ctx, chat)
	}
	c.Emit("sync", map[string]any{"progress": data.GetProgress(), "type": data.GetSyncType().String()})
	c.Emit("chats.changed", nil)
	c.emitUnread(ctx)
}

var avatarFetched = map[string]time.Time{}

// storeInlineContacts saves address-book names that newer phones send inside
// history sync instead of (or as well as) the contacts app-state patch.
// whatsmeow ignores this field, so without it most saved names never arrive.
func (c *Core) storeInlineContacts(ctx context.Context, data *waHistorySync.HistorySync) {
	ics := data.GetInlineContacts()
	if len(ics) == 0 {
		return
	}
	entries := make([]store.ContactEntry, 0, len(ics)*2)
	for _, ic := range ics {
		if ic.GetFullName() == "" && ic.GetFirstName() == "" {
			continue
		}
		for _, raw := range []string{ic.GetPnJID(), ic.GetLidJID()} {
			if j, err := types.ParseJID(raw); err == nil && raw != "" {
				entries = append(entries, store.ContactEntry{JID: j.ToNonAD(), FirstName: ic.GetFirstName(), FullName: ic.GetFullName()})
			}
		}
	}
	if err := c.cli.Store.Contacts.PutAllContactNames(ctx, entries); err != nil {
		c.Log.Warnf("Saving %d inline contacts: %v", len(entries), err)
		return
	}
	c.Log.Infof("Saved %d inline contact names from history sync", len(entries))
	c.forgetAllNames()
}

// savePushName records a profile name under both of a person's JIDs without
// overwriting newer ones from live messages.
func (c *Core) savePushName(ctx context.Context, user, alt types.JID, name string) {
	user = user.ToNonAD()
	if alt.IsEmpty() {
		alt, _ = c.cli.Store.GetAltJID(ctx, user)
	}
	for _, j := range []types.JID{user, alt.ToNonAD()} {
		if j.IsEmpty() {
			continue
		}
		if info, err := c.cli.Store.Contacts.GetContact(ctx, j); err == nil && info.PushName != "" {
			continue
		}
		_, _, _ = c.cli.Store.Contacts.PutPushName(ctx, j, name)
	}
}

// storeConvName uses a DM's display name from history sync as the contact name
// when the contact store has no saved name for that person yet.
func (c *Core) storeConvName(ctx context.Context, jid types.JID, conv *waHistorySync.Conversation) {
	name := conv.GetDisplayName()
	if name == "" {
		name = conv.GetName()
	}
	if name == "" || jid.Server != types.DefaultUserServer {
		return
	}
	if info, err := c.cli.Store.Contacts.GetContact(ctx, jid); err == nil && info.FullName != "" {
		return
	}
	if err := c.cli.Store.Contacts.PutContactName(ctx, jid, "", name); err == nil {
		c.forgetName(jid)
	}
}

func (c *Core) afterConnect(ctx context.Context) {
	if c.cli.Store.PushName != "" {
		// Stay "unavailable" so the phone keeps getting push notifications;
		// the UI flips us to available while its window is focused.
		_ = c.cli.SendPresence(ctx, types.PresenceUnavailable)
	}
	groups, err := c.cli.GetJoinedGroups(ctx)
	if err != nil {
		c.Log.Warnf("GetJoinedGroups: %v", err)
	} else {
		for _, g := range groups {
			jid := g.JID.String()
			_ = c.Store.EnsureChat(ctx, jid, true)
			if g.Name != "" {
				_ = c.Store.SetChatName(ctx, jid, g.Name)
			}
			c.forgetName(g.JID)
		}
		c.Emit("chats.changed", nil)
	}
	c.emitUnread(ctx)
	c.Emit("state", c.Status())
	c.refreshSenders(ctx)
}
