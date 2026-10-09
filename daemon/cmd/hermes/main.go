// hermes is the command-line client for hermesd.
package main

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/mdp/qrterminal/v3"
)

const usage = `hermes — WhatsApp from the terminal (talks to hermesd)

Usage:
  hermes status                       connection state
  hermes pair [--phone +911234567890] link this computer (QR in terminal, or pairing code)
  hermes inbox [--json]               triage inbox: needs reply, mentions, FYI, waiting
  hermes done <chat>                  clear a chat from the inbox
  hermes chats [--archived]           list chats
  hermes note <chat> [text...]        show or set a chat's private note ("-" clears it)
  hermes snippets                     list snippets (type ;name in the app to expand)
  hermes snippet <name> [text...]     add/replace a snippet, or delete it with no text
  hermes unread [--json]              unread counts (for status bars)
  hermes read <chat>                  show recent messages in a chat
  hermes send <chat> <text...>        send a message (chat = name, number or JID)
  hermes file <chat> <path> [caption] send a file
  hermes search <query...>            full-text search across all chats
  hermes schedule <chat> <when> <text...>   send later; when = 10m | 2h | 18:30 | 2026-10-10T09:00
  hermes scheduled                    list pending scheduled messages
  hermes focus on [duration] | off    focus mode (only VIPs notify)
  hermes open [chat]                  open the Hermes window
  hermes updates                      check WhatsApp/library update status
  hermes logout                       unlink this computer
`

type client struct {
	conn net.Conn
	r    *bufio.Reader
	id   int
}

func dial() (*client, error) {
	dir := os.Getenv("XDG_RUNTIME_DIR")
	if dir == "" {
		dir = os.TempDir()
	}
	path := os.Getenv("HERMES_SOCKET")
	if path == "" {
		path = filepath.Join(dir, "hermes.sock")
	}
	conn, err := net.Dial("unix", path)
	if err != nil {
		return nil, fmt.Errorf("can't reach hermesd at %s (is it running? try: systemctl --user start hermesd)", path)
	}
	r := bufio.NewReaderSize(conn, 1<<20)
	return &client{conn: conn, r: r}, nil
}

type envelope struct {
	ID     *int            `json:"id"`
	Result json.RawMessage `json:"result"`
	Error  *struct {
		Message string `json:"message"`
	} `json:"error"`
	Event string          `json:"event"`
	Data  json.RawMessage `json:"data"`
}

func (c *client) call(method string, params any, out any) error {
	c.id++
	b, _ := json.Marshal(map[string]any{"id": c.id, "method": method, "params": params})
	if _, err := c.conn.Write(append(b, '\n')); err != nil {
		return err
	}
	for {
		line, err := c.r.ReadBytes('\n')
		if err != nil {
			return err
		}
		var env envelope
		if err := json.Unmarshal(line, &env); err != nil {
			return err
		}
		if env.ID == nil || *env.ID != c.id {
			continue
		}
		if env.Error != nil {
			return errors.New(env.Error.Message)
		}
		if out != nil {
			return json.Unmarshal(env.Result, out)
		}
		return nil
	}
}

type chat struct {
	JID         string `json:"jid"`
	Name        string `json:"name"`
	Unread      int    `json:"unread"`
	LastTS      int64  `json:"lastTs"`
	LastPreview string `json:"lastPreview"`
	IsGroup     bool   `json:"isGroup"`
	MutedUntil  int64  `json:"mutedUntil"`
	PinnedTS    int64  `json:"pinnedTs"`
	Bucket      string `json:"bucket"`
	SnoozeUntil int64  `json:"snoozeUntil"`
	Note        string `json:"note"`
}

type status struct {
	State   string `json:"state"`
	QR      string `json:"qr"`
	MeJID   string `json:"meJid"`
	MeName  string `json:"meName"`
	Syncing bool   `json:"syncing"`
	Version string `json:"waVersion"`
}

