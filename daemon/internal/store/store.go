// Package store holds Hermes' own view of chats and messages, separate from
// the whatsmeow key store. It is the source of truth for the UI.
package store

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"
)

type Chat struct {
	JID          string `json:"jid"`
	Name         string `json:"name"`
	IsGroup      bool   `json:"isGroup"`
	LastTS       int64  `json:"lastTs"`
	LastMsgID    string `json:"lastMsgId"`
	LastPreview  string `json:"lastPreview"`
	LastSender   string `json:"lastSender"`
	LastFromMe   bool   `json:"lastFromMe"`
	LastStatus   int    `json:"lastStatus"`
	Unread       int    `json:"unread"`
	MarkedUnread bool   `json:"markedUnread"`
	Archived     bool   `json:"archived"`
	PinnedTS     int64  `json:"pinnedTs"`
	MutedUntil   int64  `json:"mutedUntil"`
	Ephemeral    int64  `json:"ephemeral"`
	AvatarPath   string `json:"avatarPath"`
	AvatarID     string `json:"-"`
	Draft        string `json:"draft"`
	DoneTS       int64  `json:"doneTs"`
	SnoozeUntil  int64  `json:"snoozeUntil"`
	SnoozeMsg    string `json:"snoozeMsg"`
	SnoozeNote   string `json:"snoozeNote"` // preview of SnoozeMsg, for "remind me about this"
	MentionTS    int64  `json:"mentionTs"`
	RepliedTS    int64  `json:"repliedTs"`
	Note         string `json:"note"`   // private, never sent
	Bucket       string `json:"bucket"` // triage: reply mention fyi waiting snoozed done
}

// Message statuses, ordered so that a higher value always wins.
const (
	StatusFailed    = -1
	StatusPending   = 0
	StatusSent      = 1
	StatusDelivered = 2
	StatusRead      = 3
	StatusPlayed    = 4
)

type Reaction struct {
	Sender     string `json:"sender"`
	SenderName string `json:"senderName"`
	Emoji      string `json:"emoji"`
	FromMe     bool   `json:"fromMe"`
}

type Message struct {
	Chat         string     `json:"chat"`
	ID           string     `json:"id"`
	Sender       string     `json:"sender"`
	SenderName   string     `json:"senderName"`
	FromMe       bool       `json:"fromMe"`
	TS           int64      `json:"ts"`
	Type         string     `json:"type"` // text image video audio voice document sticker location contact poll system revoked unknown
	Text         string     `json:"text"`
	MediaMime    string     `json:"mediaMime,omitempty"`
	MediaPath    string     `json:"mediaPath,omitempty"`
	ThumbPath    string     `json:"thumbPath,omitempty"`
	MediaSize    int64      `json:"mediaSize,omitempty"`
	MediaW       int        `json:"mediaW,omitempty"`
	MediaH       int        `json:"mediaH,omitempty"`
	MediaSecs    int        `json:"mediaSecs,omitempty"`
	FileName     string     `json:"fileName,omitempty"`
	QuotedID     string     `json:"quotedId,omitempty"`
	QuotedSender string     `json:"quotedSender,omitempty"`
	QuotedText   string     `json:"quotedText,omitempty"`
	Status       int        `json:"status"`
	Edited       bool       `json:"edited"`
	Revoked      bool       `json:"revoked"`
	ViewOnce     bool       `json:"viewOnce"`
	Starred      bool       `json:"starred"`
	Extra        string     `json:"extra,omitempty"` // JSON blob: location, poll options, contact card...
	Reactions    []Reaction `json:"reactions"`
	Raw          []byte     `json:"-"` // serialized waE2E.Message, used for lazy media download
	MentionsMe   bool       `json:"-"` // set by the converter; not stored, only bumps the chat's mention_ts
}

type Store struct {
	DB *sql.DB
}

