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
	"regexp"
	"strings"
	"time"

	"go.mau.fi/whatsmeow"
	"go.mau.fi/whatsmeow/types"
	"go.mau.fi/whatsmeow/types/events"

	hs "github.com/aadit/hermes/daemon/internal/store"
)

// ---- Channels (newsletters) ----
//
// Posts are fetched on demand and stored as messages in a chat named after the channel,
// so the normal conversation view, media download and search work. Channels are kept out
// of the inbox, the chat list, unread counts and notifications.

type Channel struct {
	JID         string `json:"jid"`
	Name        string `json:"name"`
	Description string `json:"description"`
	Subscribers int    `json:"subscribers"`
	Verified    bool   `json:"verified"`
	AvatarPath  string `json:"avatarPath"`
	Muted       bool   `json:"muted"`
	LastTS      int64  `json:"lastTs"`
	LastPreview string `json:"lastPreview"`
}

func IsChannel(jid string) bool { return strings.HasSuffix(jid, "@"+types.NewsletterServer) }

func (c *Core) channelFrom(ctx context.Context, m *types.NewsletterMetadata) *Channel {
	jid := m.ID.String()
	ch := &Channel{JID: jid, Name: m.ThreadMeta.Name.Text, Description: m.ThreadMeta.Description.Text,
		Subscribers: m.ThreadMeta.SubscriberCount, Verified: m.ThreadMeta.VerificationState == types.NewsletterVerificationStateVerified}
	if m.ViewerMeta != nil {
		ch.Muted = m.ViewerMeta.Mute == types.NewsletterMuteOn
	}
	_ = c.Store.EnsureChat(ctx, jid, false)
	if ch.Name != "" {
		_ = c.Store.SetChatName(ctx, jid, ch.Name)
	}
	if stored, _ := c.Store.GetChat(ctx, jid); stored != nil {
		ch.LastTS, ch.LastPreview, ch.AvatarPath = stored.LastTS, stored.LastPreview, stored.AvatarPath
	}
	pic := m.ThreadMeta.Picture
	if pic == nil {
		pic = &m.ThreadMeta.Preview
	}
	url := pic.URL
	if url == "" && pic.DirectPath != "" {
		url = "https://mmg.whatsapp.net" + pic.DirectPath // channel pictures are public, path-only
	}
	if url != "" {
		ch.AvatarPath = c.cacheChannelPicture(ctx, jid, pic.ID, url)
	}
	return ch
}

// cacheChannelPicture downloads a channel's (public) picture once per picture ID.
func (c *Core) cacheChannelPicture(ctx context.Context, jid, id, url string) string {
	path := filepath.Join(c.Paths.AvatarDir(), safeName(jid)+"-"+safeName(id)+".jpg")
	if _, err := os.Stat(path); err == nil {
		_ = c.Store.SetChatAvatar(ctx, jid, path, id)
		return path
	}
	reqCtx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	req, _ := http.NewRequestWithContext(reqCtx, http.MethodGet, url, nil)
	resp, err := http.DefaultClient.Do(req)
	if err != nil || resp.StatusCode != http.StatusOK {
		if resp != nil {
			resp.Body.Close()
		}
		return ""
	}
	defer resp.Body.Close()
	data, err := io.ReadAll(io.LimitReader(resp.Body, 5<<20))
	if err != nil || os.WriteFile(path, data, 0o600) != nil {
		return ""
	}
	_ = c.Store.SetChatAvatar(ctx, jid, path, id)
	return path
}

func (c *Core) ListChannels(ctx context.Context) ([]*Channel, error) {
	if err := c.loggedIn(); err != nil {
		return nil, err
	}
	list, err := c.cli.GetSubscribedNewsletters(ctx)
	if err != nil {
		return nil, err
	}
	out := []*Channel{}
	for _, m := range list {
		out = append(out, c.channelFrom(ctx, m))
	}
	return out, nil
}

