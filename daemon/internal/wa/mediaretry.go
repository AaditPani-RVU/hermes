package wa

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"time"

	"go.mau.fi/whatsmeow"
	"go.mau.fi/whatsmeow/proto/waE2E"
	"go.mau.fi/whatsmeow/proto/waMmsRetry"
	"go.mau.fi/whatsmeow/types"
	"go.mau.fi/whatsmeow/types/events"
	"google.golang.org/protobuf/proto"

	hs "github.com/aadit/hermes/daemon/internal/store"
)

// ---- Media retry ----
//
// WhatsApp deletes media from its CDN after a while (download → 404/410). The official
// apps then ask the sender's phone (or yours, for your own messages) to re-upload it.
// We do the same: send a media retry receipt, wait for the MediaRetry event with the
// new direct path, and download again.

func isExpiredMedia(err error) bool {
	return errors.Is(err, whatsmeow.ErrMediaDownloadFailedWith404) || errors.Is(err, whatsmeow.ErrMediaDownloadFailedWith410)
}

// mediaPart returns the downloadable part of a message and a setter for its direct path.
func mediaPart(msg *waE2E.Message) (whatsmeow.DownloadableMessage, func(string)) {
	switch {
	case msg.ImageMessage != nil:
		return msg.ImageMessage, func(p string) { msg.ImageMessage.DirectPath = &p }
	case msg.VideoMessage != nil:
		return msg.VideoMessage, func(p string) { msg.VideoMessage.DirectPath = &p }
	case msg.AudioMessage != nil:
		return msg.AudioMessage, func(p string) { msg.AudioMessage.DirectPath = &p }
	case msg.DocumentMessage != nil:
		return msg.DocumentMessage, func(p string) { msg.DocumentMessage.DirectPath = &p }
	case msg.StickerMessage != nil:
		return msg.StickerMessage, func(p string) { msg.StickerMessage.DirectPath = &p }
	}
	return nil, nil
}

func (c *Core) retryMedia(ctx context.Context, m *hs.Message, msg *waE2E.Message) ([]byte, error) {
	part, setPath := mediaPart(msg)
	if part == nil {
		return nil, errors.New("media expired and can't be re-requested")
	}
	chat, err := parseJID(m.Chat)
	if err != nil {
		return nil, err
	}
	info := &types.MessageInfo{ID: m.ID, MessageSource: types.MessageSource{
		Chat:     chat,
		IsFromMe: m.FromMe,
		IsGroup:  chat.Server == types.GroupServer,
	}}
	if m.FromMe {
		info.Sender = c.cli.Store.ID.ToNonAD()
	} else if s, err := parseJID(m.Sender); err == nil {
		info.Sender = s
	}

	wait := make(chan *events.MediaRetry, 1)
	c.mu.Lock()
	c.mediaWait[m.ID] = wait
	c.mu.Unlock()
	defer func() {
		c.mu.Lock()
		delete(c.mediaWait, m.ID)
		c.mu.Unlock()
	}()

	if err := c.cli.SendMediaRetryReceipt(ctx, info, part.GetMediaKey()); err != nil {
		return nil, fmt.Errorf("media retry: %w", err)
	}
	// We store chats under phone numbers, but the phone may file this one under its LID
	// and ignore a request it can't match. Ask under the LID form too; only one will answer.
	if lidInfo := c.lidForm(ctx, info); lidInfo != nil {
		if err := c.cli.SendMediaRetryReceipt(ctx, lidInfo, part.GetMediaKey()); err != nil {
			c.Log.Warnf("media retry (lid): %v", err)
		}
	}
	var evt *events.MediaRetry
	select {
	case evt = <-wait:
	case <-time.After(45 * time.Second):
		return nil, errors.New("media expired, and the phone didn't re-upload it (is it online?)")
	case <-ctx.Done():
		return nil, ctx.Err()
	}
	notif, err := whatsmeow.DecryptMediaRetryNotification(evt, part.GetMediaKey())
	if err != nil {
		return nil, fmt.Errorf("media retry: %w", err)
	}
	if notif.GetResult() != waMmsRetry.MediaRetryNotification_SUCCESS {
		return nil, fmt.Errorf("the phone no longer has this file (%s)", strings.ToLower(notif.GetResult().String()))
	}
	setPath(notif.GetDirectPath())
	data, err := c.cli.DownloadAny(ctx, msg)
	if err != nil {
		return nil, fmt.Errorf("download after retry: %w", err)
	}
	// Keep the fresh path so the next download doesn't need another round trip.
	if raw, err := proto.Marshal(msg); err == nil {
		_ = c.Store.SetRaw(ctx, m.Chat, m.ID, raw)
	}
	return data, nil
}

// lidForm returns a copy of info addressed with LIDs instead of phone numbers, or nil if none are known.
func (c *Core) lidForm(ctx context.Context, info *types.MessageInfo) *types.MessageInfo {
	toLID := func(j types.JID) (types.JID, bool) {
		if j.Server != types.DefaultUserServer {
			return j, false
		}
		lid, err := c.cli.Store.LIDs.GetLIDForPN(ctx, j)
		if err != nil || lid.IsEmpty() {
			return j, false
		}
		return lid, true
	}
	out := *info
	changed := false
	if !info.IsGroup {
		out.Chat, changed = toLID(info.Chat)
	} else if info.Sender.Server == types.DefaultUserServer {
		var ok bool
		out.Sender, ok = toLID(info.Sender)
		changed = changed || ok
	}
	if !changed {
		return nil
	}
	return &out
}

func (c *Core) handleMediaRetry(evt *events.MediaRetry) {
	c.mu.Lock()
	wait := c.mediaWait[evt.MessageID]
	c.mu.Unlock()
	if wait != nil {
		select {
		case wait <- evt:
		default:
		}
	}
}