const schema = `
CREATE TABLE IF NOT EXISTS hermes_chats (
	jid TEXT PRIMARY KEY,
	name TEXT NOT NULL DEFAULT '',
	is_group INTEGER NOT NULL DEFAULT 0,
	last_ts INTEGER NOT NULL DEFAULT 0,
	last_msg_id TEXT NOT NULL DEFAULT '',
	unread INTEGER NOT NULL DEFAULT 0,
	marked_unread INTEGER NOT NULL DEFAULT 0,
	archived INTEGER NOT NULL DEFAULT 0,
	pinned_ts INTEGER NOT NULL DEFAULT 0,
	muted_until INTEGER NOT NULL DEFAULT 0,
	ephemeral INTEGER NOT NULL DEFAULT 0,
	avatar_path TEXT NOT NULL DEFAULT '',
	avatar_id TEXT NOT NULL DEFAULT '',
	draft TEXT NOT NULL DEFAULT ''
);
CREATE TABLE IF NOT EXISTS hermes_messages (
	chat TEXT NOT NULL,
	id TEXT NOT NULL,
	sender TEXT NOT NULL DEFAULT '',
	sender_name TEXT NOT NULL DEFAULT '',
	from_me INTEGER NOT NULL DEFAULT 0,
	ts INTEGER NOT NULL,
	type TEXT NOT NULL,
	text TEXT NOT NULL DEFAULT '',
	media_mime TEXT NOT NULL DEFAULT '',
	media_path TEXT NOT NULL DEFAULT '',
	thumb_path TEXT NOT NULL DEFAULT '',
	media_size INTEGER NOT NULL DEFAULT 0,
	media_w INTEGER NOT NULL DEFAULT 0,
	media_h INTEGER NOT NULL DEFAULT 0,
	media_secs INTEGER NOT NULL DEFAULT 0,
	file_name TEXT NOT NULL DEFAULT '',
	quoted_id TEXT NOT NULL DEFAULT '',
	quoted_sender TEXT NOT NULL DEFAULT '',
	quoted_text TEXT NOT NULL DEFAULT '',
	status INTEGER NOT NULL DEFAULT 0,
	edited INTEGER NOT NULL DEFAULT 0,
	revoked INTEGER NOT NULL DEFAULT 0,
	view_once INTEGER NOT NULL DEFAULT 0,
	starred INTEGER NOT NULL DEFAULT 0,
	extra TEXT NOT NULL DEFAULT '',
	raw BLOB,
	PRIMARY KEY (chat, id)
);
CREATE INDEX IF NOT EXISTS hermes_messages_chat_ts ON hermes_messages (chat, ts);
CREATE TABLE IF NOT EXISTS hermes_reactions (
	chat TEXT NOT NULL,
	msg_id TEXT NOT NULL,
	sender TEXT NOT NULL,
	emoji TEXT NOT NULL,
	ts INTEGER NOT NULL,
	PRIMARY KEY (chat, msg_id, sender)
);
CREATE VIRTUAL TABLE IF NOT EXISTS hermes_messages_fts USING fts5(
	text, content='hermes_messages', content_rowid='rowid', tokenize='unicode61 remove_diacritics 2'
);
CREATE TRIGGER IF NOT EXISTS hermes_messages_ai AFTER INSERT ON hermes_messages BEGIN
	INSERT INTO hermes_messages_fts(rowid, text) VALUES (new.rowid, new.text);
END;
CREATE TRIGGER IF NOT EXISTS hermes_messages_ad AFTER DELETE ON hermes_messages BEGIN
	INSERT INTO hermes_messages_fts(hermes_messages_fts, rowid, text) VALUES ('delete', old.rowid, old.text);
END;
CREATE TRIGGER IF NOT EXISTS hermes_messages_au AFTER UPDATE OF text ON hermes_messages BEGIN
	INSERT INTO hermes_messages_fts(hermes_messages_fts, rowid, text) VALUES ('delete', old.rowid, old.text);
	INSERT INTO hermes_messages_fts(rowid, text) VALUES (new.rowid, new.text);
END;
CREATE TABLE IF NOT EXISTS hermes_kv (k TEXT PRIMARY KEY, v TEXT NOT NULL);
`

// Columns added after the first release. ALTER TABLE has no IF NOT EXISTS in
// SQLite, so each one is tried and "duplicate column" is ignored.
var chatMigrations = []string{
	`ALTER TABLE hermes_chats ADD COLUMN done_ts INTEGER NOT NULL DEFAULT 0`,
	`ALTER TABLE hermes_chats ADD COLUMN snooze_until INTEGER NOT NULL DEFAULT 0`,
	`ALTER TABLE hermes_chats ADD COLUMN snooze_msg TEXT NOT NULL DEFAULT ''`,
	`ALTER TABLE hermes_chats ADD COLUMN mention_ts INTEGER NOT NULL DEFAULT 0`,
	`ALTER TABLE hermes_chats ADD COLUMN replied_ts INTEGER NOT NULL DEFAULT 0`,
	`ALTER TABLE hermes_chats ADD COLUMN note TEXT NOT NULL DEFAULT ''`,
	`CREATE TABLE IF NOT EXISTS hermes_snippets (name TEXT PRIMARY KEY, text TEXT NOT NULL)`,
	`CREATE TABLE IF NOT EXISTS hermes_status_seen (id TEXT PRIMARY KEY, ts INTEGER NOT NULL)`,
}

