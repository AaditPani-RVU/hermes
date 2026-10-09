package wa

import (
	"context"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	hs "github.com/aadit/hermes/daemon/internal/store"
)

type ChatStats struct {
	JID        string `json:"jid"`
	Name       string `json:"name"`
	Messages   int    `json:"messages"`
	MediaFiles int    `json:"mediaFiles"`
	MediaBytes int64  `json:"mediaBytes"`
	LastTS     int64  `json:"lastTs"`
}

type StorageStats struct {
	DBBytes    int64        `json:"dbBytes"`
	MediaBytes int64        `json:"mediaBytes"`
	MediaFiles int          `json:"mediaFiles"`
	CacheBytes int64        `json:"cacheBytes"`
	Messages   int          `json:"messages"`
	Chats      []*ChatStats `json:"chats"` // biggest media first
}

func (c *Core) Stats(ctx context.Context) (*StorageStats, error) {
	st := &StorageStats{Chats: []*ChatStats{}}
	for _, suffix := range []string{"", "-wal", "-shm"} {
		if fi, err := os.Stat(filepath.Join(c.Paths.Data, "hermes.db"+suffix)); err == nil {
			st.DBBytes += fi.Size()
		}
	}
	st.CacheBytes = dirSize(c.Paths.Cache)

	counts, err := c.Store.MessageCounts(ctx)
	if err != nil {
		return nil, err
	}
	byChat := map[string]*ChatStats{}
	get := func(jid string) *ChatStats {
		cs := byChat[jid]
		if cs == nil {
			cs = &ChatStats{JID: jid}
			byChat[jid] = cs
		}
		return cs
	}
	for jid, n := range counts {
		get(jid).Messages = n
		st.Messages += n
	}
	err = c.Store.EachMedia(ctx, func(f hs.MediaFile) error {
		fi, err := os.Stat(f.Path)
		if err != nil {
			return nil
		}
		cs := get(f.Chat)
		cs.MediaFiles++
		cs.MediaBytes += fi.Size()
		st.MediaFiles++
		st.MediaBytes += fi.Size()
		return nil
	})
	if err != nil {
		return nil, err
	}
	for _, cs := range byChat {
		if ch, _ := c.GetChat(ctx, cs.JID); ch != nil {
			cs.Name, cs.LastTS = ch.Name, ch.LastTS
		}
		if cs.Name == "" {
			cs.Name = strings.SplitN(cs.JID, "@", 2)[0]
		}
		st.Chats = append(st.Chats, cs)
	}
	sort.Slice(st.Chats, func(i, j int) bool {
		a, b := st.Chats[i], st.Chats[j]
		if a.MediaBytes != b.MediaBytes {
			return a.MediaBytes > b.MediaBytes
		}
		return a.Messages > b.Messages
	})
	return st, nil
}

func dirSize(root string) int64 {
	var n int64
	_ = filepath.WalkDir(root, func(_ string, d fs.DirEntry, err error) error {
		if err == nil && !d.IsDir() {
			if fi, err := d.Info(); err == nil {
				n += fi.Size()
			}
		}
		return nil
	})
	return n
}

type CleanOpts struct {
	Chat      string `json:"chat"`      // "" = all chats
	OlderThan int    `json:"olderThan"` // days; 0 = any age
	MinBytes  int64  `json:"minBytes"`  // only files at least this big
	DryRun    bool   `json:"dryRun"`
}

type CleanResult struct {
	Files int   `json:"files"`
	Bytes int64 `json:"bytes"`
}

// CleanMedia deletes downloaded attachments to free space. Messages stay; their media can be
// downloaded again later (or re-requested from the phone once WhatsApp's copy expires).
// Starred messages and anything outside Hermes' media folder (exports, auto-filed copies) are kept.
func (c *Core) CleanMedia(ctx context.Context, o CleanOpts) (*CleanResult, error) {
	res := &CleanResult{}
	cutoff := int64(0)
	if o.OlderThan > 0 {
		cutoff = time.Now().AddDate(0, 0, -o.OlderThan).Unix()
	}
	root := c.Paths.MediaDir() + string(filepath.Separator)
	err := c.Store.EachMedia(ctx, func(f hs.MediaFile) error {
		if f.Starred || (o.Chat != "" && f.Chat != o.Chat) || (cutoff > 0 && f.TS >= cutoff) {
			return nil
		}
		if !strings.HasPrefix(filepath.Clean(f.Path), root) {
			return nil
		}
		fi, err := os.Stat(f.Path)
		if err != nil || fi.Size() < o.MinBytes {
			return nil
		}
		res.Files++
		res.Bytes += fi.Size()
		if o.DryRun {
			return nil
		}
		if err := os.Remove(f.Path); err != nil {
			return err
		}
		return c.Store.SetMediaPath(ctx, f.Chat, f.ID, "")
	})
	if err == nil && !o.DryRun && res.Files > 0 {
		c.Emit("media.cleaned", res)
	}
	return res, err
}
