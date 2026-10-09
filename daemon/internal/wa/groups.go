package wa

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"time"

	"go.mau.fi/whatsmeow"
	"go.mau.fi/whatsmeow/types"
	"go.mau.fi/whatsmeow/types/events"
)

// ---- Group admin, disappearing messages, blocking ----

func (c *Core) groupJID(chat string) (types.JID, error) {
	if err := c.loggedIn(); err != nil {
		return types.JID{}, err
	}
	jid, err := parseJID(chat)
	if err != nil {
		return jid, err
	}
	if jid.Server != types.GroupServer {
		return jid, errors.New("not a group")
	}
	return jid, nil
}

// UpdateMembers adds, removes, promotes or demotes members (you must be an admin).
func (c *Core) UpdateMembers(ctx context.Context, chat string, members []string, action string) (map[string]string, error) {
	jid, err := c.groupJID(chat)
	if err != nil {
		return nil, err
	}
	var change whatsmeow.ParticipantChange
	switch action {
	case "add":
		change = whatsmeow.ParticipantChangeAdd
	case "remove":
		change = whatsmeow.ParticipantChangeRemove
	case "promote":
		change = whatsmeow.ParticipantChangePromote
	case "demote":
		change = whatsmeow.ParticipantChangeDemote
	default:
		return nil, fmt.Errorf("unknown action %q", action)
	}
	var jids []types.JID
	for _, m := range members {
		if !strings.Contains(m, "@") {
			m = strings.TrimPrefix(strings.Map(func(r rune) rune {
				if r >= '0' && r <= '9' {
					return r
				}
				return -1
			}, m), "0") + "@s.whatsapp.net"
		}
		j, err := parseJID(m)
		if err != nil {
			return nil, err
		}
		jids = append(jids, j)
	}
	if len(jids) == 0 {
		return nil, errors.New("no members given")
	}
	res, err := c.cli.UpdateGroupParticipants(ctx, jid, jids, change)
	if err != nil {
		return nil, err
	}
	// Per-member results: WhatsApp refuses some adds (privacy settings) with an error code.
	out := map[string]string{}
	for _, p := range res {
		switch {
		case p.Error == 0:
			out[p.JID.String()] = "ok"
		case p.Error == 403:
			out[p.JID.String()] = "their privacy settings don't allow being added; send them the invite link"
		case p.Error == 409:
			out[p.JID.String()] = "already in the group"
		default:
			out[p.JID.String()] = fmt.Sprintf("refused (%d)", p.Error)
		}
	}
	c.emitChat(ctx, chat)
	return out, nil
}

func (c *Core) SetGroupName(ctx context.Context, chat, name string) error {
	jid, err := c.groupJID(chat)
	if err != nil {
		return err
	}
	name = strings.TrimSpace(name)
	if name == "" {
		return errors.New("a group needs a name")
	}
	if err := c.cli.SetGroupName(ctx, jid, name); err != nil {
		return err
	}
	_ = c.Store.SetChatName(ctx, chat, name)
	c.emitChat(ctx, chat)
	return nil
}

func (c *Core) SetGroupTopic(ctx context.Context, chat, topic string) error {
	jid, err := c.groupJID(chat)
	if err != nil {
		return err
	}
	gi, err := c.cli.GetGroupInfo(ctx, jid)
	if err != nil {
		return err
	}
	return c.cli.SetGroupTopic(ctx, jid, gi.TopicID, "", strings.TrimSpace(topic))
}

// SetGroupFlags changes "only admins can send" (announce) and "only admins can edit info" (locked).
func (c *Core) SetGroupFlags(ctx context.Context, chat string, announce, locked *bool) error {
	jid, err := c.groupJID(chat)
	if err != nil {
		return err
	}
	if announce != nil {
		if err := c.cli.SetGroupAnnounce(ctx, jid, *announce); err != nil {
			return err
		}
	}
	if locked != nil {
		if err := c.cli.SetGroupLocked(ctx, jid, *locked); err != nil {
			return err
		}
	}
	return nil
}

func (c *Core) InviteLink(ctx context.Context, chat string, reset bool) (string, error) {
	jid, err := c.groupJID(chat)
	if err != nil {
		return "", err
	}
	return c.cli.GetGroupInviteLink(ctx, jid, reset)
}

func (c *Core) LeaveGroup(ctx context.Context, chat string) error {
	jid, err := c.groupJID(chat)
	if err != nil {
		return err
	}
	if err := c.cli.LeaveGroup(ctx, jid); err != nil {
		return err
	}
	c.emitChat(ctx, chat)
	return nil
}

// SetDisappearing turns disappearing messages on (24 h, 7 d or 90 d) or off for a chat.
func (c *Core) SetDisappearing(ctx context.Context, chat string, seconds int64) error {
	if err := c.loggedIn(); err != nil {
		return err
	}
	switch seconds {
	case 0, 86400, 7 * 86400, 90 * 86400:
	default:
		return errors.New("choose off, 24 hours, 7 days or 90 days")
	}
	jid, err := parseJID(chat)
	if err != nil {
		return err
	}
	if err := c.cli.SetDisappearingTimer(ctx, jid, time.Duration(seconds)*time.Second, time.Now()); err != nil {
		return err
	}
	_ = c.Store.SetChatField(ctx, chat, "ephemeral", seconds)
	c.emitChat(ctx, chat)
	return nil
}

// Blocklist returns the JIDs you've blocked (phone-number form where known).
func (c *Core) Blocklist(ctx context.Context) ([]map[string]string, error) {
	if err := c.loggedIn(); err != nil {
		return nil, err
	}
	bl, err := c.cli.GetBlocklist(ctx, "")
	if err != nil {
		return nil, err
	}
	out := []map[string]string{}
	for _, it := range bl.Items {
		if !it.Active {
			continue
		}
		j := it.PN
		if j.IsEmpty() {
			j = it.LID
		}
		cj := c.canon(ctx, j)
		out = append(out, map[string]string{"jid": cj.String(), "name": c.DisplayName(ctx, cj)})
	}
	return out, nil
}

func (c *Core) SetBlocked(ctx context.Context, chat string, block bool) error {
	if err := c.loggedIn(); err != nil {
		return err
	}
	jid, err := parseJID(chat)
	if err != nil {
		return err
	}
	if jid.Server != types.DefaultUserServer && jid.Server != types.HiddenUserServer {
		return errors.New("only people can be blocked")
	}
	action := events.BlocklistChangeActionUnblock
	if block {
		action = events.BlocklistChangeActionBlock
	}
	_, err = c.cli.UpdateBlocklist(ctx, jid, action, "")
	return err
}