// FetchChannelPosts pulls the newest posts (or ones before a server ID) into the local store.
// markViewed adds your (anonymous) view to the posts' view counts, as opening a channel does on the phone.
func (c *Core) FetchChannelPosts(ctx context.Context, chat string, before int, markViewed bool) (int, error) {
	if err := c.loggedIn(); err != nil {
		return 0, err
	}
	jid, err := parseJID(chat)
	if err != nil || jid.Server != types.NewsletterServer {
		return 0, errors.New("not a channel")
	}
	posts, err := c.cli.GetNewsletterMessages(ctx, jid, &whatsmeow.GetNewsletterMessagesParams{Count: 40, Before: types.MessageServerID(before)})
	if err != nil {
		return 0, err
	}
	n := 0
	var latest *hs.Message
	var seen []types.MessageServerID
	for _, p := range posts {
		if p.Message == nil {
			continue
		}
		evt := &events.Message{Info: types.MessageInfo{
			MessageSource: types.MessageSource{Chat: jid, Sender: jid},
			ID:            p.MessageID,
			ServerID:      p.MessageServerID,
			Timestamp:     p.Timestamp,
		}, Message: p.Message}
		m := c.convert(ctx, evt)
		if m == nil {
			continue
		}
		m.SenderName = ""
		m.Extra = mergeExtra(m.Extra, map[string]any{"serverId": int(p.MessageServerID), "views": p.ViewsCount, "reactionCounts": p.ReactionCounts})
		if _, err := c.Store.UpsertMessage(ctx, m); err != nil {
			continue
		}
		// Counts change over time; refresh them on re-fetch.
		_ = c.Store.SetExtra(ctx, chat, m.ID, m.Extra)
		if latest == nil || m.TS > latest.TS {
			latest = m
		}
		seen = append(seen, p.MessageServerID)
		n++
	}
	if latest != nil {
		_ = c.Store.BumpChat(ctx, chat, latest.ID, latest.TS, false)
	}
	if markViewed && len(seen) > 0 {
		_ = c.cli.NewsletterMarkViewed(ctx, jid, seen)
	}
	return n, nil
}

func mergeExtra(extra string, add map[string]any) string {
	m := map[string]any{}
	if extra != "" {
		_ = json.Unmarshal([]byte(extra), &m)
	}
	for k, v := range add {
		m[k] = v
	}
	return hs.MarshalExtra(m)
}

func (c *Core) ReactToChannelPost(ctx context.Context, chat, id, emoji string) error {
	if err := c.loggedIn(); err != nil {
		return err
	}
	m, err := c.Store.GetMessage(ctx, chat, id)
	if err != nil || m == nil {
		return errors.New("post not found")
	}
	var extra struct {
		ServerID int `json:"serverId"`
	}
	_ = json.Unmarshal([]byte(m.Extra), &extra)
	if extra.ServerID == 0 {
		return errors.New("this post can't be reacted to")
	}
	jid, _ := parseJID(chat)
	if err := c.cli.NewsletterSendReaction(ctx, jid, types.MessageServerID(extra.ServerID), emoji, c.cli.GenerateMessageID()); err != nil {
		return err
	}
	me := c.cli.Store.ID.ToNonAD().String()
	_ = c.Store.SetReaction(ctx, chat, id, me, emoji, time.Now().Unix())
	c.emitMessage(ctx, chat, id)
	return nil
}

var channelLink = regexp.MustCompile(`(?:whatsapp\.com/channel/|^)([A-Za-z0-9]{10,})/?$`)

// FollowChannel follows a channel from its invite link (https://whatsapp.com/channel/…).
func (c *Core) FollowChannel(ctx context.Context, link string) (*Channel, error) {
	if err := c.loggedIn(); err != nil {
		return nil, err
	}
	mt := channelLink.FindStringSubmatch(strings.TrimSpace(link))
	if mt == nil {
		return nil, errors.New("paste a channel link like https://whatsapp.com/channel/…")
	}
	meta, err := c.cli.GetNewsletterInfoWithInvite(ctx, mt[1])
	if err != nil {
		return nil, fmt.Errorf("couldn't find that channel: %w", err)
	}
	if err := c.cli.FollowNewsletter(ctx, meta.ID); err != nil {
		return nil, err
	}
	return c.channelFrom(ctx, meta), nil
}

func (c *Core) UnfollowChannel(ctx context.Context, chat string) error {
	if err := c.loggedIn(); err != nil {
		return err
	}
	jid, err := parseJID(chat)
	if err != nil {
		return err
	}
	return c.cli.UnfollowNewsletter(ctx, jid)
}
