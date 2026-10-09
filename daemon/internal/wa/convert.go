package wa

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"go.mau.fi/whatsmeow/proto/waE2E"
	"go.mau.fi/whatsmeow/types"
	"go.mau.fi/whatsmeow/types/events"
	"google.golang.org/protobuf/proto"

	hs "github.com/aadit/hermes/daemon/internal/store"
)

// canon maps LID addresses to phone-number JIDs where we know the mapping, so a
// person's DM is always one chat no matter which addressing mode a message used.
func (c *Core) canon(ctx context.Context, jid types.JID) types.JID {
	jid = jid.ToNonAD()
	if jid.Server == types.HiddenUserServer && c.cli != nil {
		if pn, err := c.cli.Store.LIDs.GetPNForLID(ctx, jid); err == nil && !pn.IsEmpty() {
			return pn.ToNonAD()
		}
	}
	return jid
}

func (c *Core) canonFromSource(ctx context.Context, jid, alt types.JID) types.JID {
	if jid.Server == types.HiddenUserServer && !alt.IsEmpty() && alt.Server == types.DefaultUserServer {
		return alt.ToNonAD()
	}
	return c.canon(ctx, jid)
}

func (c *Core) isMe(jid types.JID) bool {
	if c.cli == nil || c.cli.Store.ID == nil {
		return false
	}
	return jid.User == c.cli.Store.ID.User || jid.User == c.cli.Store.GetLID().User
}

// DisplayName resolves the best human name for a user or group JID.
func (c *Core) DisplayName(ctx context.Context, jid types.JID) string {
	jid = jid.ToNonAD()
	c.mu.RLock()
	name, ok := c.nameCache[jid]
	c.mu.RUnlock()
	if ok && name != "" {
		return name
	}
	switch jid.Server {
	case types.GroupServer, types.NewsletterServer:
		if ch, _ := c.Store.GetChat(ctx, jid.String()); ch != nil && ch.Name != "" {
			name = ch.Name
		}
	case types.BroadcastServer:
		if jid.User == "status" {
			name = "Status"
		}
	default:
		if c.isMe(jid) {
			return "You"
		}
		name, _ = c.contactName(ctx, jid)
		if name == "" && jid.Server == types.DefaultUserServer {
			name = "+" + jid.User
		}
	}
	if name == "" {
		name = jid.User
	} else {
		c.mu.Lock()
		c.nameCache[jid] = name
		c.mu.Unlock()
	}
	return name
}

// contactName looks a person up under both their phone-number JID and their
// LID, since WhatsApp files names under either. saved is false when the only
// name known is the profile (push) name they set themselves.
func (c *Core) contactName(ctx context.Context, jid types.JID) (name string, saved bool) {
	if c.cli == nil {
		return "", false
	}
	ids := []types.JID{jid}
	if alt, err := c.cli.Store.GetAltJID(ctx, jid); err == nil && !alt.IsEmpty() {
		ids = append(ids, alt.ToNonAD())
	}
	var push, redacted string
	for _, id := range ids {
		info, err := c.cli.Store.Contacts.GetContact(ctx, id)
		if err != nil || !info.Found {
			continue
		}
		for _, n := range []string{info.FullName, info.FirstName, info.BusinessName} {
			if n != "" {
				return n, true
			}
		}
		if push == "" {
			push = info.PushName
		}
		if redacted == "" {
			redacted = info.RedactedPhone
		}
	}
	if push != "" {
		return push, false
	}
	return redacted, false
}

// SenderName is how a message author is labelled: saved name, else "~ " plus
// their profile name (as the official app does), else the phone number.
func (c *Core) SenderName(ctx context.Context, jid types.JID, pushName string) string {
	jid = jid.ToNonAD()
	if c.isMe(jid) {
		return "You"
	}
	name, saved := c.contactName(ctx, jid)
	switch {
	case saved:
		return name
	case name != "" && !strings.HasPrefix(name, "+"):
		return "~ " + name
	case pushName != "":
		return "~ " + pushName
	case jid.Server == types.DefaultUserServer:
		return "+" + jid.User
	}
	return jid.User
}