// resolveChat accepts a JID, phone number, or (part of) a chat/contact name.
func (c *client) resolveChat(q string) (string, string, error) {
	if strings.Contains(q, "@") {
		return q, q, nil
	}
	digits := strings.TrimLeft(strings.NewReplacer(" ", "", "-", "", "(", "", ")", "").Replace(q), "+")
	if len(digits) >= 7 && strings.Trim(digits, "0123456789") == "" {
		var jid string
		if err := c.call("contacts.resolvePhone", map[string]string{"phone": digits}, &jid); err != nil {
			return "", "", err
		}
		return jid, "+" + digits, nil
	}
	lq := strings.ToLower(q)
	var chats []chat
	if err := c.call("chats.list", map[string]any{}, &chats); err != nil {
		return "", "", err
	}
	var matches []chat
	for _, ch := range chats {
		if strings.ToLower(ch.Name) == lq {
			return ch.JID, ch.Name, nil
		}
		if strings.Contains(strings.ToLower(ch.Name), lq) {
			matches = append(matches, ch)
		}
	}
	if len(matches) == 1 {
		return matches[0].JID, matches[0].Name, nil
	}
	if len(matches) == 0 {
		var contacts []struct{ JID, Name string }
		_ = c.call("contacts.search", map[string]string{"query": q}, &contacts)
		if len(contacts) == 1 {
			return contacts[0].JID, contacts[0].Name, nil
		}
		for _, ct := range contacts {
			matches = append(matches, chat{JID: ct.JID, Name: ct.Name})
		}
	}
	if len(matches) == 0 {
		return "", "", fmt.Errorf("no chat matches %q", q)
	}
	names := []string{}
	for i, m := range matches {
		if i == 8 {
			names = append(names, "…")
			break
		}
		names = append(names, m.Name)
	}
	return "", "", fmt.Errorf("%q is ambiguous: %s", q, strings.Join(names, ", "))
}

func ago(ts int64) string {
	if ts == 0 {
		return ""
	}
	t := time.Unix(ts, 0)
	switch d := time.Since(t); {
	case d < time.Minute:
		return "now"
	case d < time.Hour:
		return fmt.Sprintf("%dm", int(d.Minutes()))
	case t.YearDay() == time.Now().YearDay() && t.Year() == time.Now().Year():
		return t.Format("15:04")
	case d < 7*24*time.Hour:
		return t.Format("Mon")
	}
	return t.Format("02 Jan")
}

func parseWhen(s string) (time.Time, error) {
	if d, err := time.ParseDuration(s); err == nil {
		return time.Now().Add(d), nil
	}
	now := time.Now()
	if t, err := time.ParseInLocation("15:04", s, time.Local); err == nil {
		at := time.Date(now.Year(), now.Month(), now.Day(), t.Hour(), t.Minute(), 0, 0, time.Local)
		if at.Before(now) {
			at = at.Add(24 * time.Hour)
		}
		return at, nil
	}
	for _, layout := range []string{"2006-01-02T15:04", "2006-01-02 15:04"} {
		if t, err := time.ParseInLocation(layout, s, time.Local); err == nil {
			return t, nil
		}
	}
	return time.Time{}, fmt.Errorf("can't understand time %q", s)
}

func main() {
	if err := run(os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, "hermes:", err)
		os.Exit(1)
	}
}

