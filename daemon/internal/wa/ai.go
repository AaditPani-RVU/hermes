package wa

import (
	"context"
	"errors"
	"fmt"
	"regexp"
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
		"Start directly with the first heading, no preamble. Use these sections, leaving out any that would be empty:\n" +
		"**Gist**: one or two sentences.\n" +
		"**For you**: only messages that name " + me + ", @-mention them, or reply to something \"You\" wrote. " +
		"General questions to the group are not for you. Say who asked.\n" +
		"**Plans & dates**: things actually scheduled, with day and time.\n" +
		"**Decisions**: what was agreed.\n" +
		"Short bullet points under each heading. Lines from \"You\" were written by " + me + "."
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

var linkRe = regexp.MustCompile(`https?://(?:www\.)?([^/\s]+)\S*`)

// shortLinks turns URLs into "[link: instagram.com]": the model gets the gist for a few tokens.
func shortLinks(s string) string { return linkRe.ReplaceAllString(s, "[link: $1]") }

// chatTranscript renders messages compactly for a prompt: reading the prompt is most of the time a
// summary takes on a small GPU, so every token counts. Consecutive messages from one person are joined
// with " / ", first names only, and a time only after a gap of 20+ minutes.
//
//	--- Fri 9 Oct ---
//	[18:02] Ravi: kal ka plan? / library at 6
//	Asha: done
func chatTranscript(msgs []*hs.Message, ch *hs.Chat) string {
	var sb strings.Builder
	var day, last string
	var lastTS int64
	for _, m := range msgs {
		if m.Revoked || m.Type == "system" || m.Type == "call" {
			continue
		}
		text := shortLinks(hs.Preview(m))
		if text == "" {
			continue
		}
		if r := []rune(text); len(r) > 300 {
			text = string(r[:300]) + "…"
		}
		if m.QuotedText != "" {
			text = "(re \"" + oneLine(m.QuotedText, 40) + "\") " + text
		}
		t := time.Unix(m.TS, 0)
		who := hs.ShortName(m.SenderName)
		switch {
		case m.FromMe:
			who = "You"
		case !ch.IsGroup:
			who = hs.ShortName(ch.Name)
		case who == "":
			who = strings.SplitN(m.Sender, "@", 2)[0]
		}
		newDay := t.Format("Mon 2 Jan") != day
		gap := m.TS-lastTS >= 20*60
		if who == last && !newDay && !gap {
			sb.WriteString(" / " + text)
			lastTS = m.TS
			continue
		}
		if sb.Len() > 0 {
			sb.WriteByte('\n')
		}
		if newDay {
			day = t.Format("Mon 2 Jan")
			fmt.Fprintf(&sb, "--- %s ---\n", day)
		}
		if newDay || gap {
			fmt.Fprintf(&sb, "[%s] ", t.Format("15:04"))
		}
		sb.WriteString(who + ": " + text)
		last, lastTS = who, m.TS
	}
	if sb.Len() > 0 {
		sb.WriteByte('\n')
	}
	return sb.String()
}
