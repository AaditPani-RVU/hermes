package wa

import (
	"context"
	"database/sql"
	"os"
	"path/filepath"
	"strings"
	"testing"

	waLog "go.mau.fi/whatsmeow/util/log"
	_ "modernc.org/sqlite"

	"github.com/aadit/hermes/daemon/internal/backup"
	hs "github.com/aadit/hermes/daemon/internal/store"
)

// testCore is a Core with a real store and no WhatsApp connection.
func testCore(t *testing.T) *Core {
	t.Helper()
	dir := t.TempDir()
	paths := Paths{Data: filepath.Join(dir, "data"), Cache: filepath.Join(dir, "cache")}
	for _, d := range []string{paths.MediaDir(), paths.TmpDir()} {
		if err := os.MkdirAll(d, 0o700); err != nil {
			t.Fatal(err)
		}
	}
	db, err := sql.Open("sqlite", "file:"+filepath.Join(paths.Data, "hermes.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { db.Close() })
	st, err := hs.Open(context.Background(), db)
	if err != nil {
		t.Fatal(err)
	}
	return &Core{Log: waLog.Noop, Paths: paths, Store: st, Emit: func(string, any) {}}
}

func addMsg(t *testing.T, c *Core, m *hs.Message) {
	t.Helper()
	if _, err := c.Store.UpsertMessage(context.Background(), m); err != nil {
		t.Fatal(err)
	}
}

func TestExportChat(t *testing.T) {
	ctx := context.Background()
	c := testCore(t)
	out := t.TempDir()
	_ = c.Store.SetKV(ctx, "export_dir", out)
	chat := "1203@g.us"
	_ = c.Store.EnsureChat(ctx, chat, true)
	_ = c.Store.SetChatName(ctx, chat, "College / CS")

	img := filepath.Join(c.Paths.MediaDir(), "pic.jpg")
	_ = os.WriteFile(img, []byte("jpegdata"), 0o600)
	addMsg(t, c, &hs.Message{Chat: chat, ID: "a", Sender: "1@s.whatsapp.net", SenderName: "Asha", TS: 1760000000, Type: "text", Text: "# not a heading\nsee [[x]]"})
	addMsg(t, c, &hs.Message{Chat: chat, ID: "b", FromMe: true, TS: 1760000100, Type: "image", Text: "notes", MediaPath: img})
	addMsg(t, c, &hs.Message{Chat: chat, ID: "c", Sender: "1@s.whatsapp.net", SenderName: "Asha", TS: 1760090000, Type: "document", FileName: "syllabus.pdf"})
	_ = c.Store.SetReaction(ctx, chat, "a", "2@s.whatsapp.net", "👍", 1760000001)

	res, err := c.ExportChat(ctx, chat, ExportOpts{})
	if err != nil {
		t.Fatal(err)
	}
	if res.Messages != 3 || res.Media != 1 || res.Missing != 1 {
		t.Fatalf("result %+v", res)
	}
	if filepath.Base(res.Path) != "College _ CS.md" {
		t.Fatalf("path %s", res.Path)
	}
	b, _ := os.ReadFile(res.Path)
	md := string(b)
	for _, want := range []string{
		"whatsapp: 1203@g.us", `chat: "College / CS"`, "· Asha:** \\# not a heading", `\[\[x]]`, "· 👍",
		"· You:**\n![](<attachments/College _ CS/pic.jpg>)\nnotes", "📄 *(syllabus.pdf, not downloaded)*",
	} {
		if !strings.Contains(md, want) {
			t.Errorf("missing %q in:\n%s", want, md)
		}
	}
	if _, err := os.Stat(filepath.Join(out, "attachments", "College _ CS", "pic.jpg")); err != nil {
		t.Error("attachment not copied")
	}

	// A different chat with the same name must not overwrite it.
	other := "999@g.us"
	_ = c.Store.EnsureChat(ctx, other, true)
	_ = c.Store.SetChatName(ctx, other, "College / CS")
	res2, err := c.ExportChat(ctx, other, ExportOpts{})
	if err != nil {
		t.Fatal(err)
	}
	if res2.Path == res.Path {
		t.Fatal("second chat overwrote the first export")
	}
}

func TestFileRuleMatch(t *testing.T) {
	pdf := &hs.Message{Chat: "a@g.us", Type: "document", FileName: "Lab Manual.PDF", MediaMime: "application/pdf"}
	voice := &hs.Message{Chat: "a@g.us", Type: "voice", MediaMime: "audio/ogg"}
	cases := []struct {
		r    FileRule
		m    *hs.Message
		want bool
	}{
		{FileRule{Chat: "a@g.us", Ext: "pdf"}, pdf, true},
		{FileRule{Chat: "b@g.us", Ext: "pdf"}, pdf, false},
		{FileRule{Kind: "image"}, pdf, false},
		{FileRule{Kind: "document", Match: "manual"}, pdf, true},
		{FileRule{Match: "invoice"}, pdf, false},
		{FileRule{Kind: "audio"}, voice, true},
		{FileRule{Ext: "ogg,mp3"}, voice, true},
	}
	for i, tc := range cases {
		if got := tc.r.matches(tc.m); got != tc.want {
			t.Errorf("case %d: got %v", i, got)
		}
	}
}

func TestBackupRoundTrip(t *testing.T) {
	ctx := context.Background()
	c := testCore(t)
	_ = c.Store.SetKV(ctx, "backup_dir", t.TempDir())
	_ = c.Store.SetKV(ctx, "marker", "hello")
	media := filepath.Join(c.Paths.MediaDir(), "chat", "x.jpg")
	_ = os.MkdirAll(filepath.Dir(media), 0o700)
	_ = os.WriteFile(media, []byte("img"), 0o600)

	if _, err := c.Backup(ctx, "short", false); err == nil {
		t.Fatal("short passphrase accepted")
	}
	res, err := c.Backup(ctx, "correct horse battery", true)
	if err != nil {
		t.Fatal(err)
	}
	if res.Files != 2 {
		t.Fatalf("files %d", res.Files)
	}
	if _, err := backup.Extract(res.Path, "wrong passphrase", filepath.Join(t.TempDir(), "x")); err == nil {
		t.Fatal("wrong passphrase decrypted")
	}
	dst := filepath.Join(t.TempDir(), "restore")
	names, err := backup.Extract(res.Path, "correct horse battery", dst)
	if err != nil {
		t.Fatal(err)
	}
	if len(names) != 2 {
		t.Fatalf("names %v", names)
	}
	db, err := sql.Open("sqlite", "file:"+filepath.Join(dst, "hermes.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	var v string
	if err := db.QueryRow(`SELECT v FROM hermes_kv WHERE k='marker'`).Scan(&v); err != nil || v != "hello" {
		t.Fatalf("restored kv %q %v", v, err)
	}
	if b, _ := os.ReadFile(filepath.Join(dst, "media", "chat", "x.jpg")); string(b) != "img" {
		t.Fatal("media not restored")
	}
}

func TestCleanMedia(t *testing.T) {
	ctx := context.Background()
	c := testCore(t)
	chat := "1@s.whatsapp.net"
	keep := filepath.Join(c.Paths.MediaDir(), "star.jpg")
	drop := filepath.Join(c.Paths.MediaDir(), "old.jpg")
	outside := filepath.Join(t.TempDir(), "filed.jpg")
	for _, p := range []string{keep, drop, outside} {
		_ = os.WriteFile(p, []byte("12345"), 0o600)
	}
	addMsg(t, c, &hs.Message{Chat: chat, ID: "s", TS: 1, Type: "image", MediaPath: keep, Starred: true})
	addMsg(t, c, &hs.Message{Chat: chat, ID: "d", TS: 1, Type: "image", MediaPath: drop})
	addMsg(t, c, &hs.Message{Chat: chat, ID: "o", TS: 1, Type: "image", MediaPath: outside})

	dry, _ := c.CleanMedia(ctx, CleanOpts{DryRun: true})
	if dry.Files != 1 || !fileExists(drop) {
		t.Fatalf("dry run %+v", dry)
	}
	res, err := c.CleanMedia(ctx, CleanOpts{OlderThan: 30})
	if err != nil || res.Files != 1 || res.Bytes != 5 {
		t.Fatalf("clean %+v %v", res, err)
	}
	if fileExists(drop) || !fileExists(keep) || !fileExists(outside) {
		t.Fatal("wrong files removed")
	}
	if m, _ := c.Store.GetMessage(ctx, chat, "d"); m.MediaPath != "" {
		t.Fatal("media_path not cleared")
	}
}