func run(args []string) error {
	if len(args) == 0 || args[0] == "-h" || args[0] == "--help" || args[0] == "help" {
		fmt.Print(usage + dataUsage)
		return nil
	}
	if ok, err := localCommand(args); ok {
		return err
	}
	c, err := dial()
	if err != nil {
		return err
	}
	defer c.conn.Close()
	cmd, rest := args[0], args[1:]
	if ok, err := dataCommand(c, cmd, rest); ok {
		return err
	}
	switch cmd {
	case "status":
		var st status
		if err := c.call("status", nil, &st); err != nil {
			return err
		}
		fmt.Printf("state:     %s\n", st.State)
		if st.MeJID != "" {
			fmt.Printf("account:   %s (%s)\n", st.MeName, st.MeJID)
		}
		fmt.Printf("syncing:   %v\nwa version: %s\n", st.Syncing, st.Version)
	case "pair":
		return pair(c, rest)
	case "chats":
		archived := len(rest) > 0 && rest[0] == "--archived"
		var chats []chat
		if err := c.call("chats.list", map[string]bool{"archived": archived}, &chats); err != nil {
			return err
		}
		for _, ch := range chats {
			badge := "   "
			if ch.Unread > 0 {
				badge = fmt.Sprintf("%3d", ch.Unread)
			}
			flags := ""
			if ch.PinnedTS > 0 {
				flags += "📌"
			}
			if ch.MutedUntil > time.Now().Unix() {
				flags += "🔕"
			}
			prev := []rune(ch.LastPreview)
			if len(prev) > 50 {
				prev = append(prev[:49], '…')
			}
			fmt.Printf("%s  %-28.28s %6s %s %s\n", badge, ch.Name, ago(ch.LastTS), flags, string(prev))
		}
	case "inbox":
		var chats []chat
		if err := c.call("chats.list", map[string]bool{"archived": false}, &chats); err != nil {
			return err
		}
		sections := []struct{ key, title string }{
			{"reply", "Needs reply"}, {"mention", "Mentions"}, {"fyi", "FYI"}, {"waiting", "Waiting on them"}, {"snoozed", "Snoozed"},
		}
		if len(rest) > 0 && rest[0] == "--json" {
			counts := map[string]int{}
			for _, ch := range chats {
				counts[ch.Bucket]++
			}
			delete(counts, "done")
			b, _ := json.Marshal(counts)
			fmt.Println(string(b))
			return nil
		}
		empty := true
		for _, sec := range sections {
			var in []chat
			for _, ch := range chats {
				if ch.Bucket == sec.key {
					in = append(in, ch)
				}
			}
			if len(in) == 0 {
				continue
			}
			empty = false
			fmt.Printf("\n%s (%d)\n", sec.title, len(in))
			for _, ch := range in {
				prev := []rune(ch.LastPreview)
				if len(prev) > 50 {
					prev = append(prev[:49], '…')
				}
				when := ago(ch.LastTS)
				if sec.key == "snoozed" {
					when = time.Unix(ch.SnoozeUntil, 0).Format("Mon 15:04")
				}
				fmt.Printf("  %-28.28s %9s  %s\n", ch.Name, when, string(prev))
			}
		}
		if empty {
			fmt.Println("Inbox zero. Nothing needs you.")
		}
	case "done":
		if len(rest) < 1 {
			return errors.New("usage: hermes done <chat>")
		}
		jid, name, err := c.resolveChat(strings.Join(rest, " "))
		if err != nil {
			return err
		}
		if err := c.call("chats.done", map[string]any{"chat": jid, "value": true}, nil); err != nil {
			return err
		}
		fmt.Println("Done:", name)
	case "note":
		if len(rest) < 1 {
			return errors.New("usage: hermes note <chat> [text...]")
		}
		jid, name, err := c.resolveChat(rest[0])
		if err != nil {
			return err
		}
		if len(rest) == 1 {
			var ch chat
			if err := c.call("chats.get", map[string]string{"chat": jid}, &ch); err != nil {
				return err
			}
			if ch.Note == "" {
				fmt.Printf("No note on %s\n", name)
			} else {
				fmt.Println(ch.Note)
			}
			return nil
		}
		text := strings.Join(rest[1:], " ")
		if text == "-" {
			text = ""
		}
		if err := c.call("chats.setNote", map[string]string{"chat": jid, "text": text}, nil); err != nil {
			return err
		}
		fmt.Println("Saved note on", name)
	case "snippets":
		var list []struct{ Trigger, Text string }
		if err := c.call("snippets.list", nil, &list); err != nil {
			return err
		}
		if len(list) == 0 {
			fmt.Println("No snippets yet. Add one: hermes snippet addr \"221B Baker Street\"")
		}
		for _, sn := range list {
			fmt.Printf(";%-12s %s\n", sn.Trigger, strings.ReplaceAll(sn.Text, "\n", " ⏎ "))
		}
	case "snippet":
		if len(rest) < 1 {
			return errors.New("usage: hermes snippet <name> [text...]")
		}
		text := strings.Join(rest[1:], " ")
		if err := c.call("snippets.set", map[string]string{"trigger": rest[0], "text": text}, nil); err != nil {
			return err
		}
		if text == "" {
			fmt.Println("Deleted ;" + strings.TrimLeft(rest[0], ";"))
		} else {
			fmt.Println("Saved ;" + strings.TrimLeft(rest[0], ";"))
		}
	case "unread":
		var u map[string]int
		if err := c.call("chats.unread", nil, &u); err != nil {
			return err
		}
		if len(rest) > 0 && rest[0] == "--json" {
			b, _ := json.Marshal(u)
			fmt.Println(string(b))
		} else {
			fmt.Printf("%d unread messages in %d chats\n", u["messages"], u["chats"])
		}
	case "read":
		if len(rest) < 1 {
			return errors.New("usage: hermes read <chat>")
		}
		jid, name, err := c.resolveChat(strings.Join(rest, " "))
		if err != nil {
			return err
		}
		var msgs []struct {
			SenderName string `json:"senderName"`
			FromMe     bool   `json:"fromMe"`
			TS         int64  `json:"ts"`
			Type       string `json:"type"`
			Text       string `json:"text"`
			FileName   string `json:"fileName"`
			Revoked    bool   `json:"revoked"`
		}
		if err := c.call("messages.list", map[string]any{"chat": jid, "limit": 30}, &msgs); err != nil {
			return err
		}
		fmt.Printf("── %s ──\n", name)
		for _, m := range msgs {
			body := m.Text
			if m.Type != "text" {
				body = "[" + m.Type + "] " + m.FileName + " " + body
			}
			if m.Revoked {
				body = "🚫 deleted"
			}
			fmt.Printf("%s  %-14.14s %s\n", time.Unix(m.TS, 0).Format("Jan 02 15:04"), m.SenderName, body)
		}
	case "send":
		if len(rest) < 2 {
			return errors.New("usage: hermes send <chat> <text>")
		}
		jid, name, err := c.resolveChat(rest[0])
		if err != nil {
			return err
		}
		if err := c.call("messages.sendText", map[string]string{"chat": jid, "text": strings.Join(rest[1:], " ")}, nil); err != nil {
			return err
		}
		fmt.Printf("✓ sent to %s\n", name)
	case "file":
		if len(rest) < 2 {
			return errors.New("usage: hermes file <chat> <path> [caption]")
		}
		jid, name, err := c.resolveChat(rest[0])
		if err != nil {
			return err
		}
		abs, _ := filepath.Abs(rest[1])
		if err := c.call("messages.sendFile", map[string]string{"chat": jid, "path": abs, "caption": strings.Join(rest[2:], " ")}, nil); err != nil {
			return err
		}
		fmt.Printf("✓ sent %s to %s\n", filepath.Base(abs), name)
	case "search":
		var hits []struct {
			ChatName   string `json:"chatName"`
			SenderName string `json:"senderName"`
			TS         int64  `json:"ts"`
			Snippet    string `json:"snippet"`
		}
		if err := c.call("messages.search", map[string]any{"query": strings.Join(rest, " "), "limit": 30}, &hits); err != nil {
			return err
		}
		for _, h := range hits {
			fmt.Printf("%s  %-20.20s %-12.12s %s\n", time.Unix(h.TS, 0).Format("2006-01-02"), h.ChatName, h.SenderName, h.Snippet)
		}
		if len(hits) == 0 {
			fmt.Println("no results")
		}
	case "schedule":
		if len(rest) < 3 {
			return errors.New("usage: hermes schedule <chat> <when> <text>")
		}
		jid, name, err := c.resolveChat(rest[0])
		if err != nil {
			return err
		}
		at, err := parseWhen(rest[1])
		if err != nil {
			return err
		}
		if err := c.call("schedule.add", map[string]any{"chat": jid, "text": strings.Join(rest[2:], " "), "at": at.Unix()}, nil); err != nil {
			return err
		}
		fmt.Printf("⏰ will send to %s at %s\n", name, at.Format("Mon Jan 2 15:04"))
	case "scheduled":
		var list []struct {
			ID     int64  `json:"id"`
			Name   string `json:"name"`
			Text   string `json:"text"`
			SendAt int64  `json:"sendAt"`
		}
		if err := c.call("schedule.list", map[string]any{}, &list); err != nil {
			return err
		}
		for _, s := range list {
			fmt.Printf("#%-4d %s  %-20.20s %s\n", s.ID, time.Unix(s.SendAt, 0).Format("Jan 02 15:04"), s.Name, s.Text)
		}
		if len(list) == 0 {
			fmt.Println("nothing scheduled")
		}
	case "focus":
		if len(rest) == 0 {
			var f map[string]any
			if err := c.call("focus.get", nil, &f); err != nil {
				return err
			}
			fmt.Printf("focus active: %v\n", f["active"])
			return nil
		}
		until := int64(0)
		if rest[0] == "on" {
			until = -1
			if len(rest) > 1 {
				d, err := time.ParseDuration(rest[1])
				if err != nil {
					return err
				}
				until = time.Now().Add(d).Unix()
			}
		}
		if err := c.call("focus.set", map[string]any{"until": until}, nil); err != nil {
			return err
		}
		fmt.Println("focus", rest[0])
	case "open":
		jid := ""
		if len(rest) > 0 {
			var err error
			if jid, _, err = c.resolveChat(strings.Join(rest, " ")); err != nil {
				return err
			}
		}
		return c.call("ui.open", map[string]string{"chat": jid}, nil)
	case "updates":
		var u map[string]any
		if err := c.call("updates.check", nil, &u); err != nil {
			return err
		}
		fmt.Printf("WhatsApp Web version advertised: %v\n", u["waVersion"])
		fmt.Printf("whatsmeow built:  %v\nwhatsmeow latest: %v\n", u["libraryCurrent"], u["libraryLatest"])
		if u["libraryOutdated"] == true {
			fmt.Printf("→ library is %v days behind; run hermes-update\n", u["libraryAgeDays"])
		} else {
			fmt.Println("→ up to date")
		}
	case "logout":
		return c.call("auth.logout", nil, nil)
	default:
		fmt.Print(usage)
		return fmt.Errorf("unknown command %q", cmd)
	}
	return nil
}