func Open(ctx context.Context, db *sql.DB) (*Store, error) {
	if _, err := db.ExecContext(ctx, schema); err != nil {
		return nil, fmt.Errorf("hermes schema: %w", err)
	}
	for _, m := range chatMigrations {
		if _, err := db.ExecContext(ctx, m); err != nil && !strings.Contains(err.Error(), "duplicate column") {
			return nil, fmt.Errorf("hermes migration: %w", err)
		}
	}
	s := &Store{DB: db}
	if s.GetKV(ctx, "triage_backfill") == "" {
		// replied_ts drives "never talked to them" detection, so seed it from history.
		if _, err := db.ExecContext(ctx, `UPDATE hermes_chats SET replied_ts = COALESCE(
			(SELECT MAX(ts) FROM hermes_messages m WHERE m.chat = hermes_chats.jid AND m.from_me = 1), 0)`); err != nil {
			return nil, fmt.Errorf("triage backfill: %w", err)
		}
		_ = s.SetKV(ctx, "triage_backfill", "1")
	}
	return s, nil
}

func b2i(b bool) int {
	if b {
		return 1
	}
	return 0
}

const chatCols = `jid, name, is_group, last_ts, last_msg_id, unread, marked_unread, archived, pinned_ts, muted_until, ephemeral, avatar_path, avatar_id, draft,
	done_ts, snooze_until, snooze_msg, mention_ts, replied_ts, note`

func scanChat(row interface{ Scan(...any) error }) (*Chat, error) {
	var c Chat
	err := row.Scan(&c.JID, &c.Name, &c.IsGroup, &c.LastTS, &c.LastMsgID, &c.Unread, &c.MarkedUnread,
		&c.Archived, &c.PinnedTS, &c.MutedUntil, &c.Ephemeral, &c.AvatarPath, &c.AvatarID, &c.Draft,
		&c.DoneTS, &c.SnoozeUntil, &c.SnoozeMsg, &c.MentionTS, &c.RepliedTS, &c.Note)
	return &c, err
}

// Triage windows: activity older than this drops out of the inbox on its own,
// so a fresh install doesn't start with every chat ever as "needs reply".
const (
	InboxWindow   = 7 * 24 * 60 * 60
	WaitingWindow = 3 * 24 * 60 * 60
)

// Bucket sorts a chat into the triage inbox. Must run after fillPreview (needs LastFromMe).
//
//	reply    a person wrote to you and you haven't answered or cleared it
//	mention  someone @-mentioned or replied to you in a group
//	fyi      unread group chatter, or DMs from senders you never write to (OTPs, shops)
//	waiting  you sent the last message in a DM; the ball is in their court
//	snoozed  hidden until snooze_until
//	done     everything else (cleared, stale, muted, archived)
func Bucket(c *Chat, now int64) string {
	switch {
	case c.SnoozeUntil > now:
		return "snoozed"
	case c.SnoozeUntil > 0:
		return "reply" // expired; the scheduler is about to bring it back
	case c.Archived || c.JID == "status@broadcast" || strings.HasSuffix(c.JID, "@newsletter") || strings.HasSuffix(c.JID, "@broadcast"):
		return "done"
	case c.MarkedUnread:
		return "reply"
	case c.LastTS <= c.DoneTS:
		return "done"
	}
	recent := now-c.LastTS < InboxWindow
	muted := c.MutedUntil > now
	if c.IsGroup {
		switch {
		case c.MentionTS > c.DoneTS && c.MentionTS > c.RepliedTS && now-c.MentionTS < InboxWindow:
			return "mention"
		case muted || c.LastFromMe || !recent:
			return "done"
		case c.Unread > 0:
			return "fyi"
		}
		return "done"
	}
	switch {
	case !recent:
		return "done"
	case c.LastFromMe:
		if now-c.LastTS < WaitingWindow {
			return "waiting"
		}
		return "done"
	case c.RepliedTS == 0 || muted:
		if c.Unread > 0 {
			return "fyi"
		}
		return "done"
	}
	return "reply"
}

// EnsureChat creates the chat row if it doesn't exist yet.
func (s *Store) EnsureChat(ctx context.Context, jid string, isGroup bool) error {
	_, err := s.DB.ExecContext(ctx, `INSERT INTO hermes_chats (jid, is_group) VALUES (?, ?) ON CONFLICT(jid) DO NOTHING`, jid, b2i(isGroup))
	return err
}

func (s *Store) GetChat(ctx context.Context, jid string) (*Chat, error) {
	c, err := scanChat(s.DB.QueryRowContext(ctx, `SELECT `+chatCols+` FROM hermes_chats WHERE jid=?`, jid))
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	} else if err != nil {
		return nil, err
	}
	s.fillPreview(ctx, c)
	c.FillBucket()
	return c, nil
}

func (s *Store) fillPreview(ctx context.Context, c *Chat) {
	if c.SnoozeMsg != "" {
		if m, _ := s.GetMessage(ctx, c.JID, c.SnoozeMsg); m != nil {
			c.SnoozeNote = Preview(m)
		}
	}
	if c.LastMsgID == "" {
		return
	}
	m, err := s.GetMessage(ctx, c.JID, c.LastMsgID)
	if err != nil || m == nil {
		return
	}
	c.LastPreview = Preview(m)
	c.LastSender = m.SenderName
	c.LastFromMe = m.FromMe
	c.LastStatus = m.Status
}

