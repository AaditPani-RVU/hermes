package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"strconv"
	"strings"
	"time"

	"golang.org/x/term"

	"github.com/aadit/hermes/daemon/internal/backup"
)

const dataUsage = `
Your data:
  hermes export <chat>|--all [--since 30d] [--download] [--no-media]
                                      export to Markdown (Obsidian-friendly) in the export folder
  hermes export --dir <path>          set the export folder (e.g. your Obsidian vault)
  hermes backup [--media]             encrypted backup (asks for a passphrase)
  hermes backup --dir <path>          set the backup folder
  hermes backup list                  show backups
  hermes backup extract <file> <dir>  decrypt a backup into an empty folder (no daemon needed)
  hermes storage [--json]             disk usage per chat
  hermes clean [--chat C] [--older 90d] [--min 5M] [--yes]
                                      delete downloaded media (dry run unless --yes)
  hermes autofile                     list auto-filing rules
  hermes autofile add <chat|*> <dir> [--kind document] [--ext pdf,docx] [--match text]
  hermes autofile rm <n>              remove rule n
`

// splitFlags separates --name [value] flags from positional args. Flags in bools take no value.
func splitFlags(args []string, bools ...string) (map[string]string, []string) {
	flags := map[string]string{}
	var pos []string
	for i := 0; i < len(args); i++ {
		a := args[i]
		name, ok := strings.CutPrefix(a, "--")
		if !ok {
			pos = append(pos, a)
			continue
		}
		if k, v, ok := strings.Cut(name, "="); ok {
			flags[k] = v
			continue
		}
		isBool := false
		for _, b := range bools {
			isBool = isBool || b == name
		}
		if isBool || i+1 >= len(args) {
			flags[name] = "1"
			continue
		}
		flags[name] = args[i+1]
		i++
	}
	return flags, pos
}

// parseDays accepts "90", "90d", "12w" or "6m" (months of 30 days).
func parseDays(s string) (int, error) {
	if s == "" {
		return 0, nil
	}
	mult := 1
	switch s[len(s)-1] {
	case 'd':
		s = s[:len(s)-1]
	case 'w':
		mult, s = 7, s[:len(s)-1]
	case 'm':
		mult, s = 30, s[:len(s)-1]
	}
	n, err := strconv.Atoi(s)
	if err != nil {
		return 0, fmt.Errorf("bad age %q (try 90d)", s)
	}
	return n * mult, nil
}

func parseSize(s string) (int64, error) {
	if s == "" {
		return 0, nil
	}
	mult := int64(1)
	switch strings.ToUpper(s[len(s)-1:]) {
	case "K":
		mult = 1 << 10
	case "M":
		mult = 1 << 20
	case "G":
		mult = 1 << 30
	}
	if mult > 1 {
		s = s[:len(s)-1]
	}
	n, err := strconv.ParseFloat(s, 64)
	if err != nil {
		return 0, fmt.Errorf("bad size %q (try 5M)", s)
	}
	return int64(n * float64(mult)), nil
}

func humanSize(n int64) string {
	switch {
	case n >= 1<<30:
		return fmt.Sprintf("%.1f GB", float64(n)/(1<<30))
	case n >= 1<<20:
		return fmt.Sprintf("%.1f MB", float64(n)/(1<<20))
	case n >= 1<<10:
		return fmt.Sprintf("%.0f KB", float64(n)/(1<<10))
	}
	return fmt.Sprintf("%d B", n)
}

func readPassphrase(prompt string, confirm bool) (string, error) {
	if p := os.Getenv("HERMES_BACKUP_PASSPHRASE"); p != "" {
		return p, nil
	}
	if !term.IsTerminal(int(os.Stdin.Fd())) {
		return "", errors.New("no terminal to ask for a passphrase; set HERMES_BACKUP_PASSPHRASE")
	}
	fmt.Fprint(os.Stderr, prompt)
	b, err := term.ReadPassword(int(os.Stdin.Fd()))
	fmt.Fprintln(os.Stderr)
	if err != nil {
		return "", err
	}
	if confirm {
		fmt.Fprint(os.Stderr, "Again: ")
		b2, err := term.ReadPassword(int(os.Stdin.Fd()))
		fmt.Fprintln(os.Stderr)
		if err != nil {
			return "", err
		}
		if string(b) != string(b2) {
			return "", errors.New("passphrases don't match")
		}
	}
	return string(b), nil
}

