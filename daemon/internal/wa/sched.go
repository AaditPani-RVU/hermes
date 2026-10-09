package wa

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"runtime/debug"
	"strings"
	"time"

	"go.mau.fi/whatsmeow/store"

	hs "github.com/aadit/hermes/daemon/internal/store"
)

// ---- Scheduled messages ----

type Scheduled struct {
	ID     int64  `json:"id"`
	Chat   string `json:"chat"`
	Name   string `json:"name"`
	Text   string `json:"text"`
	SendAt int64  `json:"sendAt"`
	Status string `json:"status"` // pending, sent, failed, cancelled
	Error  string `json:"error,omitempty"`
}

const schedSchema = `CREATE TABLE IF NOT EXISTS hermes_scheduled (
	id INTEGER PRIMARY KEY AUTOINCREMENT,
	chat TEXT NOT NULL,
	text TEXT NOT NULL,
	send_at INTEGER NOT NULL,
	status TEXT NOT NULL DEFAULT 'pending',
	error TEXT NOT NULL DEFAULT ''
)`

func (c *Core) Schedule(ctx context.Context, chat, text string, at time.Time) (*Scheduled, error) {
	if strings.TrimSpace(text) == "" {
		return nil, errors.New("empty message")
	}
	if at.Before(time.Now().Add(-time.Minute)) {
		return nil, errors.New("time is in the past")
	}
	res, err := c.Store.DB.ExecContext(ctx, `INSERT INTO hermes_scheduled (chat, text, send_at) VALUES (?,?,?)`, chat, text, at.Unix())
	if err != nil {
		return nil, err
	}
	id, _ := res.LastInsertId()
	s := &Scheduled{ID: id, Chat: chat, Text: text, SendAt: at.Unix(), Status: "pending"}
	c.Emit("scheduled", s)
	return s, nil
}

func (c *Core) ListScheduled(ctx context.Context, chat string) ([]*Scheduled, error) {
	q := `SELECT id, chat, text, send_at, status, error FROM hermes_scheduled WHERE status='pending'`
	args := []any{}
	if chat != "" {
		q += ` AND chat=?`
		args = append(args, chat)
	}
	rows, err := c.Store.DB.QueryContext(ctx, q+` ORDER BY send_at`, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []*Scheduled{}
	for rows.Next() {
		var s Scheduled
		if err := rows.Scan(&s.ID, &s.Chat, &s.Text, &s.SendAt, &s.Status, &s.Error); err != nil {
			return nil, err
		}
		out = append(out, &s)
	}
	for _, s := range out {
		if ch, _ := c.GetChat(ctx, s.Chat); ch != nil {
			s.Name = ch.Name
		}
	}
	return out, rows.Err()
}

func (c *Core) CancelScheduled(ctx context.Context, id int64) error {
	_, err := c.Store.DB.ExecContext(ctx, `UPDATE hermes_scheduled SET status='cancelled' WHERE id=? AND status='pending'`, id)
	c.Emit("scheduled.changed", nil)
	return err
}

func (c *Core) schedulerLoop(ctx context.Context) {
	if _, err := c.Store.DB.ExecContext(ctx, schedSchema); err != nil {
		c.Log.Errorf("scheduler schema: %v", err)
		return
	}
	t := time.NewTicker(15 * time.Second)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
		}
		c.wakeSnoozes(ctx)
		if c.Status().State != "connected" {
			continue
		}
		rows, err := c.Store.DB.QueryContext(ctx, `SELECT id, chat, text FROM hermes_scheduled
			WHERE status='pending' AND send_at <= ? ORDER BY send_at LIMIT 5`, time.Now().Unix())
		if err != nil {
			continue
		}
		type due struct {
			id         int64
			chat, text string
		}
		var list []due
		for rows.Next() {
			var d due
			if rows.Scan(&d.id, &d.chat, &d.text) == nil {
				list = append(list, d)
			}
		}
		rows.Close()
		for _, d := range list {
			status, errText := "sent", ""
			if _, err := c.SendText(ctx, d.chat, d.text, SendOpts{}); err != nil {
				status, errText = "failed", err.Error()
				c.notifySystem("Scheduled message failed", errText)
			}
			_, _ = c.Store.DB.ExecContext(ctx, `UPDATE hermes_scheduled SET status=?, error=? WHERE id=?`, status, errText, d.id)
			c.Emit("scheduled.changed", nil)
			time.Sleep(2 * time.Second) // never burst
		}
	}
}

