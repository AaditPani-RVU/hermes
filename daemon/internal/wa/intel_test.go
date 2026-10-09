package wa

import (
	"context"
	"strings"
	"testing"

	hs "github.com/aadit/hermes/daemon/internal/store"
)

func TestPickModel(t *testing.T) {
	models := []string{"qwen3:8b", "gemma3:4b", "nomic-embed-text:latest"}
	if got := pickModel("", models); got != "gemma3:4b" {
		t.Errorf("auto pick %q", got)
	}
	if got := pickModel("qwen3:8b", models); got != "qwen3:8b" {
		t.Errorf("chosen %q", got)
	}
	if got := pickModel("missing:1b", models); got != "gemma3:4b" {
		t.Errorf("missing chosen should fall back, got %q", got)
	}
	if got := pickModel("", []string{"nomic-embed-text:latest", "mistral:7b"}); got != "mistral:7b" {
		t.Errorf("fallback %q", got)
	}
	if got := pickModel("", nil); got != "" {
		t.Errorf("empty %q", got)
	}
}

func TestCleanLLM(t *testing.T) {
	if got := cleanLLM("<think>hmm</think>\n Hello "); got != "Hello" {
		t.Errorf("%q", got)
	}
	if got := cleanLLM("Hi <think>still going"); got != "Hi" {
		t.Errorf("%q", got)
	}
}

func TestChatTranscript(t *testing.T) {
	ch := &hs.Chat{JID: "1@s.whatsapp.net", Name: "Maya"}
	msgs := []*hs.Message{
		{TS: 1760000000, Type: "text", Text: "kal milte hain?", Sender: "1@s.whatsapp.net", SenderName: "maya_x"},
		{TS: 1760000060, Type: "text", Text: "yes\n6 baje", FromMe: true, QuotedText: "kal milte hain?"},
		{TS: 1760000100, Type: "text", Text: "gone", Revoked: true},
		{TS: 1760000120, Type: "image", Text: ""},
	}
	tr := chatTranscript(msgs, ch)
	for _, want := range []string{"] Maya: kal milte hain?", "] You: (replying to \"kal milte hain?\") yes 6 baje", "] Maya: 📷 Photo"} {
		if !strings.Contains(tr, want) {
			t.Errorf("missing %q in\n%s", want, tr)
		}
	}
	if strings.Contains(tr, "gone") {
		t.Error("revoked message included")
	}
}

type fakeNotifier struct{ digests []string }

func (f *fakeNotifier) NotifyMessage(*hs.Chat, *hs.Message)     {}
func (f *fakeNotifier) NotifyCall(string, bool)                 {}
func (f *fakeNotifier) NotifyReminder(*hs.Chat, string)         {}
func (f *fakeNotifier) NotifySystem(string, string)             {}
func (f *fakeNotifier) Dismiss(string)                          {}
func (f *fakeNotifier) NotifyDigest(_ *hs.Chat, s, body string) { f.digests = append(f.digests, s+"|"+body) }

func TestDigest(t *testing.T) {
	ctx := context.Background()
	c := testCore(t)
	n := &fakeNotifier{}
	c.Notify = n
	chat := "555@g.us"
	_ = c.Store.EnsureChat(ctx, chat, true)
	_ = c.Store.SetChatName(ctx, chat, "Hostel")
	ch, _ := c.GetChat(ctx, chat)

	msg := func(name, text string, mention bool) *hs.Message {
		return &hs.Message{Chat: chat, Sender: name + "@s.whatsapp.net", SenderName: name, Type: "text", Text: text, MentionsMe: mention}
	}
	if c.holdForDigest(ctx, ch, msg("Ravi", "hi", false)) {
		t.Fatal("held without digest mode")
	}
	if err := c.SetDigest(ctx, chat, 30); err != nil {
		t.Fatal(err)
	}
	for _, who := range []string{"Ravi", "Asha", "Ravi", "Kiran", "Dev"} {
		if !c.holdForDigest(ctx, ch, msg(who, "msg from "+who, false)) {
			t.Fatal("not held")
		}
	}
	if c.holdForDigest(ctx, ch, msg("Asha", "@you", true)) {
		t.Fatal("mention was held")
	}
	_ = c.Store.SetChatField(ctx, chat, "unread", 5)
	c.flushDigest(ctx, chat, false)
	if len(n.digests) != 1 {
		t.Fatalf("digests %v", n.digests)
	}
	d := n.digests[0]
	for _, want := range []string{"Hostel · 5 new", "From Ravi, Asha, Kiran and 1 others", "Dev: msg from Dev"} {
		if !strings.Contains(d, want) {
			t.Errorf("missing %q in %q", want, d)
		}
	}
	// Reading the chat drops a pending digest.
	c.holdForDigest(ctx, ch, msg("Ravi", "again", false))
	c.clearDigest(chat)
	c.flushDigest(ctx, chat, false)
	if len(n.digests) != 1 {
		t.Fatal("digest sent after the chat was read")
	}
}

func TestOCRSearch(t *testing.T) {
	ctx := context.Background()
	c := testCore(t)
	chat := "1@s.whatsapp.net"
	_ = c.Store.EnsureChat(ctx, chat, false)
	addMsg(t, c, &hs.Message{Chat: chat, ID: "img", TS: 100, Type: "image", MediaPath: "/x.jpg"})
	addMsg(t, c, &hs.Message{Chat: chat, ID: "txt", TS: 200, Type: "text", Text: "invoice attached"})
	if todo, _ := c.Store.UnscannedImages(ctx, 10); len(todo) != 1 {
		t.Fatalf("unscanned %v", todo)
	}
	_ = c.Store.SetOCR(ctx, chat, "img", "TAX INVOICE\nTotal 1,240")
	if todo, _ := c.Store.UnscannedImages(ctx, 10); len(todo) != 0 {
		t.Fatalf("still unscanned %v", todo)
	}
	hits, err := c.Store.Search(ctx, "invoice", "", 10)
	if err != nil {
		t.Fatal(err)
	}
	if len(hits) != 2 || hits[0].ID != "txt" || hits[1].ID != "img" || !strings.HasPrefix(hits[1].Snippet, "🔍") {
		for _, h := range hits {
			t.Logf("%s %q", h.ID, h.Snippet)
		}
		t.Fatal("unexpected hits")
	}
}
