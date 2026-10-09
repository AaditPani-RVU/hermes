// hermesd is the Hermes background daemon: it owns the WhatsApp connection and
// serves the UI and CLI over a Unix socket.
package main

import (
	"context"
	"database/sql"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	waLog "go.mau.fi/whatsmeow/util/log"
	_ "modernc.org/sqlite"

	"github.com/aadit/hermes/daemon/internal/notify"
	"github.com/aadit/hermes/daemon/internal/rpc"
	hs "github.com/aadit/hermes/daemon/internal/store"
	"github.com/aadit/hermes/daemon/internal/wa"
)

func envOr(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

func SocketPath() string {
	return filepath.Join(envOr("XDG_RUNTIME_DIR", os.TempDir()), "hermes.sock")
}

func main() {
	home, _ := os.UserHomeDir()
	dataDir := flag.String("data", filepath.Join(envOr("XDG_DATA_HOME", filepath.Join(home, ".local/share")), "hermes"), "data directory")
	cacheDir := flag.String("cache", filepath.Join(envOr("XDG_CACHE_HOME", filepath.Join(home, ".cache")), "hermes"), "cache directory")
	sock := flag.String("socket", SocketPath(), "RPC socket path")
	logLevel := flag.String("log", "INFO", "log level (DEBUG, INFO, WARN, ERROR)")
	flag.Parse()

	log := waLog.Stdout("hermes", strings.ToUpper(*logLevel), false)
	if err := run(log, *dataDir, *cacheDir, *sock); err != nil {
		log.Errorf("%v", err)
		os.Exit(1)
	}
}

func run(log waLog.Logger, dataDir, cacheDir, sock string) error {
	for _, d := range []string{dataDir, cacheDir} {
		if err := os.MkdirAll(d, 0o700); err != nil {
			return err
		}
	}
	dsn := "file:" + filepath.Join(dataDir, "hermes.db") +
		"?_pragma=foreign_keys(1)&_pragma=journal_mode(WAL)&_pragma=busy_timeout(10000)&_pragma=synchronous(NORMAL)"
	db, err := sql.Open("sqlite", dsn)
	if err != nil {
		return err
	}
	defer db.Close()
	ctx, cancel := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer cancel()

	st, err := hs.Open(ctx, db)
	if err != nil {
		return err
	}
	core, err := wa.New(log, wa.Paths{Data: dataDir, Cache: cacheDir}, db, st)
	if err != nil {
		return err
	}
	srv := rpc.New(log.Sub("RPC"))
	core.Emit = srv.Broadcast

	openUI := func(chat string) {
		if srv.UIConnected() {
			srv.Broadcast("ui.open", map[string]string{"chat": chat})
			return
		}
		cmd := exec.Command("hermes-ui")
		cmd.Env = append(os.Environ(), "HERMES_OPEN_CHAT="+chat)
		if err := cmd.Start(); err != nil {
			log.Warnf("launch hermes-ui: %v", err)
			return
		}
		go func() { _ = cmd.Wait() }()
	}

	// Quick reply: a small Hermes window with the last few messages and a text box.
	quickReply := func(chat string) {
		if srv.UIConnected() {
			srv.Broadcast("ui.quickReply", map[string]string{"chat": chat})
			return
		}
		cmd := exec.Command("hermes-ui")
		cmd.Env = append(os.Environ(), "HERMES_QUICK_REPLY="+chat)
		if err := cmd.Start(); err != nil {
			log.Warnf("launch hermes-ui: %v", err)
			return
		}
		go func() { _ = cmd.Wait() }()
	}

	if n, err := notify.New(); err != nil {
		log.Warnf("Desktop notifications unavailable: %v", err)
	} else {
		n.OnOpen = openUI
		// Drop notify-icon.png or .svg into the data dir to use your own logo.
		home, _ := os.UserHomeDir()
		n.Icons = []string{
			filepath.Join(dataDir, "notify-icon.png"),
			filepath.Join(dataDir, "notify-icon.svg"),
			filepath.Join(home, ".local/share/icons/hicolor/scalable/apps/hermes-notify.svg"),
			filepath.Join(home, ".local/share/icons/hicolor/scalable/apps/hermes.svg"),
		}
		n.OnMarkRead = func(chat string) { _ = core.MarkRead(context.Background(), chat) }
		n.OnQuickReply = quickReply
		n.OnReply = func(chat, text string) {
			bg := context.Background()
			if _, err := core.SendText(bg, chat, text, wa.SendOpts{}); err != nil {
				n.NotifySystem("Reply not sent", err.Error())
				return
			}
			_ = core.MarkRead(bg, chat)
		}
		n.Quiet = func(chat string) bool { return focusBlocks(ctx, st, chat) }
		core.Notify = n
	}

	registerMethods(srv, core, st, openUI)

	go func() {
		if err := srv.Serve(ctx, sock); err != nil {
			log.Errorf("RPC server: %v", err)
			cancel()
		}
	}()
	log.Infof("Listening on %s", sock)
	return core.Start(ctx)
}

// focusBlocks reports whether focus mode should silence this chat (VIPs always get through).
func focusBlocks(ctx context.Context, st *hs.Store, chat string) bool {
	until := st.GetKV(ctx, "focus_until")
	if until == "" || until == "0" {
		return false
	}
	var ts int64
	fmt.Sscan(until, &ts)
	if ts > 0 && time.Now().Unix() > ts {
		return false
	}
	var vips []string
	_ = json.Unmarshal([]byte(st.GetKV(ctx, "vips")), &vips)
	for _, v := range vips {
		if v == chat {
			return false
		}
	}
	return true
}

type chatParam struct {
	Chat string `json:"chat"`
}

type msgParam struct {
	Chat string `json:"chat"`
	ID   string `json:"id"`
}

func registerMethods(srv *rpc.Server, core *wa.Core, st *hs.Store, openUI func(string)) {
	h := func(name string, fn rpc.Handler) { srv.Register(name, fn) }

	h("status", func(ctx context.Context, _ json.RawMessage) (any, error) { return core.Status(), nil })
	h("auth.pairPhone", func(ctx context.Context, raw json.RawMessage) (any, error) {
		p, err := rpc.Bind[struct{ Phone string }](raw)
		if err != nil {
			return nil, err
		}
		return core.PairPhone(ctx, p.Phone)
	})
	h("auth.logout", func(ctx context.Context, _ json.RawMessage) (any, error) { return nil, core.Logout(ctx) })

	// Chats
	h("chats.list", func(ctx context.Context, raw json.RawMessage) (any, error) {
		p, err := rpc.Bind[struct{ Archived bool }](raw)
		if err != nil {
			return nil, err
		}
		return core.ListChats(ctx, p.Archived)
	})
	h("chats.get", func(ctx context.Context, raw json.RawMessage) (any, error) {
		p, err := rpc.Bind[chatParam](raw)
		if err != nil {
			return nil, err
		}
		return core.GetChat(ctx, p.Chat)
	})
	h("chats.markRead", func(ctx context.Context, raw json.RawMessage) (any, error) {
		p, err := rpc.Bind[chatParam](raw)
		if err != nil {
			return nil, err
		}
		return nil, core.MarkRead(ctx, p.Chat)
	})
	h("chats.markUnread", func(ctx context.Context, raw json.RawMessage) (any, error) {
		p, err := rpc.Bind[chatParam](raw)
		if err != nil {
			return nil, err
		}
		return nil, core.MarkUnread(ctx, p.Chat)
	})
	h("chats.archive", func(ctx context.Context, raw json.RawMessage) (any, error) {
		p, err := rpc.Bind[struct {
			Chat  string
			Value bool
		}](raw)
		if err != nil {
			return nil, err
		}
		return nil, core.SetArchived(ctx, p.Chat, p.Value)
	})
	h("chats.pin", func(ctx context.Context, raw json.RawMessage) (any, error) {
		p, err := rpc.Bind[struct {
			Chat  string
			Value bool
		}](raw)
		if err != nil {
			return nil, err
		}
		return nil, core.SetPinned(ctx, p.Chat, p.Value)
	})
	h("chats.mute", func(ctx context.Context, raw json.RawMessage) (any, error) {
		p, err := rpc.Bind[struct {
			Chat  string
			Value bool
			Hours float64
		}](raw)
		if err != nil {
			return nil, err
		}
		return nil, core.SetMuted(ctx, p.Chat, p.Value, time.Duration(p.Hours*float64(time.Hour)))
	})
	h("chats.setDraft", func(ctx context.Context, raw json.RawMessage) (any, error) {
		p, err := rpc.Bind[struct{ Chat, Text string }](raw)
		if err != nil {
			return nil, err
		}
		return nil, core.SetDraft(ctx, p.Chat, p.Text)
	})
	h("chats.avatar", func(ctx context.Context, raw json.RawMessage) (any, error) {
		p, err := rpc.Bind[chatParam](raw)
		if err != nil {
			return nil, err
		}
		return core.Avatar(ctx, p.Chat)
	})
	h("chats.groupInfo", func(ctx context.Context, raw json.RawMessage) (any, error) {
		p, err := rpc.Bind[chatParam](raw)
		if err != nil {
			return nil, err
		}
		return core.GroupInfo(ctx, p.Chat)
	})
	h("chats.loadOlder", func(ctx context.Context, raw json.RawMessage) (any, error) {
		p, err := rpc.Bind[chatParam](raw)
		if err != nil {
			return nil, err
		}
		return nil, core.LoadOlder(ctx, p.Chat)
	})
	h("chats.done", func(ctx context.Context, raw json.RawMessage) (any, error) {
		p, err := rpc.Bind[struct {
			Chat  string
			Value bool
		}](raw)
		if err != nil {
			return nil, err
		}
		return nil, core.SetDone(ctx, p.Chat, p.Value)
	})
	h("chats.snooze", func(ctx context.Context, raw json.RawMessage) (any, error) {
		p, err := rpc.Bind[struct {
			Chat  string
			Until int64
			Msg   string
		}](raw)
		if err != nil {
			return nil, err
		}
		return nil, core.Snooze(ctx, p.Chat, p.Until, p.Msg)
	})
	h("messages.transcribe", func(ctx context.Context, raw json.RawMessage) (any, error) {
		p, err := rpc.Bind[msgParam](raw)
		if err != nil {
			return nil, err
		}
		return nil, core.QueueTranscription(ctx, p.Chat, p.ID)
	})
	h("transcribe.get", func(ctx context.Context, _ json.RawMessage) (any, error) {
		ok, model := core.WhisperInstalled()
		return map[string]any{"installed": ok, "model": model, "enabled": st.GetKV(ctx, "transcribe") != "off"}, nil
	})
	h("transcribe.set", func(ctx context.Context, raw json.RawMessage) (any, error) {
		p, err := rpc.Bind[struct{ Enabled bool }](raw)
		if err != nil {
			return nil, err
		}
		v := "on"
		if !p.Enabled {
			v = "off"
		}
		return nil, st.SetKV(ctx, "transcribe", v)
	})
	h("chats.setNote", func(ctx context.Context, raw json.RawMessage) (any, error) {
		p, err := rpc.Bind[struct{ Chat, Text string }](raw)
		if err != nil {
			return nil, err
		}
		return nil, core.SetNote(ctx, p.Chat, p.Text)
	})
	h("snippets.list", func(ctx context.Context, _ json.RawMessage) (any, error) { return st.Snippets(ctx) })
	h("snippets.set", func(ctx context.Context, raw json.RawMessage) (any, error) {
		p, err := rpc.Bind[struct{ Trigger, Text string }](raw)
		if err != nil {
			return nil, err
		}
		if err := st.SetSnippet(ctx, p.Trigger, p.Text); err != nil {
			return nil, err
		}
		srv.Broadcast("snippets.changed", nil)
		return nil, nil
	})
	h("status.list", func(ctx context.Context, _ json.RawMessage) (any, error) { return core.StatusList(ctx) })
	h("status.view", func(ctx context.Context, raw json.RawMessage) (any, error) {
		p, err := rpc.Bind[struct{ ID string }](raw)
		if err != nil {
			return nil, err
		}
		return nil, core.ViewStatus(ctx, p.ID)
	})
	h("status.reply", func(ctx context.Context, raw json.RawMessage) (any, error) {
		p, err := rpc.Bind[struct{ ID, Text string }](raw)
		if err != nil {
			return nil, err
		}
		return core.ReplyToStatus(ctx, p.ID, p.Text)
	})
	h("status.postText", func(ctx context.Context, raw json.RawMessage) (any, error) {
		p, err := rpc.Bind[struct {
			Text string
			Bg   uint32
		}](raw)
		if err != nil {
			return nil, err
		}
		return core.PostTextStatus(ctx, p.Text, p.Bg)
	})
	h("status.postFile", func(ctx context.Context, raw json.RawMessage) (any, error) {
		p, err := rpc.Bind[struct{ Path, Caption string }](raw)
		if err != nil {
			return nil, err
		}
		return core.SendFile(ctx, "status@broadcast", p.Path, p.Caption, "auto", wa.SendOpts{})
	})
	h("status.setReceipts", func(ctx context.Context, raw json.RawMessage) (any, error) {
		p, err := rpc.Bind[struct{ Enabled bool }](raw)
		if err != nil {
			return nil, err
		}
		v := "on"
		if !p.Enabled {
			v = "off"
		}
		return nil, st.SetKV(ctx, "status_receipts", v)
	})
	// Groups, disappearing messages, blocking
	h("groups.members", func(ctx context.Context, raw json.RawMessage) (any, error) {
		p, err := rpc.Bind[struct {
			Chat    string
			Members []string
			Action  string
		}](raw)
		if err != nil {
			return nil, err
		}
		return core.UpdateMembers(ctx, p.Chat, p.Members, p.Action)
	})
	h("groups.setName", func(ctx context.Context, raw json.RawMessage) (any, error) {
		p, err := rpc.Bind[struct{ Chat, Name string }](raw)
		if err != nil {
			return nil, err
		}
		return nil, core.SetGroupName(ctx, p.Chat, p.Name)
	})
	h("groups.setTopic", func(ctx context.Context, raw json.RawMessage) (any, error) {
		p, err := rpc.Bind[struct{ Chat, Topic string }](raw)
		if err != nil {
			return nil, err
		}
		return nil, core.SetGroupTopic(ctx, p.Chat, p.Topic)
	})
	h("groups.setFlags", func(ctx context.Context, raw json.RawMessage) (any, error) {
		p, err := rpc.Bind[struct {
			Chat     string
			Announce *bool
			Locked   *bool
		}](raw)
		if err != nil {
			return nil, err
		}
		return nil, core.SetGroupFlags(ctx, p.Chat, p.Announce, p.Locked)
	})
	h("groups.inviteLink", func(ctx context.Context, raw json.RawMessage) (any, error) {
		p, err := rpc.Bind[struct {
			Chat  string
			Reset bool
		}](raw)
		if err != nil {
			return nil, err
		}
		return core.InviteLink(ctx, p.Chat, p.Reset)
	})
	h("groups.leave", func(ctx context.Context, raw json.RawMessage) (any, error) {
		p, err := rpc.Bind[chatParam](raw)
		if err != nil {
			return nil, err
		}
		return nil, core.LeaveGroup(ctx, p.Chat)
	})
	h("chats.setDisappearing", func(ctx context.Context, raw json.RawMessage) (any, error) {
		p, err := rpc.Bind[struct {
			Chat    string
			Seconds int64
		}](raw)
		if err != nil {
			return nil, err
		}
		return nil, core.SetDisappearing(ctx, p.Chat, p.Seconds)
	})
	h("blocklist.get", func(ctx context.Context, _ json.RawMessage) (any, error) { return core.Blocklist(ctx) })
	h("blocklist.set", func(ctx context.Context, raw json.RawMessage) (any, error) {
		p, err := rpc.Bind[struct {
			Chat  string
			Block bool
		}](raw)
		if err != nil {
			return nil, err
		}
		return nil, core.SetBlocked(ctx, p.Chat, p.Block)
	})
	// Account settings
	h("settings.get", func(ctx context.Context, _ json.RawMessage) (any, error) { return core.GetSettings(ctx) })
	h("settings.setPrivacy", func(ctx context.Context, raw json.RawMessage) (any, error) {
		p, err := rpc.Bind[struct{ Name, Value string }](raw)
		if err != nil {
			return nil, err
		}
		return nil, core.SetPrivacy(ctx, p.Name, p.Value)
	})
	h("settings.setAbout", func(ctx context.Context, raw json.RawMessage) (any, error) {
		p, err := rpc.Bind[struct{ Text string }](raw)
		if err != nil {
			return nil, err
		}
		return nil, core.SetAbout(ctx, p.Text)
	})
	h("settings.setName", func(ctx context.Context, raw json.RawMessage) (any, error) {
		p, err := rpc.Bind[struct{ Name string }](raw)
		if err != nil {
			return nil, err
		}
		return nil, core.SetPushName(ctx, p.Name)
	})
	h("chats.unread", func(ctx context.Context, _ json.RawMessage) (any, error) {
		c, m, err := st.TotalUnread(ctx)
		return map[string]int{"chats": c, "messages": m}, err
	})

	// Messages
	h("messages.list", func(ctx context.Context, raw json.RawMessage) (any, error) {
		p, err := rpc.Bind[struct {
			Chat   string
			Before int64
			Limit  int
		}](raw)
		if err != nil {
			return nil, err
		}
		msgs, err := st.ListMessages(ctx, p.Chat, p.Before, p.Limit)
		if msgs == nil {
			msgs = []*hs.Message{}
		}
		return msgs, err
	})
	h("messages.sendText", func(ctx context.Context, raw json.RawMessage) (any, error) {
		p, err := rpc.Bind[struct {
			Chat, Text string
			wa.SendOpts
		}](raw)
		if err != nil {
			return nil, err
		}
		return core.SendText(ctx, p.Chat, p.Text, p.SendOpts)
	})
	h("messages.sendFile", func(ctx context.Context, raw json.RawMessage) (any, error) {
		p, err := rpc.Bind[struct {
			Chat, Path, Caption, Kind string
			wa.SendOpts
		}](raw)
		if err != nil {
			return nil, err
		}
		return core.SendFile(ctx, p.Chat, p.Path, p.Caption, p.Kind, p.SendOpts)
	})
	h("messages.react", func(ctx context.Context, raw json.RawMessage) (any, error) {
		p, err := rpc.Bind[struct{ Chat, ID, Emoji string }](raw)
		if err != nil {
			return nil, err
		}
		return nil, core.React(ctx, p.Chat, p.ID, p.Emoji)
	})
	h("messages.edit", func(ctx context.Context, raw json.RawMessage) (any, error) {
		p, err := rpc.Bind[struct{ Chat, ID, Text string }](raw)
		if err != nil {
			return nil, err
		}
		return nil, core.Edit(ctx, p.Chat, p.ID, p.Text)
	})
	h("messages.delete", func(ctx context.Context, raw json.RawMessage) (any, error) {
		p, err := rpc.Bind[struct {
			Chat, ID    string
			ForEveryone bool
		}](raw)
		if err != nil {
			return nil, err
		}
		return nil, core.Delete(ctx, p.Chat, p.ID, p.ForEveryone)
	})
	h("messages.star", func(ctx context.Context, raw json.RawMessage) (any, error) {
		p, err := rpc.Bind[struct {
			Chat, ID string
			Value    bool
		}](raw)
		if err != nil {
			return nil, err
		}
		return nil, core.Star(ctx, p.Chat, p.ID, p.Value)
	})
	h("messages.forward", func(ctx context.Context, raw json.RawMessage) (any, error) {
		p, err := rpc.Bind[struct{ Chat, ID, To string }](raw)
		if err != nil {
			return nil, err
		}
		return core.Forward(ctx, p.Chat, p.ID, p.To)
	})
	h("messages.download", func(ctx context.Context, raw json.RawMessage) (any, error) {
		p, err := rpc.Bind[msgParam](raw)
		if err != nil {
			return nil, err
		}
		return core.DownloadMedia(ctx, p.Chat, p.ID)
	})
	h("messages.search", func(ctx context.Context, raw json.RawMessage) (any, error) {
		p, err := rpc.Bind[struct {
			Query, Chat string
			Limit       int
		}](raw)
		if err != nil {
			return nil, err
		}
		return st.Search(ctx, p.Query, p.Chat, p.Limit)
	})
	h("messages.starred", func(ctx context.Context, raw json.RawMessage) (any, error) {
		p, err := rpc.Bind[struct {
			Query string
			Limit int
		}](raw)
		if err != nil {
			return nil, err
		}
		return st.Starred(ctx, p.Query, p.Limit)
	})
	h("chats.markAllRead", func(ctx context.Context, _ json.RawMessage) (any, error) {
		chats, err := st.UnreadChats(ctx)
		if err != nil {
			return nil, err
		}
		for _, c := range chats {
			if err := core.MarkRead(ctx, c); err != nil {
				return nil, err
			}
		}
		return len(chats), nil
	})
	h("polls.create", func(ctx context.Context, raw json.RawMessage) (any, error) {
		p, err := rpc.Bind[struct {
			Chat, Question string
			Options        []string
			Multi          bool
		}](raw)
		if err != nil {
			return nil, err
		}
		return core.SendPoll(ctx, p.Chat, p.Question, p.Options, p.Multi)
	})
	h("polls.vote", func(ctx context.Context, raw json.RawMessage) (any, error) {
		p, err := rpc.Bind[struct {
			Chat, ID string
			Options  []string
		}](raw)
		if err != nil {
			return nil, err
		}
		return nil, core.VotePoll(ctx, p.Chat, p.ID, p.Options)
	})

	// Voice notes
	h("voice.start", func(ctx context.Context, raw json.RawMessage) (any, error) {
		p, err := rpc.Bind[chatParam](raw)
		if err != nil {
			return nil, err
		}
		return nil, core.StartRecording(ctx, p.Chat)
	})
	h("voice.stop", func(ctx context.Context, raw json.RawMessage) (any, error) {
		p, err := rpc.Bind[struct {
			Send bool
			wa.SendOpts
		}](raw)
		if err != nil {
			return nil, err
		}
		return core.StopRecording(ctx, p.Send, p.SendOpts)
	})

	// Presence
	h("presence.typing", func(ctx context.Context, raw json.RawMessage) (any, error) {
		p, err := rpc.Bind[struct {
			Chat      string
			Composing bool
		}](raw)
		if err != nil {
			return nil, err
		}
		return nil, core.SetTyping(ctx, p.Chat, p.Composing, false)
	})
	h("presence.subscribe", func(ctx context.Context, raw json.RawMessage) (any, error) {
		p, err := rpc.Bind[chatParam](raw)
		if err != nil {
			return nil, err
		}
		return nil, core.SubscribePresence(ctx, p.Chat)
	})
	h("ui.focus", func(ctx context.Context, raw json.RawMessage) (any, error) {
		p, err := rpc.Bind[struct {
			Chat   string
			Active bool
		}](raw)
		if err != nil {
			return nil, err
		}
		if p.Active {
			core.SetUIFocus(p.Chat)
		} else {
			core.SetUIFocus("")
		}
		return nil, core.SetOnline(ctx, p.Active)
	})
	h("ui.open", func(ctx context.Context, raw json.RawMessage) (any, error) {
		p, err := rpc.Bind[chatParam](raw)
		if err != nil {
			return nil, err
		}
		openUI(p.Chat)
		return nil, nil
	})

	// Contacts
	h("contacts.search", func(ctx context.Context, raw json.RawMessage) (any, error) {
		p, err := rpc.Bind[struct{ Query string }](raw)
		if err != nil {
			return nil, err
		}
		return core.SearchContacts(ctx, p.Query)
	})
	h("contacts.resolvePhone", func(ctx context.Context, raw json.RawMessage) (any, error) {
		p, err := rpc.Bind[struct{ Phone string }](raw)
		if err != nil {
			return nil, err
		}
		return core.ResolvePhone(ctx, p.Phone)
	})

	// Productivity
	h("schedule.add", func(ctx context.Context, raw json.RawMessage) (any, error) {
		p, err := rpc.Bind[struct {
			Chat, Text string
			At         int64
		}](raw)
		if err != nil {
			return nil, err
		}
		return core.Schedule(ctx, p.Chat, p.Text, time.Unix(p.At, 0))
	})
	h("schedule.list", func(ctx context.Context, raw json.RawMessage) (any, error) {
		p, err := rpc.Bind[chatParam](raw)
		if err != nil {
			return nil, err
		}
		return core.ListScheduled(ctx, p.Chat)
	})
	h("schedule.cancel", func(ctx context.Context, raw json.RawMessage) (any, error) {
		p, err := rpc.Bind[struct{ ID int64 }](raw)
		if err != nil {
			return nil, err
		}
		return nil, core.CancelScheduled(ctx, p.ID)
	})
	h("focus.get", func(ctx context.Context, _ json.RawMessage) (any, error) {
		var vips []string
		_ = json.Unmarshal([]byte(st.GetKV(ctx, "vips")), &vips)
		if vips == nil {
			vips = []string{}
		}
		var until int64
		fmt.Sscan(st.GetKV(ctx, "focus_until"), &until)
		return map[string]any{"until": until, "active": focusBlocks(ctx, st, "\x00"), "vips": vips}, nil
	})
	h("focus.set", func(ctx context.Context, raw json.RawMessage) (any, error) {
		// until: 0 = off, -1 = indefinitely, otherwise unix time.
		p, err := rpc.Bind[struct {
			Until int64
			Vips  *[]string
		}](raw)
		if err != nil {
			return nil, err
		}
		_ = st.SetKV(ctx, "focus_until", fmt.Sprint(p.Until))
		if p.Vips != nil {
			b, _ := json.Marshal(*p.Vips)
			_ = st.SetKV(ctx, "vips", string(b))
		}
		srv.Broadcast("focus", map[string]any{"until": p.Until})
		return nil, nil
	})
	h("updates.check", func(ctx context.Context, _ json.RawMessage) (any, error) { return core.CheckUpdates(ctx) })
	h("ping", func(ctx context.Context, _ json.RawMessage) (any, error) { return "pong", nil })

}
