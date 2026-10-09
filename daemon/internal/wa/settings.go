package wa

import (
	"context"
	"errors"
	"strings"

	"go.mau.fi/whatsmeow/appstate"
	"go.mau.fi/whatsmeow/types"
)

// ---- Account settings: profile name, about, privacy ----

type Settings struct {
	Name    string            `json:"name"`
	About   string            `json:"about"`
	Phone   string            `json:"phone"`
	Privacy map[string]string `json:"privacy"`
}

func (c *Core) GetSettings(ctx context.Context) (*Settings, error) {
	if err := c.loggedIn(); err != nil {
		return nil, err
	}
	me := c.cli.Store.ID.ToNonAD()
	s := &Settings{Name: c.cli.Store.PushName, Phone: "+" + me.User, Privacy: map[string]string{}}
	if info, err := c.cli.GetUserInfo(ctx, []types.JID{me}); err == nil {
		s.About = info[me].Status
	}
	p := c.cli.GetPrivacySettings(ctx)
	for k, v := range map[string]types.PrivacySetting{
		"groupadd": p.GroupAdd, "last": p.LastSeen, "status": p.Status, "profile": p.Profile,
		"readreceipts": p.ReadReceipts, "online": p.Online, "calladd": p.CallAdd, "messages": p.Messages,
	} {
		s.Privacy[k] = string(v)
	}
	return s, nil
}

// Allowed values per setting, mirroring what the phone offers.
var privacyValues = map[string][]string{
	"last":         {"all", "contacts", "contact_blacklist", "none"},
	"online":       {"all", "match_last_seen"},
	"profile":      {"all", "contacts", "contact_blacklist", "none"},
	"status":       {"all", "contacts", "contact_blacklist", "none"},
	"groupadd":     {"all", "contacts", "contact_blacklist", "none"},
	"readreceipts": {"all", "none"},
	"calladd":      {"all", "known"},
	"messages":     {"all", "contacts"},
}

func (c *Core) SetPrivacy(ctx context.Context, name, value string) error {
	if err := c.loggedIn(); err != nil {
		return err
	}
	ok := false
	for _, v := range privacyValues[name] {
		ok = ok || v == value
	}
	if !ok {
		return errors.New("that privacy option isn't available")
	}
	_, err := c.cli.SetPrivacySetting(ctx, types.PrivacySettingType(name), types.PrivacySetting(value))
	return err
}

func (c *Core) SetAbout(ctx context.Context, text string) error {
	if err := c.loggedIn(); err != nil {
		return err
	}
	text = strings.TrimSpace(text)
	if len([]rune(text)) > 139 {
		return errors.New("about can be at most 139 characters")
	}
	return c.cli.SetStatusMessage(ctx, types.SetStatusInput{Text: &text})
}

// SetPushName changes the name other people see (synced to your phone via app state).
func (c *Core) SetPushName(ctx context.Context, name string) error {
	if err := c.loggedIn(); err != nil {
		return err
	}
	name = strings.TrimSpace(name)
	if name == "" || len([]rune(name)) > 25 {
		return errors.New("a name is 1 to 25 characters")
	}
	if err := c.cli.SendAppState(ctx, appstate.BuildSettingPushName(name)); err != nil {
		return err
	}
	c.cli.Store.PushName = name
	_ = c.cli.Store.Save(ctx)
	c.Emit("state", c.Status())
	return nil
}