func pair(c *client, args []string) error {
	var st status
	if err := c.call("status", nil, &st); err != nil {
		return err
	}
	if st.MeJID != "" {
		fmt.Printf("Already linked as %s (%s)\n", st.MeName, st.MeJID)
		return nil
	}
	if len(args) == 2 && args[0] == "--phone" {
		var code string
		if err := c.call("auth.pairPhone", map[string]string{"phone": args[1]}, &code); err != nil {
			return err
		}
		fmt.Printf("On your phone: WhatsApp → Linked devices → Link with phone number instead\nEnter code: %s\n", code)
	}
	if err := c.call("events.subscribe", map[string]any{}, nil); err != nil {
		return err
	}
	lastQR := ""
	show := func(qr string) {
		if qr == "" || qr == lastQR || len(args) > 0 {
			return
		}
		lastQR = qr
		fmt.Print("\033[H\033[2J")
		fmt.Println("Scan with WhatsApp → Settings → Linked devices → Link a device")
		qrterminal.GenerateHalfBlock(qr, qrterminal.L, os.Stdout)
	}
	show(st.QR)
	for {
		line, err := c.r.ReadBytes('\n')
		if err != nil {
			return err
		}
		var env envelope
		if json.Unmarshal(line, &env) != nil || env.Event != "state" {
			continue
		}
		var s status
		_ = json.Unmarshal(env.Data, &s)
		switch s.State {
		case "pairing":
			show(s.QR)
		case "connected":
			fmt.Printf("\n✓ Linked as %s. History is syncing in the background.\n", s.MeName)
			return nil
		}
	}
}