// FillBucket computes the triage bucket; fillPreview must have run.
func (c *Chat) FillBucket() {
	c.Bucket = Bucket(c, time.Now().Unix())
}

// Preview renders a short single-line summary of a message for chat lists and notifications.
func Preview(m *Message) string {
	if m.Revoked {
		return "🚫 This message was deleted"
	}
	text := strings.ReplaceAll(m.Text, "\n", " ")
	label := func(icon, name string) string {
		if text != "" {
			return icon + " " + text
		}
		return icon + " " + name
	}
	switch m.Type {
	case "image":
		return label("📷", "Photo")
	case "video":
		return label("🎥", "Video")
	case "gif":
		return label("🎞", "GIF")
	case "voice":
		if text != "" {
			return "🎤 " + text // transcript
		}
		return "🎤 Voice message"
	case "audio":
		return "🎵 Audio"
	case "document":
		if m.FileName != "" {
			return "📄 " + m.FileName
		}
		return label("📄", "Document")
	case "sticker":
		return "💟 Sticker"
	case "location":
		return "📍 Location"
	case "contact":
		return label("👤", "Contact")
	case "poll":
		return "📊 " + text
	case "call":
		return "📞 " + text
	}
	return text
}

func (s *Store) ListChats(ctx context.Context, archived bool) ([]*Chat, error) {
	rows, err := s.DB.QueryContext(ctx, `SELECT `+chatCols+` FROM hermes_chats
		WHERE archived=? AND jid != 'status@broadcast' AND (last_ts > 0 OR draft != '')
		ORDER BY pinned_ts DESC, last_ts DESC`, b2i(archived))
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []*Chat
	for rows.Next() {
		c, err := scanChat(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, c)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	for _, c := range out {
		s.fillPreview(ctx, c)
		c.FillBucket()
	}
	return out, nil
}

func (s *Store) SetChatName(ctx context.Context, jid, name string) error {
	_, err := s.DB.ExecContext(ctx, `UPDATE hermes_chats SET name=? WHERE jid=?`, name, jid)
	return err
}

// RenameSender rewrites the stored display name on everything a person sent,
// so a name learned later (saved contact or profile name) applies to old messages.
func (s *Store) RenameSender(ctx context.Context, sender, name string) (int64, error) {
	res, err := s.DB.ExecContext(ctx, `UPDATE hermes_messages SET sender_name=? WHERE sender=? AND from_me=0 AND sender_name<>?`,
		name, sender, name)
	if err != nil {
		return 0, err
	}
	return res.RowsAffected()
}

// Senders lists everyone who has sent a message, other than this account.
func (s *Store) Senders(ctx context.Context) ([]string, error) {
	rows, err := s.DB.QueryContext(ctx, `SELECT DISTINCT sender FROM hermes_messages WHERE from_me=0 AND sender<>''`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []string
	for rows.Next() {
		var j string
		if err := rows.Scan(&j); err != nil {
			return nil, err
		}
		out = append(out, j)
	}
	return out, rows.Err()
}

// ShortName is the first word of a sender name for compact lists, keeping the
// "~ " marker that flags an unsaved contact's profile name.
func ShortName(name string) string {
	if rest, ok := strings.CutPrefix(name, "~ "); ok {
		return "~ " + strings.Fields(rest + " ")[0]
	}
	return strings.Fields(name + " ")[0]
}

func (s *Store) SetChatAvatar(ctx context.Context, jid, path, id string) error {
	_, err := s.DB.ExecContext(ctx, `UPDATE hermes_chats SET avatar_path=?, avatar_id=? WHERE jid=?`, path, id, jid)
	return err
}

func (s *Store) SetChatField(ctx context.Context, jid, field string, value any) error {
	switch field {
	case "archived", "pinned_ts", "muted_until", "unread", "marked_unread", "ephemeral", "draft",
		"done_ts", "snooze_until", "snooze_msg", "note":
	default:
		return fmt.Errorf("unknown chat field %q", field)
	}
	_, err := s.DB.ExecContext(ctx, `UPDATE hermes_chats SET `+field+`=? WHERE jid=?`, value, jid)
	return err
}

// BumpChat updates the last message pointer if msg is newer, and optionally increments unread.
func (s *Store) BumpChat(ctx context.Context, jid, msgID string, ts int64, incUnread bool) error {
	_, err := s.DB.ExecContext(ctx, `UPDATE hermes_chats SET
		last_msg_id = CASE WHEN ? >= last_ts THEN ? ELSE last_msg_id END,
		last_ts = MAX(last_ts, ?),
		unread = unread + ?
		WHERE jid=?`, ts, msgID, ts, b2i(incUnread), jid)
	return err
}

// RecomputeLast points the chat at its newest stored message (used after history sync).
func (s *Store) RecomputeLast(ctx context.Context, jid string) error {
	_, err := s.DB.ExecContext(ctx, `UPDATE hermes_chats SET
		last_msg_id = COALESCE((SELECT id FROM hermes_messages WHERE chat=? ORDER BY ts DESC LIMIT 1), last_msg_id),
		last_ts = MAX(last_ts, COALESCE((SELECT MAX(ts) FROM hermes_messages WHERE chat=?), 0))
		WHERE jid=?`, jid, jid, jid)
	return err
}

func (s *Store) TotalUnread(ctx context.Context) (chats int, msgs int, err error) {
	err = s.DB.QueryRowContext(ctx, `SELECT COUNT(*), COALESCE(SUM(unread),0) FROM hermes_chats
		WHERE (unread > 0 OR marked_unread=1) AND archived=0 AND muted_until <= ? AND jid != 'status@broadcast'`,
		time.Now().Unix()).Scan(&chats, &msgs)
	return
}

const msgCols = `chat, id, sender, sender_name, from_me, ts, type, text, media_mime, media_path, thumb_path, media_size,
	media_w, media_h, media_secs, file_name, quoted_id, quoted_sender, quoted_text, status, edited, revoked, view_once, starred, extra, raw`

func scanMsg(row interface{ Scan(...any) error }) (*Message, error) {
	var m Message
	err := row.Scan(&m.Chat, &m.ID, &m.Sender, &m.SenderName, &m.FromMe, &m.TS, &m.Type, &m.Text, &m.MediaMime, &m.MediaPath,
		&m.ThumbPath, &m.MediaSize, &m.MediaW, &m.MediaH, &m.MediaSecs, &m.FileName, &m.QuotedID, &m.QuotedSender,
		&m.QuotedText, &m.Status, &m.Edited, &m.Revoked, &m.ViewOnce, &m.Starred, &m.Extra, &m.Raw)
	return &m, err
}

// UpsertMessage inserts a message or refreshes its content. Status only moves forward,
// and local state (media path, revoked, starred) is never clobbered by a re-delivery.
func (s *Store) UpsertMessage(ctx context.Context, m *Message) (inserted bool, err error) {
	res, err := s.DB.ExecContext(ctx, `INSERT INTO hermes_messages (`+msgCols+`)
		VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
		ON CONFLICT(chat, id) DO NOTHING`,
		m.Chat, m.ID, m.Sender, m.SenderName, b2i(m.FromMe), m.TS, m.Type, m.Text, m.MediaMime, m.MediaPath,
		m.ThumbPath, m.MediaSize, m.MediaW, m.MediaH, m.MediaSecs, m.FileName, m.QuotedID, m.QuotedSender,
		m.QuotedText, m.Status, b2i(m.Edited), b2i(m.Revoked), b2i(m.ViewOnce), b2i(m.Starred), m.Extra, m.Raw)
	if err != nil {
		return false, err
	}
	n, _ := res.RowsAffected()
	if n > 0 {
		switch {
		case m.FromMe:
			_, err = s.DB.ExecContext(ctx, `UPDATE hermes_chats SET replied_ts = MAX(replied_ts, ?) WHERE jid=?`, m.TS, m.Chat)
		case m.MentionsMe:
			_, err = s.DB.ExecContext(ctx, `UPDATE hermes_chats SET mention_ts = MAX(mention_ts, ?) WHERE jid=?`, m.TS, m.Chat)
		}
		return true, err
	}
	_, err = s.DB.ExecContext(ctx, `UPDATE hermes_messages SET status = MAX(status, ?),
		sender_name = CASE WHEN sender_name = '' THEN ? ELSE sender_name END,
		thumb_path = CASE WHEN thumb_path = '' THEN ? ELSE thumb_path END
		WHERE chat=? AND id=?`, m.Status, m.SenderName, m.ThumbPath, m.Chat, m.ID)
	return false, err
}

func (s *Store) GetMessage(ctx context.Context, chat, id string) (*Message, error) {
	m, err := scanMsg(s.DB.QueryRowContext(ctx, `SELECT `+msgCols+` FROM hermes_messages WHERE chat=? AND id=?`, chat, id))
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	} else if err != nil {
		return nil, err
	}
	m.Reactions, _ = s.reactions(ctx, chat, id)
	return m, nil
}

// ListMessages returns up to limit messages older than beforeTS (0 = newest), oldest first.
func (s *Store) ListMessages(ctx context.Context, chat string, beforeTS int64, limit int) ([]*Message, error) {
	if limit <= 0 || limit > 500 {
		limit = 60
	}
	if beforeTS <= 0 {
		beforeTS = 1 << 62
	}
	rows, err := s.DB.QueryContext(ctx, `SELECT `+msgCols+` FROM hermes_messages
		WHERE chat=? AND ts < ? AND type != 'reaction' ORDER BY ts DESC, rowid DESC LIMIT ?`, chat, beforeTS, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []*Message
	for rows.Next() {
		m, err := scanMsg(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, m)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	for i, j := 0, len(out)-1; i < j; i, j = i+1, j-1 {
		out[i], out[j] = out[j], out[i]
	}
	for _, m := range out {
		m.Reactions, _ = s.reactions(ctx, m.Chat, m.ID)
	}
	return out, nil
}

func (s *Store) reactions(ctx context.Context, chat, id string) ([]Reaction, error) {
	rows, err := s.DB.QueryContext(ctx, `SELECT sender, emoji FROM hermes_reactions WHERE chat=? AND msg_id=? ORDER BY ts`, chat, id)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []Reaction{}
	for rows.Next() {
		var r Reaction
		if err := rows.Scan(&r.Sender, &r.Emoji); err != nil {
			return nil, err
		}
		out = append(out, r)
	}
	return out, rows.Err()
}

func (s *Store) SetReaction(ctx context.Context, chat, msgID, sender, emoji string, ts int64) error {
	if emoji == "" {
		_, err := s.DB.ExecContext(ctx, `DELETE FROM hermes_reactions WHERE chat=? AND msg_id=? AND sender=?`, chat, msgID, sender)
		return err
	}
	_, err := s.DB.ExecContext(ctx, `INSERT INTO hermes_reactions (chat, msg_id, sender, emoji, ts) VALUES (?,?,?,?,?)
		ON CONFLICT(chat, msg_id, sender) DO UPDATE SET emoji=excluded.emoji, ts=excluded.ts`, chat, msgID, sender, emoji, ts)
	return err
}

func (s *Store) SetStatus(ctx context.Context, chat string, ids []string, status int) error {
	for _, id := range ids {
		if _, err := s.DB.ExecContext(ctx, `UPDATE hermes_messages SET status=MAX(status, ?) WHERE chat=? AND id=? AND from_me=1`,
			status, chat, id); err != nil {
			return err
		}
	}
	return nil
}

func (s *Store) ForceStatus(ctx context.Context, chat, id string, status int) error {
	_, err := s.DB.ExecContext(ctx, `UPDATE hermes_messages SET status=? WHERE chat=? AND id=?`, status, chat, id)
	return err
}

func (s *Store) EditMessage(ctx context.Context, chat, id, text string) error {
	_, err := s.DB.ExecContext(ctx, `UPDATE hermes_messages SET text=?, edited=1 WHERE chat=? AND id=?`, text, chat, id)
	return err
}

func (s *Store) RevokeMessage(ctx context.Context, chat, id string) error {
	_, err := s.DB.ExecContext(ctx, `UPDATE hermes_messages SET revoked=1, text='', media_path='', thumb_path='' WHERE chat=? AND id=?`, chat, id)
	return err
}

func (s *Store) DeleteMessage(ctx context.Context, chat, id string) error {
	_, err := s.DB.ExecContext(ctx, `DELETE FROM hermes_messages WHERE chat=? AND id=?`, chat, id)
	return err
}

func (s *Store) SetMediaPath(ctx context.Context, chat, id, path string) error {
	_, err := s.DB.ExecContext(ctx, `UPDATE hermes_messages SET media_path=? WHERE chat=? AND id=?`, path, chat, id)
	return err
}

// SetTranscript stores a voice note's transcript as its text (indexed for search) plus its state in extra.
func (s *Store) SetTranscript(ctx context.Context, chat, id, text, extra string) error {
	_, err := s.DB.ExecContext(ctx, `UPDATE hermes_messages SET text=?, extra=? WHERE chat=? AND id=? AND revoked=0`, text, extra, chat, id)
	return err
}

// SetRaw replaces a message's serialized proto (e.g. with a re-uploaded media path).
func (s *Store) SetRaw(ctx context.Context, chat, id string, raw []byte) error {
	_, err := s.DB.ExecContext(ctx, `UPDATE hermes_messages SET raw=? WHERE chat=? AND id=?`, raw, chat, id)
	return err
}

func (s *Store) SetStarred(ctx context.Context, chat, id string, starred bool) error {
	_, err := s.DB.ExecContext(ctx, `UPDATE hermes_messages SET starred=? WHERE chat=? AND id=?`, b2i(starred), chat, id)
	return err
}

type SearchHit struct {
	*Message
	ChatName string `json:"chatName"`
	Snippet  string `json:"snippet"`
}

// Search runs a full-text query across all messages, newest first.
func (s *Store) Search(ctx context.Context, query, chat string, limit int) ([]*SearchHit, error) {
	if limit <= 0 || limit > 200 {
		limit = 50
	}
	// Quote each term so user input can't break FTS syntax; prefix-match the last one.
	terms := strings.Fields(query)
	if len(terms) == 0 {
		return []*SearchHit{}, nil
	}
	for i, t := range terms {
		terms[i] = `"` + strings.ReplaceAll(t, `"`, `""`) + `"`
	}
	terms[len(terms)-1] += "*"
	q := strings.Join(terms, " ")
	sqlq := `SELECT m.chat, m.id, m.sender, m.sender_name, m.from_me, m.ts, m.type, m.text, m.media_mime, m.media_path,
		m.thumb_path, m.media_size, m.media_w, m.media_h, m.media_secs, m.file_name, m.quoted_id, m.quoted_sender,
		m.quoted_text, m.status, m.edited, m.revoked, m.view_once, m.starred, m.extra, m.raw,
		COALESCE(c.name, ''), snippet(hermes_messages_fts, 0, '«', '»', '…', 12)
		FROM hermes_messages_fts f JOIN hermes_messages m ON m.rowid = f.rowid
		LEFT JOIN hermes_chats c ON c.jid = m.chat
		WHERE hermes_messages_fts MATCH ? AND m.revoked = 0`
	args := []any{q}
	if chat != "" {
		sqlq += ` AND m.chat = ?`
		args = append(args, chat)
	}
	sqlq += ` ORDER BY m.ts DESC LIMIT ?`
	args = append(args, limit)
	rows, err := s.DB.QueryContext(ctx, sqlq, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []*SearchHit{}
	for rows.Next() {
		var m Message
		h := &SearchHit{Message: &m}
		if err := rows.Scan(&m.Chat, &m.ID, &m.Sender, &m.SenderName, &m.FromMe, &m.TS, &m.Type, &m.Text, &m.MediaMime,
			&m.MediaPath, &m.ThumbPath, &m.MediaSize, &m.MediaW, &m.MediaH, &m.MediaSecs, &m.FileName, &m.QuotedID,
			&m.QuotedSender, &m.QuotedText, &m.Status, &m.Edited, &m.Revoked, &m.ViewOnce, &m.Starred, &m.Extra, &m.Raw,
			&h.ChatName, &h.Snippet); err != nil {
			return nil, err
		}
		out = append(out, h)
	}
	return out, rows.Err()
}

// Starred returns starred messages (optionally filtered by text), newest first.
func (s *Store) Starred(ctx context.Context, filter string, limit int) ([]*SearchHit, error) {
	if limit <= 0 || limit > 500 {
		limit = 100
	}
	rows, err := s.DB.QueryContext(ctx, `SELECT m.chat, m.id, m.sender, m.sender_name, m.from_me, m.ts, m.type, m.text, m.media_mime,
		m.media_path, m.thumb_path, m.media_size, m.media_w, m.media_h, m.media_secs, m.file_name, m.quoted_id, m.quoted_sender,
		m.quoted_text, m.status, m.edited, m.revoked, m.view_once, m.starred, m.extra, m.raw, COALESCE(c.name, '')
		FROM hermes_messages m LEFT JOIN hermes_chats c ON c.jid = m.chat
		WHERE m.starred = 1 AND m.revoked = 0 AND (? = '' OR m.text LIKE '%' || ? || '%')
		ORDER BY m.ts DESC LIMIT ?`, filter, filter, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []*SearchHit{}
	for rows.Next() {
		var m Message
		h := &SearchHit{Message: &m}
		if err := rows.Scan(&m.Chat, &m.ID, &m.Sender, &m.SenderName, &m.FromMe, &m.TS, &m.Type, &m.Text, &m.MediaMime,
			&m.MediaPath, &m.ThumbPath, &m.MediaSize, &m.MediaW, &m.MediaH, &m.MediaSecs, &m.FileName, &m.QuotedID,
			&m.QuotedSender, &m.QuotedText, &m.Status, &m.Edited, &m.Revoked, &m.ViewOnce, &m.Starred, &m.Extra, &m.Raw,
			&h.ChatName); err != nil {
			return nil, err
		}
		h.Snippet = Preview(&m)
		out = append(out, h)
	}
	return out, rows.Err()
}

// Snooze hides a chat until the given time; msgID optionally points at the message to come back to.
func (s *Store) Snooze(ctx context.Context, jid string, until int64, msgID string) error {
	_, err := s.DB.ExecContext(ctx, `UPDATE hermes_chats SET snooze_until=?, snooze_msg=? WHERE jid=?`, until, msgID, jid)
	return err
}

// DueSnoozes clears expired snoozes and returns the chats that just came back.
// They return flagged unread (local only) so they land in "Needs reply".
func (s *Store) DueSnoozes(ctx context.Context, now int64) ([]*Chat, error) {
	rows, err := s.DB.QueryContext(ctx, `SELECT `+chatCols+` FROM hermes_chats WHERE snooze_until > 0 AND snooze_until <= ?`, now)
	if err != nil {
		return nil, err
	}
	var out []*Chat
	for rows.Next() {
		c, err := scanChat(rows)
		if err != nil {
			rows.Close()
			return nil, err
		}
		out = append(out, c)
	}
	rows.Close()
	for _, c := range out {
		if _, err := s.DB.ExecContext(ctx, `UPDATE hermes_chats SET snooze_until=0, done_ts=0, marked_unread=1 WHERE jid=?`, c.JID); err != nil {
			return nil, err
		}
		s.fillPreview(ctx, c)
	}
	return out, nil
}

// ---- Status ----

// RecentStatuses returns statuses newer than since (oldest first) and which ones you've seen.
func (s *Store) RecentStatuses(ctx context.Context, since int64) ([]*Message, map[string]bool, error) {
	rows, err := s.DB.QueryContext(ctx, `SELECT `+msgCols+` FROM hermes_messages
		WHERE chat='status@broadcast' AND ts > ? AND revoked=0 AND type NOT IN ('reaction','system','unknown')
		ORDER BY ts`, since)
	if err != nil {
		return nil, nil, err
	}
	var out []*Message
	for rows.Next() {
		m, err := scanMsg(rows)
		if err != nil {
			rows.Close()
			return nil, nil, err
		}
		m.Reactions = []Reaction{}
		out = append(out, m)
	}
	rows.Close()
	seen := map[string]bool{}
	srows, err := s.DB.QueryContext(ctx, `SELECT id FROM hermes_status_seen WHERE ts > ?`, since-86400)
	if err != nil {
		return nil, nil, err
	}
	defer srows.Close()
	for srows.Next() {
		var id string
		if srows.Scan(&id) == nil {
			seen[id] = true
		}
	}
	return out, seen, srows.Err()
}

func (s *Store) MarkStatusSeen(ctx context.Context, id string) error {
	_, err := s.DB.ExecContext(ctx, `INSERT INTO hermes_status_seen (id, ts) VALUES (?, ?) ON CONFLICT(id) DO NOTHING`, id, time.Now().Unix())
	return err
}

// ---- Snippets: text you expand with ;trigger in the composer ----

type Snippet struct {
	Trigger string `json:"trigger"`
	Text    string `json:"text"`
}

func (s *Store) Snippets(ctx context.Context) ([]Snippet, error) {
	rows, err := s.DB.QueryContext(ctx, `SELECT name, text FROM hermes_snippets ORDER BY name`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []Snippet{}
	for rows.Next() {
		var sn Snippet
		if err := rows.Scan(&sn.Trigger, &sn.Text); err != nil {
			return nil, err
		}
		out = append(out, sn)
	}
	return out, rows.Err()
}

// SetSnippet creates or replaces a snippet; an empty text deletes it.
func (s *Store) SetSnippet(ctx context.Context, trigger, text string) error {
	trigger = strings.ToLower(strings.TrimLeft(strings.TrimSpace(trigger), ";"))
	if trigger == "" || strings.ContainsAny(trigger, " \t\n;") {
		return errors.New("a snippet name is one word, like addr")
	}
	if strings.TrimSpace(text) == "" {
		_, err := s.DB.ExecContext(ctx, `DELETE FROM hermes_snippets WHERE name=?`, trigger)
		return err
	}
	_, err := s.DB.ExecContext(ctx, `INSERT INTO hermes_snippets (name, text) VALUES (?, ?)
		ON CONFLICT(name) DO UPDATE SET text=excluded.text`, trigger, text)
	return err
}

// UnreadChats lists chats with unread messages.
func (s *Store) UnreadChats(ctx context.Context) ([]string, error) {
	rows, err := s.DB.QueryContext(ctx, `SELECT jid FROM hermes_chats WHERE unread > 0 OR marked_unread = 1`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []string
	for rows.Next() {
		var j string
		if rows.Scan(&j) == nil {
			out = append(out, j)
		}
	}
	return out, rows.Err()
}

func (s *Store) GetKV(ctx context.Context, k string) string {
	var v string
	_ = s.DB.QueryRowContext(ctx, `SELECT v FROM hermes_kv WHERE k=?`, k).Scan(&v)
	return v
}

func (s *Store) SetKV(ctx context.Context, k, v string) error {
	_, err := s.DB.ExecContext(ctx, `INSERT INTO hermes_kv (k, v) VALUES (?, ?) ON CONFLICT(k) DO UPDATE SET v=excluded.v`, k, v)
	return err
}

// MarshalExtra is a helper for the JSON extra column.
func MarshalExtra(v any) string {
	b, err := json.Marshal(v)
	if err != nil {
		return ""
	}
	return string(b)
}