// refreshSenders re-labels stored messages after names change. With no JIDs
// it walks every sender (used once per connect as a backfill).
func (c *Core) refreshSenders(ctx context.Context, jids ...types.JID) {
	if len(jids) == 0 {
		all, err := c.Store.Senders(ctx)
		if err != nil {
			c.Log.Warnf("Listing senders: %v", err)
			return
		}
		for _, s := range all {
			if j, err := types.ParseJID(s); err == nil {
				jids = append(jids, j)
			}
		}
	}
	var changed int64
	seen := map[types.JID]bool{}
	for _, j := range jids {
		j = c.canon(ctx, j)
		if seen[j] {
			continue
		}
		seen[j] = true
		name := c.SenderName(ctx, j, "")
		if name == "+"+j.User || name == j.User {
			continue // nothing better than what's stored
		}
		n, _ := c.Store.RenameSender(ctx, j.String(), name)
		changed += n
	}
	if changed > 0 {
		c.Log.Infof("Updated sender names on %d messages", changed)
		c.Emit("chats.changed", nil)
		c.Emit("messages.changed", nil)
	}
}

func (c *Core) forgetAllNames() {
	c.mu.Lock()
	c.nameCache = map[types.JID]string{}
	c.mu.Unlock()
}

func (c *Core) forgetName(jid types.JID) {
	c.mu.Lock()
	delete(c.nameCache, jid.ToNonAD())
	c.mu.Unlock()
}

// textOf extracts plain text from any message kind, used for quotes and previews.
func textOf(m *waE2E.Message) string {
	if m == nil {
		return ""
	}
	switch {
	case m.Conversation != nil:
		return m.GetConversation()
	case m.ExtendedTextMessage != nil:
		return m.GetExtendedTextMessage().GetText()
	case m.ImageMessage != nil:
		return m.GetImageMessage().GetCaption()
	case m.VideoMessage != nil:
		return m.GetVideoMessage().GetCaption()
	case m.DocumentMessage != nil:
		if c := m.GetDocumentMessage().GetCaption(); c != "" {
			return c
		}
		return m.GetDocumentMessage().GetFileName()
	case m.DocumentWithCaptionMessage != nil:
		return textOf(m.GetDocumentWithCaptionMessage().GetMessage())
	case m.AudioMessage != nil:
		return "🎤 Voice message"
	case m.StickerMessage != nil:
		return "💟 Sticker"
	case m.LocationMessage != nil:
		return "📍 Location"
	case m.ContactMessage != nil:
		return "👤 " + m.GetContactMessage().GetDisplayName()
	case m.PollCreationMessage != nil:
		return "📊 " + m.GetPollCreationMessage().GetName()
	case m.PollCreationMessageV3 != nil:
		return "📊 " + m.GetPollCreationMessageV3().GetName()
	}
	return ""
}

func contextOf(m *waE2E.Message) *waE2E.ContextInfo {
	switch {
	case m.ExtendedTextMessage != nil:
		return m.GetExtendedTextMessage().GetContextInfo()
	case m.ImageMessage != nil:
		return m.GetImageMessage().GetContextInfo()
	case m.VideoMessage != nil:
		return m.GetVideoMessage().GetContextInfo()
	case m.AudioMessage != nil:
		return m.GetAudioMessage().GetContextInfo()
	case m.DocumentMessage != nil:
		return m.GetDocumentMessage().GetContextInfo()
	case m.StickerMessage != nil:
		return m.GetStickerMessage().GetContextInfo()
	case m.LocationMessage != nil:
		return m.GetLocationMessage().GetContextInfo()
	case m.ContactMessage != nil:
		return m.GetContactMessage().GetContextInfo()
	}
	return nil
}

type pollExtra struct {
	Options    []string `json:"options"`
	Selectable uint32   `json:"selectable"`
}

type locationExtra struct {
	Lat     float64 `json:"lat"`
	Lng     float64 `json:"lng"`
	Name    string  `json:"name,omitempty"`
	Address string  `json:"address,omitempty"`
	Live    bool    `json:"live,omitempty"`
}

type contactExtra struct {
	Name  string `json:"name"`
	VCard string `json:"vcard"`
}

