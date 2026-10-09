package wa

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"time"

	hs "github.com/aadit/hermes/daemon/internal/store"
)

// ExportDir is where chats are exported: kv export_dir, else ~/Documents/WhatsApp.
func (c *Core) ExportDir(ctx context.Context) string {
	if d := c.Store.GetKV(ctx, "export_dir"); d != "" {
		return expandHome(d)
	}
	home, _ := os.UserHomeDir()
	return filepath.Join(home, "Documents", "WhatsApp")
}

func expandHome(p string) string {
	if p == "~" || strings.HasPrefix(p, "~/") {
		home, _ := os.UserHomeDir()
		return filepath.Join(home, p[1:])
	}
	return p
}

type ExportOpts struct {
	Since    int64 `json:"since"`    // unix time; 0 = whole chat
	Download bool  `json:"download"` // fetch media that isn't on disk yet (slow for big chats)
	NoMedia  bool  `json:"noMedia"`  // text only
}

type ExportResult struct {
	Path     string `json:"path"`
	Messages int    `json:"messages"`
	Media    int    `json:"media"`
	Missing  int    `json:"missing"` // media that wasn't downloaded, linked as a placeholder
}

// ExportChat writes a chat as Markdown (Obsidian-friendly: frontmatter, a heading per day,
// attachments copied next to it and embedded with relative links). Re-exporting regenerates the file.
func (c *Core) ExportChat(ctx context.Context, jid string, opts ExportOpts) (*ExportResult, error) {
	ch, err := c.GetChat(ctx, jid)
	if err != nil {
		return nil, err
	} else if ch == nil {
		return nil, errors.New("chat not found")
	}
	dir := c.ExportDir(ctx)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return nil, err
	}
	name := ch.Name
	if name == "" {
		name = strings.SplitN(jid, "@", 2)[0]
	}
	mdPath := exportFileFor(dir, fileSafe(name), jid)
	slug := strings.TrimSuffix(filepath.Base(mdPath), ".md")
	attDir := filepath.Join(dir, "attachments", slug)

	tmp := mdPath + ".tmp"
	f, err := os.Create(tmp)
	if err != nil {
		return nil, err
	}
	defer os.Remove(tmp)
	w := bufio.NewWriter(f)
	res := &ExportResult{Path: mdPath}

	var body strings.Builder
	var day string
	err = c.Store.EachMessage(ctx, jid, opts.Since, func(m *hs.Message) error {
		if m.Type == "system" && m.Text == "" {
			return nil
		}
		t := time.Unix(m.TS, 0)
		if d := t.Format("2006-01-02"); d != day {
			day = d
			fmt.Fprintf(&body, "\n## %s\n\n", t.Format("2006-01-02 (Monday)"))
		}
		res.Messages++
		who := m.SenderName
		if m.FromMe {
			who = "You"
		} else if who == "" {
			who = strings.SplitN(m.Sender, "@", 2)[0]
		}
		if !ch.IsGroup && !m.FromMe {
			who = name
		}
		fmt.Fprintf(&body, "**%s · %s:**", t.Format("15:04"), mdEscapeInline(who))
		if m.QuotedText != "" {
			fmt.Fprintf(&body, "\n> %s", strings.ReplaceAll(oneLine(m.QuotedText, 140), "\n", " "))
		}
		body.WriteString(c.exportBody(ctx, m, attDir, slug, opts, res))
		if len(m.Reactions) > 0 {
			var em []string
			for _, r := range m.Reactions {
				em = append(em, r.Emoji)
			}
			fmt.Fprintf(&body, " · %s", strings.Join(em, ""))
		}
		body.WriteString("\n\n")
		return nil
	})
	if err != nil {
		f.Close()
		return nil, err
	}

	kind := "dm"
	if ch.IsGroup {
		kind = "group"
	}
	fmt.Fprintf(w, "---\nwhatsapp: %s\nchat: %s\ntype: %s\nexported: %s\nmessages: %d\ntags: [whatsapp]\n---\n\n# %s\n",
		jid, yamlString(name), kind, time.Now().Format(time.RFC3339), res.Messages, name)
	if ch.Note != "" {
		fmt.Fprintf(w, "\n> [!note] Note\n> %s\n", strings.ReplaceAll(ch.Note, "\n", "\n> "))
	}
	w.WriteString(body.String())
	if err := w.Flush(); err != nil {
		f.Close()
		return nil, err
	}
	if err := f.Close(); err != nil {
		return nil, err
	}
	return res, os.Rename(tmp, mdPath)
}