// wakeSnoozes brings snoozed chats back into the inbox when their time comes.
func (c *Core) wakeSnoozes(ctx context.Context) {
	due, err := c.Store.DueSnoozes(ctx, time.Now().Unix())
	if err != nil {
		c.Log.Warnf("snoozes: %v", err)
		return
	}
	for _, ch := range due {
		c.emitChat(ctx, ch.JID)
		if c.Notify == nil {
			continue
		}
		full, _ := c.GetChat(ctx, ch.JID)
		if full == nil {
			continue
		}
		body := full.LastPreview
		if ch.SnoozeMsg != "" {
			if m, _ := c.Store.GetMessage(ctx, ch.JID, ch.SnoozeMsg); m != nil {
				body = hs.Preview(m)
			}
		}
		c.Notify.NotifyReminder(full, body)
	}
}

// ---- Update watching ----
//
// Two things can go stale:
//  1. The WhatsApp Web version we advertise. WhatsApp bumps this constantly, so we
//     re-read it from web.whatsapp.com every few hours (no rebuild needed).
//  2. The whatsmeow library itself, when WhatsApp changes the protocol. That needs a
//     rebuild, so we check the Go module proxy daily and tell the user to run hermes-update.

type UpdateInfo struct {
	WAVersion       string `json:"waVersion"`
	LibraryCurrent  string `json:"libraryCurrent"`
	LibraryLatest   string `json:"libraryLatest"`
	LibraryOutdated bool   `json:"libraryOutdated"`
	LibraryAgeDays  int    `json:"libraryAgeDays"`
	CheckedAt       int64  `json:"checkedAt"`
}

func builtWhatsmeowVersion() string {
	bi, ok := debug.ReadBuildInfo()
	if !ok {
		return ""
	}
	for _, d := range bi.Deps {
		if d.Path == "go.mau.fi/whatsmeow" {
			if d.Replace != nil {
				return d.Replace.Version
			}
			return d.Version
		}
	}
	return ""
}

// pseudoTime extracts the commit time from a pseudo-version like v0.0.0-20261007111105-c386243a72ba.
func pseudoTime(v string) time.Time {
	parts := strings.Split(v, "-")
	if len(parts) < 3 {
		return time.Time{}
	}
	t, _ := time.Parse("20060102150405", parts[len(parts)-2])
	return t
}

func (c *Core) CheckUpdates(ctx context.Context) (*UpdateInfo, error) {
	c.refreshWAVersion(ctx)
	info := &UpdateInfo{WAVersion: store.GetWAVersion().String(), LibraryCurrent: builtWhatsmeowVersion(), CheckedAt: time.Now().Unix()}
	reqCtx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	req, _ := http.NewRequestWithContext(reqCtx, http.MethodGet, "https://proxy.golang.org/go.mau.fi/whatsmeow/@latest", nil)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return info, err
	}
	defer resp.Body.Close()
	var latest struct{ Version string }
	if err := json.NewDecoder(resp.Body).Decode(&latest); err != nil {
		return info, err
	}
	info.LibraryLatest = latest.Version
	cur, lat := pseudoTime(info.LibraryCurrent), pseudoTime(latest.Version)
	if !cur.IsZero() && !lat.IsZero() && lat.After(cur) {
		info.LibraryOutdated = true
		info.LibraryAgeDays = int(lat.Sub(cur).Hours() / 24)
	}
	return info, nil
}

func (c *Core) versionWatcher(ctx context.Context) {
	check := func() {
		info, err := c.CheckUpdates(ctx)
		if err != nil {
			c.Log.Warnf("update check: %v", err)
		}
		if info == nil {
			return
		}
		c.Emit("update", info)
		// Nag once per upstream version, and only when it's been a few days:
		// whatsmeow commits often and most are not urgent.
		if info.LibraryOutdated && info.LibraryAgeDays >= 3 && c.Store.GetKV(ctx, "notified_lib") != info.LibraryLatest {
			_ = c.Store.SetKV(ctx, "notified_lib", info.LibraryLatest)
			c.notifySystem("Hermes update available",
				"The WhatsApp protocol library has updates ("+info.LibraryLatest+"). Run `hermes-update` to stay compatible.")
		}
	}
	time.Sleep(30 * time.Second)
	check()
	t := time.NewTicker(6 * time.Hour)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			check()
		}
	}
}
