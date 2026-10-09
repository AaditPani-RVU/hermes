package wa

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	hs "github.com/aadit/hermes/daemon/internal/store"
)

// FileRule copies matching incoming attachments into a folder, e.g. PDFs from "College" → ~/Documents/College.
// Hermes keeps its own copy, so the message still plays/opens in the app.
type FileRule struct {
	Chat     string `json:"chat"`     // JID; "" = any chat
	ChatName string `json:"chatName"` // for display only
	Kind     string `json:"kind"`     // document image video audio (incl. voice); "" = any
	Ext      string `json:"ext"`      // comma-separated extensions, e.g. "pdf,docx"; "" = any
	Match    string `json:"match"`    // case-insensitive substring of the file name or caption; "" = any
	Dir      string `json:"dir"`
}

// autoFileMax caps downloads triggered by a rule (normal auto-download stops at 16 MB).
const autoFileMax = 200 << 20

func (c *Core) FileRules(ctx context.Context) []FileRule {
	var rules []FileRule
	_ = json.Unmarshal([]byte(c.Store.GetKV(ctx, "autofile_rules")), &rules)
	if rules == nil {
		rules = []FileRule{}
	}
	return rules
}

func (c *Core) SetFileRules(ctx context.Context, rules []FileRule) error {
	for i := range rules {
		r := &rules[i]
		r.Dir = strings.TrimSpace(r.Dir)
		if r.Dir == "" {
			return fmt.Errorf("rule %d has no folder", i+1)
		}
		if !filepath.IsAbs(expandHome(r.Dir)) {
			return fmt.Errorf("folder %q must be an absolute path or start with ~/", r.Dir)
		}
		r.Ext = strings.ToLower(strings.ReplaceAll(strings.ReplaceAll(r.Ext, " ", ""), ".", ""))
	}
	b, _ := json.Marshal(rules)
	return c.Store.SetKV(ctx, "autofile_rules", string(b))
}

func (r FileRule) matches(m *hs.Message) bool {
	if r.Chat != "" && r.Chat != m.Chat {
		return false
	}
	kind := m.Type
	switch kind {
	case "voice":
		kind = "audio"
	case "gif":
		kind = "video"
	}
	if r.Kind != "" && r.Kind != kind {
		return false
	}
	name := m.FileName
	if name == "" {
		name = "x" + extFor(m.MediaMime)
	}
	if r.Ext != "" {
		ext := strings.TrimPrefix(strings.ToLower(filepath.Ext(name)), ".")
		ok := false
		for _, e := range strings.Split(r.Ext, ",") {
			if e == ext || (e == "jpeg" && ext == "jpg") || (e == "jpg" && ext == "jpeg") {
				ok = true
			}
		}
		if !ok {
			return false
		}
	}
	if r.Match != "" {
		q := strings.ToLower(r.Match)
		if !strings.Contains(strings.ToLower(m.FileName), q) && !strings.Contains(strings.ToLower(m.Text), q) {
			return false
		}
	}
	return true
}

// autoFile runs after an incoming media message is stored; the first matching rule wins.
func (c *Core) autoFile(ctx context.Context, m *hs.Message) {
	switch m.Type {
	case "image", "video", "gif", "audio", "voice", "document":
	default:
		return
	}
	if m.ViewOnce || m.MediaSize > autoFileMax {
		return
	}
	for _, r := range c.FileRules(ctx) {
		if !r.matches(m) {
			continue
		}
		go func() {
			bg := context.Background()
			dst, err := c.FileMessage(bg, m.Chat, m.ID, expandHome(r.Dir))
			if err != nil {
				c.Log.Warnf("auto-file %s: %v", m.ID, err)
				return
			}
			c.Log.Infof("Filed %s → %s", m.ID, dst)
		}()
		return
	}
}

// FileMessage copies one message's attachment into dir (downloading it if needed) and remembers where.
func (c *Core) FileMessage(ctx context.Context, chat, id, dir string) (string, error) {
	dir = expandHome(dir)
	if !filepath.IsAbs(dir) {
		return "", errors.New("folder must be an absolute path")
	}
	src, err := c.DownloadMedia(ctx, chat, id)
	if err != nil {
		return "", err
	}
	m, err := c.Store.GetMessage(ctx, chat, id)
	if err != nil || m == nil {
		return "", errors.New("message not found")
	}
	name := m.FileName
	if name == "" {
		// Downloaded name is "<id><ext>"; prefix the date so photos sort sensibly.
		name = "WhatsApp " + unixDate(m.TS) + " " + filepath.Base(src)
	}
	name = fileSafe(filepath.Base(name))
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return "", err
	}
	dst := freeName(filepath.Join(dir, name), src)
	if err := copyIfChanged(src, dst); err != nil {
		return "", err
	}
	if !strings.HasPrefix(m.Extra, "[") { // contact cards keep an array in extra
		_ = c.Store.SetExtra(ctx, chat, id, mergeExtra(m.Extra, map[string]any{"filed": dst}))
		c.emitMessage(ctx, chat, id)
	}
	return dst, nil
}

// freeName returns path, or "name (2).ext" etc. if a different file already has that name.
func freeName(path, src string) string {
	si, _ := os.Stat(src)
	ext := filepath.Ext(path)
	base := strings.TrimSuffix(path, ext)
	for i := 1; ; i++ {
		p := path
		if i > 1 {
			p = fmt.Sprintf("%s (%d)%s", base, i, ext)
		}
		di, err := os.Stat(p)
		if err != nil || (si != nil && di.Size() == si.Size()) {
			return p
		}
	}
}

func unixDate(ts int64) string { return time.Unix(ts, 0).Format("2006-01-02 15.04.05") }