// localCommand runs commands that don't need hermesd. handled=false means "dial the daemon".
func localCommand(args []string) (handled bool, err error) {
	if len(args) >= 2 && args[0] == "backup" && args[1] == "extract" {
		if len(args) != 4 {
			return true, errors.New("usage: hermes backup extract <file> <dir>")
		}
		pass, err := readPassphrase("Passphrase: ", false)
		if err != nil {
			return true, err
		}
		names, err := backup.Extract(args[2], pass, args[3])
		if err != nil {
			return true, err
		}
		fmt.Printf("Extracted %d files to %s\n", len(names), args[3])
		fmt.Println("To restore: systemctl --user stop hermesd, copy hermes.db (and media/) into ~/.local/share/hermes, start it again.")
		return true, nil
	}
	return false, nil
}

type fileRule struct {
	Chat     string `json:"chat"`
	ChatName string `json:"chatName"`
	Kind     string `json:"kind"`
	Ext      string `json:"ext"`
	Match    string `json:"match"`
	Dir      string `json:"dir"`
}

type dataInfo struct {
	ExportDir string `json:"exportDir"`
	Rules     []fileRule `json:"rules"`
	Backup struct {
		Dir  string `json:"dir"`
		Last int64  `json:"last"`
		List []struct {
			Path string `json:"path"`
			Size int64  `json:"size"`
		} `json:"list"`
	} `json:"backup"`
}

