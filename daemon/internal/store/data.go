package store

import (
	"context"
	"os"
)

// EachMessage calls fn for every displayable message in a chat at or after since, oldest first,
// with reactions filled in. Used by export, so it streams instead of loading the chat into memory.
func (s *Store) EachMessage(ctx context.Context, chat string, since int64, fn func(*Message) error) error {
	reacts, err := s.chatReactions(ctx, chat)
	if err != nil {
		return err
	}
	rows, err := s.DB.QueryContext(ctx, `SELECT `+msgCols+` FROM hermes_messages
		WHERE chat=? AND ts >= ? AND type != 'reaction' ORDER BY ts, rowid`, chat, since)
	if err != nil {
		return err
	}
	defer rows.Close()
	for rows.Next() {
		m, err := scanMsg(rows)
		if err != nil {
			return err
		}
		m.Reactions = reacts[m.ID]
		if err := fn(m); err != nil {
			return err
		}
	}
	return rows.Err()
}

func (s *Store) chatReactions(ctx context.Context, chat string) (map[string][]Reaction, error) {
	rows, err := s.DB.QueryContext(ctx, `SELECT msg_id, sender, emoji FROM hermes_reactions WHERE chat=? ORDER BY ts`, chat)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := map[string][]Reaction{}
	for rows.Next() {
		var id string
		var r Reaction
		if err := rows.Scan(&id, &r.Sender, &r.Emoji); err != nil {
			return nil, err
		}
		out[id] = append(out[id], r)
	}
	return out, rows.Err()
}

// MediaFile is a downloaded attachment, as seen by the storage stats and cleanup.
type MediaFile struct {
	Chat    string
	ID      string
	Path    string
	TS      int64
	Starred bool
}

// EachMedia calls fn for every message with a local media path.
func (s *Store) EachMedia(ctx context.Context, fn func(MediaFile) error) error {
	rows, err := s.DB.QueryContext(ctx, `SELECT chat, id, media_path, ts, starred FROM hermes_messages WHERE media_path != ''`)
	if err != nil {
		return err
	}
	defer rows.Close()
	var files []MediaFile
	for rows.Next() {
		var f MediaFile
		if err := rows.Scan(&f.Chat, &f.ID, &f.Path, &f.TS, &f.Starred); err != nil {
			return err
		}
		files = append(files, f)
	}
	if err := rows.Err(); err != nil {
		return err
	}
	// Closed before fn runs, so fn may write (cleanup clears media_path).
	rows.Close()
	for _, f := range files {
		if err := fn(f); err != nil {
			return err
		}
	}
	return nil
}

// MessageCounts returns the number of stored messages per chat.
func (s *Store) MessageCounts(ctx context.Context) (map[string]int, error) {
	rows, err := s.DB.QueryContext(ctx, `SELECT chat, COUNT(*) FROM hermes_messages WHERE type != 'reaction' GROUP BY chat`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := map[string]int{}
	for rows.Next() {
		var chat string
		var n int
		if err := rows.Scan(&chat, &n); err != nil {
			return nil, err
		}
		out[chat] = n
	}
	return out, rows.Err()
}

// Snapshot writes a consistent copy of the whole database (Hermes and whatsmeow tables) to path.
func (s *Store) Snapshot(ctx context.Context, path string) error {
	_ = os.Remove(path)
	_, err := s.DB.ExecContext(ctx, `VACUUM INTO ?`, path)
	return err
}