// exportBody renders a message's content after the "**time · name:**" prefix.
func (c *Core) exportBody(ctx context.Context, m *hs.Message, attDir, slug string, opts ExportOpts, res *ExportResult) string {
	if m.Revoked {
		return " *deleted*"
	}
	text := mdEscapeBlock(m.Text)
	switch m.Type {
	case "image", "video", "gif", "sticker", "voice", "audio", "document":
	default:
		if m.Type == "text" || m.Type == "system" {
			if m.Type == "system" {
				return " *" + strings.TrimSpace(text) + "*"
			}
			return " " + text
		}
		return " " + mdEscapeBlock(hs.Preview(m))
	}

	label := strings.TrimSpace(strings.SplitN(hs.Preview(m), " ", 2)[0]) // the emoji
	if opts.NoMedia || m.ViewOnce {
		return " " + mdEscapeBlock(hs.Preview(m))
	}
	src := m.MediaPath
	if _, err := os.Stat(src); src == "" || err != nil {
		src = ""
		if opts.Download {
			if p, err := c.DownloadMedia(ctx, m.Chat, m.ID); err == nil {
				src = p
			}
		}
	}
	if src == "" {
		res.Missing++
		what := mediaKind(m)
		if m.FileName != "" {
			what = mdEscapeInline(m.FileName) + ","
		}
		out := " " + label + " *(" + what + " not downloaded)*"
		if text != "" && m.Type != "document" {
			out += "\n" + text
		}
		return out
	}
	dst := filepath.Join(attDir, filepath.Base(src))
	if err := copyIfChanged(src, dst); err != nil {
		c.Log.Warnf("export: copy %s: %v", src, err)
		res.Missing++
		return " " + label + " *(" + mediaKind(m) + " missing)*"
	}
	res.Media++
	rel := "attachments/" + slug + "/" + filepath.Base(src)
	link := "<" + rel + ">"
	var out string
	switch m.Type {
	case "document":
		fn := m.FileName
		if fn == "" {
			fn = filepath.Base(src)
		}
		out = " 📄 [" + mdEscapeInline(fn) + "](" + link + ")"
		if text != "" && text != m.FileName {
			out += "\n" + text
		}
		return out
	case "voice":
		out = "\n![](" + link + ")"
		if text != "" {
			out += "\n> 🎤 " + strings.ReplaceAll(text, "\n", "\n> ")
		}
		return out
	}
	out = "\n![](" + link + ")"
	if text != "" {
		out += "\n" + text
	}
	return out
}

func mediaKind(m *hs.Message) string {
	switch m.Type {
	case "image":
		return "photo"
	case "voice":
		return "voice note"
	case "gif":
		return "GIF"
	}
	return m.Type
}

// exportFileFor picks <dir>/<name>.md, unless that file belongs to another chat (same display name).
func exportFileFor(dir, name, jid string) string {
	p := filepath.Join(dir, name+".md")
	owner := frontmatterJID(p)
	if owner == "" || owner == jid {
		return p
	}
	return filepath.Join(dir, name+" ("+strings.SplitN(jid, "@", 2)[0]+").md")
}

func frontmatterJID(path string) string {
	f, err := os.Open(path)
	if err != nil {
		return ""
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	for i := 0; i < 8 && sc.Scan(); i++ {
		if v, ok := strings.CutPrefix(sc.Text(), "whatsapp: "); ok {
			return strings.TrimSpace(v)
		}
	}
	return "?" // exists but isn't ours: don't overwrite
}

func copyIfChanged(src, dst string) error {
	si, err := os.Stat(src)
	if err != nil {
		return err
	}
	if di, err := os.Stat(dst); err == nil && di.Size() == si.Size() {
		return nil
	}
	if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
		return err
	}
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	out, err := os.Create(dst + ".tmp")
	if err != nil {
		return err
	}
	if _, err := io.Copy(out, in); err != nil {
		out.Close()
		os.Remove(dst + ".tmp")
		return err
	}
	if err := out.Close(); err != nil {
		return err
	}
	return os.Rename(dst+".tmp", dst)
}

// fileSafe makes a chat name usable as a file name on any filesystem and in Obsidian links.
func fileSafe(s string) string {
	s = strings.Map(func(r rune) rune {
		switch r {
		case '/', '\\', ':', '*', '?', '"', '<', '>', '|', '#', '^', '[', ']', 0:
			return '_'
		}
		if r < 32 {
			return -1
		}
		return r
	}, s)
	s = strings.Trim(s, ". ")
	if s == "" {
		s = "chat"
	}
	if len(s) > 120 {
		s = s[:120]
	}
	return s
}

func yamlString(s string) string {
	b, _ := json.Marshal(s) // a JSON string is a valid YAML scalar
	return string(b)
}

func mdEscapeInline(s string) string {
	return strings.NewReplacer("*", `\*`, "_", `\_`, "[", `\[`, "]", `\]`, "\n", " ").Replace(s)
}

// mdEscapeBlock keeps message text as written, but stops lines from turning into headings,
// quotes, rules or lists, and stops [[...]] from becoming Obsidian links.
func mdEscapeBlock(s string) string {
	lines := strings.Split(strings.TrimRight(s, "\n"), "\n")
	for i, l := range lines {
		t := strings.TrimLeft(l, " ")
		if t != "" && strings.ContainsRune("#>-+=|", rune(t[0])) {
			lines[i] = `\` + t
		}
		lines[i] = strings.ReplaceAll(lines[i], "[[", `\[\[`)
	}
	return strings.Join(lines, "\n")
}

func oneLine(s string, n int) string {
	s = strings.ReplaceAll(s, "\n", " ")
	if r := []rune(s); len(r) > n {
		return string(r[:n]) + "…"
	}
	return s
}