// convert turns a whatsmeow message event into Hermes' storage model.
// It returns nil for messages that are not displayable (protocol messages, reactions, etc.).
func (c *Core) convert(ctx context.Context, evt *events.Message) *hs.Message {
	info := evt.Info
	msg := evt.Message
	if msg == nil {
		return nil
	}
	if dwc := msg.GetDocumentWithCaptionMessage(); dwc != nil && dwc.GetMessage() != nil {
		msg = dwc.GetMessage()
	}
	chat := c.canonFromSource(ctx, info.Chat, info.RecipientAlt)
	if !info.IsGroup && !info.IsFromMe {
		chat = c.canonFromSource(ctx, info.Chat, info.SenderAlt)
	}
	sender := c.canonFromSource(ctx, info.Sender, info.SenderAlt)
	m := &hs.Message{
		Chat:     chat.String(),
		ID:       info.ID,
		Sender:   sender.String(),
		FromMe:   info.IsFromMe,
		TS:       info.Timestamp.Unix(),
		Status:   hs.StatusSent,
		ViewOnce: evt.IsViewOnce,
	}
	if info.IsFromMe {
		m.SenderName = "You"
	} else {
		m.SenderName = c.SenderName(ctx, sender, info.PushName)
	}
	raw, _ := proto.Marshal(msg)

	switch {
	case msg.Conversation != nil || msg.ExtendedTextMessage != nil:
		m.Type = "text"
		m.Text = textOf(msg)
	case msg.ImageMessage != nil:
		im := msg.GetImageMessage()
		m.Type, m.Text, m.MediaMime = "image", im.GetCaption(), im.GetMimetype()
		m.MediaSize, m.MediaW, m.MediaH = int64(im.GetFileLength()), int(im.GetWidth()), int(im.GetHeight())
		m.ThumbPath = c.saveThumb(info.ID, im.GetJPEGThumbnail())
		m.ViewOnce = m.ViewOnce || im.GetViewOnce()
		m.Raw = raw
	case msg.VideoMessage != nil:
		vm := msg.GetVideoMessage()
		m.Type, m.Text, m.MediaMime = "video", vm.GetCaption(), vm.GetMimetype()
		if vm.GetGifPlayback() {
			m.Type = "gif"
		}
		m.MediaSize, m.MediaW, m.MediaH, m.MediaSecs = int64(vm.GetFileLength()), int(vm.GetWidth()), int(vm.GetHeight()), int(vm.GetSeconds())
		m.ThumbPath = c.saveThumb(info.ID, vm.GetJPEGThumbnail())
		m.ViewOnce = m.ViewOnce || vm.GetViewOnce()
		m.Raw = raw
	case msg.AudioMessage != nil:
		am := msg.GetAudioMessage()
		m.Type, m.MediaMime = "audio", am.GetMimetype()
		if am.GetPTT() {
			m.Type = "voice"
		}
		m.MediaSize, m.MediaSecs = int64(am.GetFileLength()), int(am.GetSeconds())
		if wf := am.GetWaveform(); len(wf) > 0 {
			ints := make([]int, len(wf))
			for i, b := range wf {
				ints[i] = int(b)
			}
			m.Extra = hs.MarshalExtra(map[string]any{"waveform": ints})
		}
		m.Raw = raw
	case msg.DocumentMessage != nil:
		dm := msg.GetDocumentMessage()
		m.Type, m.MediaMime, m.FileName = "document", dm.GetMimetype(), dm.GetFileName()
		if m.FileName == "" {
			m.FileName = dm.GetTitle()
		}
		m.Text = dm.GetCaption()
		m.MediaSize = int64(dm.GetFileLength())
		m.ThumbPath = c.saveThumb(info.ID, dm.GetJPEGThumbnail())
		m.Extra = hs.MarshalExtra(map[string]any{"pages": dm.GetPageCount()})
		m.Raw = raw
	case msg.StickerMessage != nil:
		sm := msg.GetStickerMessage()
		m.Type, m.MediaMime = "sticker", sm.GetMimetype()
		m.MediaW, m.MediaH = int(sm.GetWidth()), int(sm.GetHeight())
		m.Raw = raw
	case msg.LocationMessage != nil:
		lm := msg.GetLocationMessage()
		m.Type = "location"
		m.Text = lm.GetName()
		m.Extra = hs.MarshalExtra(locationExtra{lm.GetDegreesLatitude(), lm.GetDegreesLongitude(), lm.GetName(), lm.GetAddress(), false})
		m.ThumbPath = c.saveThumb(info.ID, lm.GetJPEGThumbnail())
	case msg.LiveLocationMessage != nil:
		lm := msg.GetLiveLocationMessage()
		m.Type = "location"
		m.Text = lm.GetCaption()
		m.Extra = hs.MarshalExtra(locationExtra{lm.GetDegreesLatitude(), lm.GetDegreesLongitude(), "", "", true})
	case msg.ContactMessage != nil:
		cm := msg.GetContactMessage()
		m.Type, m.Text = "contact", cm.GetDisplayName()
		m.Extra = hs.MarshalExtra([]contactExtra{{cm.GetDisplayName(), cm.GetVcard()}})
	case msg.ContactsArrayMessage != nil:
		ca := msg.GetContactsArrayMessage()
		m.Type, m.Text = "contact", ca.GetDisplayName()
		var list []contactExtra
		for _, cm := range ca.GetContacts() {
			list = append(list, contactExtra{cm.GetDisplayName(), cm.GetVcard()})
		}
		m.Extra = hs.MarshalExtra(list)
	case msg.PollCreationMessage != nil || msg.PollCreationMessageV3 != nil || msg.PollCreationMessageV2 != nil:
		pm := msg.GetPollCreationMessage()
		if pm == nil {
			pm = msg.GetPollCreationMessageV3()
		}
		if pm == nil {
			pm = msg.GetPollCreationMessageV2()
		}
		m.Type, m.Text = "poll", pm.GetName()
		var opts []string
		for _, o := range pm.GetOptions() {
			opts = append(opts, o.GetOptionName())
		}
		m.Extra = hs.MarshalExtra(pollExtra{opts, pm.GetSelectableOptionsCount()})
		m.Raw = raw
	default:
		return nil
	}

	if ci := contextOf(msg); ci != nil && ci.GetStanzaID() != "" {
		m.QuotedID = ci.GetStanzaID()
		if p := ci.GetParticipant(); p != "" {
			if pj, err := types.ParseJID(p); err == nil {
				m.QuotedSender = c.DisplayName(ctx, c.canon(ctx, pj))
			}
		}
		m.QuotedText = textOf(ci.GetQuotedMessage())
	}
	if m.Text != "" {
		m.Text = c.resolveMentions(ctx, m.Text, contextOf(msg))
	}
	if !m.FromMe && info.IsGroup {
		m.MentionsMe = c.mentionsMe(contextOf(msg))
	}
	return m
}

