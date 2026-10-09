package wa

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"time"

	hs "github.com/aadit/hermes/daemon/internal/store"
)

// ---- On-demand translation and catch-up summaries (local LLM, see llm.go) ----

func (c *Core) translateLang(ctx context.Context) string {
	if l := c.Store.GetKV(ctx, "translate_lang"); l != "" {
		return l
	}
	return "English"
}

// Translate returns a message's text in lang ("" = the configured language), cached per message.
func (c *Core) Translate(ctx context.Context, chat, id, lang string) (map[string]string, error) {
	if lang == "" {
		lang = c.translateLang(ctx)
	}
	m, err := c.Store.GetMessage(ctx, chat, id)
	if err != nil || m == nil {
		return nil, errors.New("message not found")
	}
	text := strings.TrimSpace(m.Text)
	if m.Type == "image" && text == "" {
		text, _ = c.Store.OCR(ctx, chat, id)
	}
	if text == "" || m.Revoked {
		return nil, errors.New("nothing to translate")
	}
	if t := c.Store.Translation(ctx, chat, id, lang); t != "" {
		return map[string]string{"text": t, "lang": lang}, nil
	}
	system := "You translate WhatsApp messages into " + lang + ". Reply with only the translation: no quotes, notes or explanations. " +
		"Keep names, emojis, numbers and the tone (casual stays casual). Messages may mix languages or use romanised Hindi, " +
		"Kannada, Tamil etc. (\"haan bhai kal milte hain\"); translate their meaning. If it is already entirely in " + lang + ", reply with it unchanged."
	out, err := c.llmChat(ctx, system, text, 600, nil)
	if err != nil {
		return nil, err
	}
	out = strings.Trim(out, "\"“” \n")
	_ = c.Store.SetTranslation(ctx, chat, id, lang, out)
	return map[string]string{"text": out, "lang": lang}, nil
}

const summaryMax = 400

// Summarize condenses a chat's recent messages. scope "unread" covers the unread ones (plus a little context);
// otherwise the last n. Progress streams as "summary" events tagged with token.
func (c *Core) Summarize(ctx context.Context, chat, scope string, n int, token string) (string, error) {
	ch, err := c.GetChat(ctx, chat)
	if err != nil || ch == nil {
		return "", errors.New("chat not found")
	}
	if scope == "unread" {
		n = ch.Unread + 10
		if ch.Unread == 0 {
			n = 60
		}
	}
	if n <= 0 {
		n = 150
	}
	n = min(n, summaryMax)
	msgs, err := c.Store.ListMessages(ctx, chat, 0, n)
	if err != nil {
		return "", err
	}
	transcript := chatTranscript(msgs, ch)
	if transcript == "" {
		return "", errors.New("no messages to summarise")
	}
	me := c.Status().MeName
	if me == "" {
		me = "the user"
	}
	kind := "a group chat"
	if !ch.IsGroup {
		kind = "a one-to-one chat with " + ch.Name
	}
	system := "You summarise WhatsApp chats for " + me + ", who reads your summary instead of scrolling. " +
		"Write in English even if the chat mixes languages. Be brief and concrete; never invent anything. " +
		"Use these sections, skipping any that would be empty:\n" +
		"**Gist**: one or two sentences.\n" +
		"**For you**: questions, requests or mentions aimed at " + me + " (say who).\n" +
		"**Plans & dates**: anything scheduled, with day and time.\n" +
		"**Decisions**: what was agreed.\n" +
		"Use short bullet points under each heading. Messages from \"You\" were written by " + me + "."
	prompt := fmt.Sprintf("%s: \"%s\". %d messages, oldest first:\n\n%s", kind, ch.Name, len(msgs), transcript)
	emit := func(text string, done bool) {
		c.Emit("summary", map[string]any{"token": token, "chat": chat, "text": text, "done": done})
	}
	out, err := c.llmChat(ctx, system, prompt, 700, func(s string) { emit(s, false) })
	if err != nil {
		return "", err
	}
	emit(out, true)
	return out, nil
}

// chatTranscript renders messages as "[Fri 18:02] Name: text" lines for a prompt.
func chatTranscript(msgs []*hs.Message, ch *hs.Chat) string {
	var sb strings.Builder
	var day string
	for _, m := range msgs {
		if m.Revoked || m.Type == "system" || m.Type == "call" {
			continue
		}
		text := hs.Preview(m)
		if text == "" {
			continue
		}
		if r := []rune(text); len(r) > 400 {
			text = string(r[:400]) + "…"
		}
		t := time.Unix(m.TS, 0)
		if d := t.Format("Mon 2 Jan"); d != day {
			day = d
			fmt.Fprintf(&sb, "--- %s ---\n", d)
		}
		who := m.SenderName
		switch {
		case m.FromMe:
			who = "You"
		case !ch.IsGroup:
			who = ch.Name
		case who == "":
			who = strings.SplitN(m.Sender, "@", 2)[0]
		}
		if m.QuotedText != "" {
			text = "(replying to \"" + oneLine(m.QuotedText, 60) + "\") " + text
		}
		fmt.Fprintf(&sb, "[%s] %s: %s\n", t.Format("15:04"), who, strings.ReplaceAll(text, "\n", " / "))
	}
	return sb.String()
}
