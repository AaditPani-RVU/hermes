package wa

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"sync"
	"time"

	hs "github.com/aadit/hermes/daemon/internal/store"
)

// ---- Digest notifications ----
//
// For busy chats you pick, Hermes holds notifications and sends one roundup every N minutes
// instead of a ping per message. Mentions and replies to you still notify straight away.
// kv digest_chats = {"jid": minutes}; kv digest_ai = "on" adds a one-line gist from the local LLM.

type digestBatch struct {
	first   time.Time
	count   int
	senders []string
	lines   []string // "Name: preview", newest last, capped
}

type digestState struct {
	mu      sync.Mutex
	batches map[string]*digestBatch
}

const digestLines = 60

func (c *Core) DigestChats(ctx context.Context) map[string]int {
	out := map[string]int{}
	_ = json.Unmarshal([]byte(c.Store.GetKV(ctx, "digest_chats")), &out)
	return out
}

// SetDigest turns digest notifications on for a chat (minutes > 0) or off (0).
func (c *Core) SetDigest(ctx context.Context, chat string, minutes int) error {
	d := c.DigestChats(ctx)
	if minutes <= 0 {
		delete(d, chat)
		c.flushDigest(ctx, chat, true)
	} else {
		d[chat] = max(5, minutes)
	}
	b, _ := json.Marshal(d)
	if err := c.Store.SetKV(ctx, "digest_chats", string(b)); err != nil {
		return err
	}
	c.emitChat(ctx, chat)
	return nil
}

// holdForDigest queues a message for the chat's next digest instead of notifying now.
func (c *Core) holdForDigest(ctx context.Context, ch *hs.Chat, m *hs.Message) bool {
	if m.MentionsMe || c.DigestChats(ctx)[ch.JID] == 0 {
		return false
	}
	name := hs.ShortName(m.SenderName)
	if name == "" {
		name = strings.SplitN(m.Sender, "@", 2)[0]
	}
	c.digest.mu.Lock()
	defer c.digest.mu.Unlock()
	if c.digest.batches == nil {
		c.digest.batches = map[string]*digestBatch{}
	}
	b := c.digest.batches[ch.JID]
	if b == nil {
		b = &digestBatch{first: time.Now()}
		c.digest.batches[ch.JID] = b
	}
	b.count++
	found := false
	for _, s := range b.senders {
		found = found || s == name
	}
	if !found {
		b.senders = append(b.senders, name)
	}
	b.lines = append(b.lines, name+": "+oneLine(hs.Preview(m), 200))
	if len(b.lines) > digestLines {
		b.lines = b.lines[len(b.lines)-digestLines:]
	}
	return true
}

// clearDigest drops a pending digest (the chat was read).
func (c *Core) clearDigest(chat string) {
	c.digest.mu.Lock()
	delete(c.digest.batches, chat)
	c.digest.mu.Unlock()
}

func (c *Core) digestLoop(ctx context.Context) {
	t := time.NewTicker(30 * time.Second)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			mins := c.DigestChats(ctx)
			c.digest.mu.Lock()
			var due []string
			for jid, b := range c.digest.batches {
				if m := mins[jid]; m == 0 || time.Since(b.first) >= time.Duration(m)*time.Minute {
					due = append(due, jid)
				}
			}
			c.digest.mu.Unlock()
			for _, jid := range due {
				c.flushDigest(ctx, jid, false)
			}
		}
	}
}

// flushDigest sends (or with drop, discards) a chat's pending digest.
func (c *Core) flushDigest(ctx context.Context, jid string, drop bool) {
	c.digest.mu.Lock()
	b := c.digest.batches[jid]
	delete(c.digest.batches, jid)
	c.digest.mu.Unlock()
	if b == nil || drop || c.Notify == nil {
		return
	}
	ch, _ := c.GetChat(ctx, jid)
	if ch == nil || ch.Unread == 0 || ch.MutedUntil > time.Now().Unix() {
		return // read or muted in the meantime
	}
	summary := fmt.Sprintf("%s · %d new", ch.Name, b.count)
	who := strings.Join(b.senders, ", ")
	if len(b.senders) > 3 {
		who = fmt.Sprintf("%s and %d others", strings.Join(b.senders[:3], ", "), len(b.senders)-3)
	}
	body := "From " + who
	if c.Store.GetKV(ctx, "digest_ai") == "on" {
		gctx, cancel := context.WithTimeout(ctx, 45*time.Second)
		gist, err := c.llmChat(gctx,
			"You write one-sentence notification summaries of WhatsApp group messages, in English, at most 25 words. "+
				"Say what happened, not who said hello. Reply with only the sentence.",
			strings.Join(b.lines, "\n"), 80, nil)
		cancel()
		if err == nil && gist != "" {
			c.Notify.NotifyDigest(ch, summary, gist+"\n"+body)
			return
		}
		c.Log.Warnf("digest gist: %v", err)
	}
	last := b.lines
	if len(last) > 3 {
		last = last[len(last)-3:]
	}
	c.Notify.NotifyDigest(ch, summary, body+"\n"+strings.Join(last, "\n"))
}