// mentionsMe reports whether a message @-mentions this account or replies to one of its messages.
func (c *Core) mentionsMe(ci *waE2E.ContextInfo) bool {
	if ci == nil {
		return false
	}
	for _, mj := range ci.GetMentionedJID() {
		if j, err := types.ParseJID(mj); err == nil && c.isMe(j) {
			return true
		}
	}
	if p := ci.GetParticipant(); p != "" && ci.GetStanzaID() != "" {
		if j, err := types.ParseJID(p); err == nil && c.isMe(j) {
			return true
		}
	}
	return false
}

// resolveMentions replaces "@<number>" with "@Name" for mentioned users.
func (c *Core) resolveMentions(ctx context.Context, text string, ci *waE2E.ContextInfo) string {
	if ci == nil {
		return text
	}
	for _, mj := range ci.GetMentionedJID() {
		j, err := types.ParseJID(mj)
		if err != nil {
			continue
		}
		name := c.DisplayName(ctx, c.canon(ctx, j))
		if !strings.HasPrefix(name, "+") {
			text = strings.ReplaceAll(text, "@"+j.User, "@"+name)
		}
	}
	return text
}

func (c *Core) saveThumb(id string, data []byte) string {
	if len(data) == 0 {
		return ""
	}
	p := filepath.Join(c.Paths.ThumbDir(), safeName(id)+".jpg")
	if _, err := os.Stat(p); err == nil {
		return p
	}
	if err := os.WriteFile(p, data, 0o600); err != nil {
		return ""
	}
	return p
}

func safeName(s string) string {
	return strings.Map(func(r rune) rune {
		if r == '/' || r == '\\' || r == 0 || r == ':' {
			return '_'
		}
		return r
	}, s)
}

func fmtSize(n int64) string {
	switch {
	case n > 1<<30:
		return fmt.Sprintf("%.1f GB", float64(n)/(1<<30))
	case n > 1<<20:
		return fmt.Sprintf("%.1f MB", float64(n)/(1<<20))
	case n > 1<<10:
		return fmt.Sprintf("%.0f KB", float64(n)/(1<<10))
	}
	return fmt.Sprintf("%d B", n)
}
