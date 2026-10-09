// Package notify sends freedesktop desktop notifications, one per chat, and
// routes their action buttons back to the daemon.
package notify

import (
	"html"
	"os"
	"strings"
	"sync"

	"github.com/godbus/dbus/v5"

	hs "github.com/aadit/hermes/daemon/internal/store"
)

const (
	busName = "org.freedesktop.Notifications"
	objPath = "/org/freedesktop/Notifications"
)

type Notifier struct {
	conn *dbus.Conn
	obj  dbus.BusObject

	OnOpen     func(chat string)
	OnMarkRead func(chat string)
	// Quiet returns true when notifications should be suppressed (focus mode).
	Quiet func(chat string) bool
	// Icons are image files tried in order for the app icon; the first that
	// exists wins, checked on every send so a custom icon applies immediately.
	Icons []string

	mu      sync.Mutex
	byChat  map[string]uint32
	lines   map[string][]string
	chatFor map[uint32]string
}

func New() (*Notifier, error) {
	conn, err := dbus.ConnectSessionBus()
	if err != nil {
		return nil, err
	}
	n := &Notifier{
		conn: conn, obj: conn.Object(busName, objPath),
		byChat: map[string]uint32{}, lines: map[string][]string{}, chatFor: map[uint32]string{},
	}
	if err := conn.AddMatchSignal(dbus.WithMatchInterface(busName), dbus.WithMatchObjectPath(objPath)); err != nil {
		return nil, err
	}
	sigs := make(chan *dbus.Signal, 16)
	conn.Signal(sigs)
	go n.listen(sigs)
	return n, nil
}

func (n *Notifier) listen(sigs chan *dbus.Signal) {
	for sig := range sigs {
		switch sig.Name {
		case busName + ".ActionInvoked":
			if len(sig.Body) < 2 {
				continue
			}
			id, _ := sig.Body[0].(uint32)
			action, _ := sig.Body[1].(string)
			n.mu.Lock()
			chat, ok := n.chatFor[id]
			n.mu.Unlock()
			if !ok {
				continue
			}
			switch action {
			case "default", "open":
				if n.OnOpen != nil {
					go n.OnOpen(chat)
				}
			case "read":
				if n.OnMarkRead != nil {
					go n.OnMarkRead(chat)
				}
			}
		case busName + ".NotificationClosed":
			if len(sig.Body) < 1 {
				continue
			}
			id, _ := sig.Body[0].(uint32)
			n.mu.Lock()
			if chat, ok := n.chatFor[id]; ok {
				delete(n.chatFor, id)
				if n.byChat[chat] == id {
					delete(n.byChat, chat)
					delete(n.lines, chat)
				}
			}
			n.mu.Unlock()
		}
	}
}

// appIcon returns an absolute image path; bare theme names like "chat" are
// missing from most icon themes and render as a placeholder.
func (n *Notifier) appIcon() string {
	for _, p := range n.Icons {
		if st, err := os.Stat(p); err == nil && !st.IsDir() {
			return p
		}
	}
	return ""
}

func (n *Notifier) send(replaces uint32, icon, summary, body string, actions []string, hints map[string]dbus.Variant) uint32 {
	var id uint32
	call := n.obj.Call(busName+".Notify", 0, "Hermes", replaces, icon, summary, body, actions, hints, int32(-1))
	if call.Err != nil {
		return 0
	}
	_ = call.Store(&id)
	return id
}

func (n *Notifier) NotifyMessage(chat *hs.Chat, m *hs.Message) {
	if n.Quiet != nil && n.Quiet(chat.JID) {
		return
	}
	line := hs.Preview(m)
	if chat.IsGroup {
		first := hs.ShortName(m.SenderName)
		line = first + ": " + line
	}
	n.mu.Lock()
	lines := append(n.lines[chat.JID], html.EscapeString(line))
	if len(lines) > 4 {
		lines = lines[len(lines)-4:]
	}
	n.lines[chat.JID] = lines
	replaces := n.byChat[chat.JID]
	n.mu.Unlock()

	summary := chat.Name
	if count := chat.Unread; count > 1 {
		summary += " · " + itoa(count) + " new"
	}
	hints := map[string]dbus.Variant{
		"desktop-entry": dbus.MakeVariant("hermes"),
		"category":      dbus.MakeVariant("im.received"),
	}
	icon := n.appIcon()
	if chat.AvatarPath != "" {
		hints["image-path"] = dbus.MakeVariant(chat.AvatarPath)
	}
	id := n.send(replaces, icon, summary, strings.Join(lines, "\n"), []string{"default", "Open", "read", "Mark as read"}, hints)
	if id == 0 {
		return
	}
	n.mu.Lock()
	n.byChat[chat.JID] = id
	n.chatFor[id] = chat.JID
	n.mu.Unlock()
}

// NotifyReminder announces a snoozed chat coming back. It bypasses focus mode:
// the user asked to be reminded.
func (n *Notifier) NotifyReminder(chat *hs.Chat, body string) {
	hints := map[string]dbus.Variant{
		"desktop-entry": dbus.MakeVariant("hermes"),
		"category":      dbus.MakeVariant("im"),
	}
	if chat.AvatarPath != "" {
		hints["image-path"] = dbus.MakeVariant(chat.AvatarPath)
	}
	id := n.send(0, n.appIcon(), "⏰ Back: "+chat.Name, html.EscapeString(body), []string{"default", "Open"}, hints)
	if id == 0 {
		return
	}
	n.mu.Lock()
	n.chatFor[id] = chat.JID
	n.mu.Unlock()
}

func (n *Notifier) NotifyCall(from string, video bool) {
	kind := "Voice call"
	if video {
		kind = "Video call"
	}
	n.send(0, n.appIcon(), kind+" from "+from, "Answer on your phone — desktop calls aren't supported yet.", nil,
		map[string]dbus.Variant{"urgency": dbus.MakeVariant(byte(2)), "category": dbus.MakeVariant("im")})
}

func (n *Notifier) NotifySystem(summary, body string) {
	n.send(0, n.appIcon(), summary, html.EscapeString(body), nil, map[string]dbus.Variant{})
}

func (n *Notifier) Dismiss(chat string) {
	n.mu.Lock()
	id, ok := n.byChat[chat]
	delete(n.byChat, chat)
	delete(n.lines, chat)
	n.mu.Unlock()
	if ok {
		n.obj.Call(busName+".CloseNotification", 0, id)
	}
}

func itoa(i int) string {
	if i < 10 {
		return string(rune('0' + i))
	}
	return itoa(i/10) + string(rune('0'+i%10))
}