// dataCommand handles the "your data" commands; handled=false means it isn't one of them.
func dataCommand(c *client, cmd string, rest []string) (handled bool, err error) {
	switch cmd {
	case "export", "backup", "storage", "clean", "autofile":
	default:
		return false, nil
	}
	var info dataInfo
	if err := c.call("data.get", nil, &info); err != nil {
		return true, err
	}
	switch cmd {
	case "export":
		f, pos := splitFlags(rest, "all", "download", "no-media")
		if d, ok := f["dir"]; ok {
			if err := c.call("data.setDirs", map[string]string{"exportDir": d}, nil); err != nil {
				return true, err
			}
			fmt.Println("Exports will go to", d)
			return true, nil
		}
		days, err := parseDays(f["since"])
		if err != nil {
			return true, err
		}
		opts := map[string]any{"download": f["download"] != "", "noMedia": f["no-media"] != ""}
		if days > 0 {
			opts["since"] = time.Now().AddDate(0, 0, -days).Unix()
		}
		var targets [][2]string
		if f["all"] != "" {
			var chats []chat
			for _, archived := range []bool{false, true} {
				var part []chat
				if err := c.call("chats.list", map[string]bool{"archived": archived}, &part); err != nil {
					return true, err
				}
				chats = append(chats, part...)
			}
			for _, ch := range chats {
				if ch.LastTS > 0 && !strings.HasSuffix(ch.JID, "@newsletter") && ch.JID != "status@broadcast" {
					targets = append(targets, [2]string{ch.JID, ch.Name})
				}
			}
		} else {
			if len(pos) != 1 {
				return true, errors.New("usage: hermes export <chat> | --all")
			}
			jid, name, err := c.resolveChat(pos[0])
			if err != nil {
				return true, err
			}
			targets = append(targets, [2]string{jid, name})
		}
		for _, t := range targets {
			opts["chat"] = t[0]
			var res struct {
				Path     string `json:"path"`
				Messages int    `json:"messages"`
				Media    int    `json:"media"`
				Missing  int    `json:"missing"`
			}
			if err := c.call("export.chat", opts, &res); err != nil {
				fmt.Fprintf(os.Stderr, "%s: %v\n", t[1], err)
				continue
			}
			miss := ""
			if res.Missing > 0 {
				miss = fmt.Sprintf(", %d not downloaded", res.Missing)
			}
			fmt.Printf("%s: %d messages, %d attachments%s → %s\n", t[1], res.Messages, res.Media, miss, res.Path)
		}

	case "backup":
		f, pos := splitFlags(rest, "media")
		if d, ok := f["dir"]; ok {
			if err := c.call("data.setDirs", map[string]string{"backupDir": d}, nil); err != nil {
				return true, err
			}
			fmt.Println("Backups will go to", d)
			return true, nil
		}
		if len(pos) > 0 && pos[0] == "list" {
			fmt.Println("Folder:", info.Backup.Dir)
			for _, b := range info.Backup.List {
				fmt.Printf("  %-50s %s\n", b.Path, humanSize(b.Size))
			}
			if len(info.Backup.List) == 0 {
				fmt.Println("  no backups yet")
			}
			return true, nil
		}
		pass, err := readPassphrase("Backup passphrase (you'll need it to restore): ", true)
		if err != nil {
			return true, err
		}
		fmt.Fprintln(os.Stderr, "Backing up…")
		var res struct {
			Path  string `json:"path"`
			Size  int64  `json:"size"`
			Files int    `json:"files"`
		}
		if err := c.call("backup.create", map[string]any{"passphrase": pass, "media": f["media"] != ""}, &res); err != nil {
			return true, err
		}
		fmt.Printf("Saved %s (%d files, %s)\n", res.Path, res.Files, humanSize(res.Size))

	case "storage":
		f, _ := splitFlags(rest, "json")
		var st struct {
			DBBytes    int64 `json:"dbBytes"`
			MediaBytes int64 `json:"mediaBytes"`
			MediaFiles int   `json:"mediaFiles"`
			CacheBytes int64 `json:"cacheBytes"`
			Messages   int   `json:"messages"`
			Chats      []struct {
				Name       string `json:"name"`
				Messages   int    `json:"messages"`
				MediaFiles int    `json:"mediaFiles"`
				MediaBytes int64  `json:"mediaBytes"`
			} `json:"chats"`
		}
		var raw json.RawMessage
		if err := c.call("storage.stats", nil, &raw); err != nil {
			return true, err
		}
		if f["json"] != "" {
			fmt.Println(string(raw))
			return true, nil
		}
		_ = json.Unmarshal(raw, &st)
		fmt.Printf("Database %s · media %s in %d files · cache %s · %d messages\n\n",
			humanSize(st.DBBytes), humanSize(st.MediaBytes), st.MediaFiles, humanSize(st.CacheBytes), st.Messages)
		for i, ch := range st.Chats {
			if i == 20 {
				fmt.Printf("… and %d more chats\n", len(st.Chats)-20)
				break
			}
			fmt.Printf("%-28.28s %9s %5d files %7d msgs\n", ch.Name, humanSize(ch.MediaBytes), ch.MediaFiles, ch.Messages)
		}

	case "clean":
		f, _ := splitFlags(rest, "yes")
		days, err := parseDays(f["older"])
		if err != nil {
			return true, err
		}
		min, err := parseSize(f["min"])
		if err != nil {
			return true, err
		}
		params := map[string]any{"olderThan": days, "minBytes": min, "dryRun": f["yes"] == ""}
		if q := f["chat"]; q != "" {
			jid, _, err := c.resolveChat(q)
			if err != nil {
				return true, err
			}
			params["chat"] = jid
		}
		var res struct {
			Files int   `json:"files"`
			Bytes int64 `json:"bytes"`
		}
		if err := c.call("storage.clean", params, &res); err != nil {
			return true, err
		}
		if f["yes"] == "" {
			fmt.Printf("Would delete %d files (%s). Starred media is kept; messages stay and can re-download. Add --yes to do it.\n", res.Files, humanSize(res.Bytes))
		} else {
			fmt.Printf("Deleted %d files, freed %s\n", res.Files, humanSize(res.Bytes))
		}

	case "autofile":
		rules := info.Rules
		show := func() {
			if len(rules) == 0 {
				fmt.Println("No auto-filing rules. Add one: hermes autofile add College ~/Documents/College --ext pdf")
			}
			for i, r := range rules {
				from := r.ChatName
				if r.Chat == "" {
					from = "any chat"
				}
				what := r.Kind
				if what == "" {
					what = "any media"
				}
				if r.Ext != "" {
					what += " ." + strings.ReplaceAll(r.Ext, ",", "/.")
				}
				if r.Match != "" {
					what += fmt.Sprintf(" matching %q", r.Match)
				}
				fmt.Printf("%d. %s from %s → %s\n", i+1, what, from, r.Dir)
			}
		}
		if len(rest) == 0 {
			show()
			return true, nil
		}
		save := func() error {
			return c.call("autofile.set", map[string]any{"rules": rules}, nil)
		}
		switch rest[0] {
		case "add":
			f, pos := splitFlags(rest[1:])
			if len(pos) != 2 {
				return true, errors.New("usage: hermes autofile add <chat|*> <dir> [--kind document] [--ext pdf] [--match text]")
			}
			nr := fileRule{Kind: f["kind"], Ext: f["ext"], Match: f["match"], Dir: pos[1]}
			if pos[0] != "*" {
				jid, name, err := c.resolveChat(pos[0])
				if err != nil {
					return true, err
				}
				nr.Chat, nr.ChatName = jid, name
			}
			rules = append(rules, nr)
			if err := save(); err != nil {
				return true, err
			}
			show()
		case "rm":
			n, err := strconv.Atoi(strings.Join(rest[1:], ""))
			if err != nil || n < 1 || n > len(rules) {
				return true, errors.New("usage: hermes autofile rm <n> (see hermes autofile)")
			}
			rules = append(rules[:n-1], rules[n:]...)
			if err := save(); err != nil {
				return true, err
			}
			show()
		default:
			return true, errors.New("usage: hermes autofile [add|rm]")
		}
	}
	return true, nil
}
