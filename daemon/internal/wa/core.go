// Package wa wraps whatsmeow: connection lifecycle, event handling, and the
// operations exposed to the UI over RPC.
package wa

import (
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"sync"
	"time"

	"go.mau.fi/whatsmeow"
	"go.mau.fi/whatsmeow/proto/waCompanionReg"
	"go.mau.fi/whatsmeow/store"
	"go.mau.fi/whatsmeow/store/sqlstore"
	"go.mau.fi/whatsmeow/types"
	"go.mau.fi/whatsmeow/types/events"
	waLog "go.mau.fi/whatsmeow/util/log"
	"google.golang.org/protobuf/proto"
	"rsc.io/qr"

	hs "github.com/aadit/hermes/daemon/internal/store"
)

type Paths struct {
	Data  string // ~/.local/share/hermes
	Cache string // ~/.cache/hermes
}

func (p Paths) MediaDir() string  { return filepath.Join(p.Data, "media") }
func (p Paths) ThumbDir() string  { return filepath.Join(p.Cache, "thumbs") }
func (p Paths) AvatarDir() string { return filepath.Join(p.Cache, "avatars") }
func (p Paths) TmpDir() string    { return filepath.Join(p.Cache, "tmp") }

// Notifier is implemented by the desktop notification layer.
type Notifier interface {
	NotifyMessage(chat *hs.Chat, m *hs.Message)
	NotifyCall(from string, video bool)
	NotifyReminder(chat *hs.Chat, body string)
	NotifyDigest(chat *hs.Chat, summary, body string)
	NotifySystem(summary, body string)
	Dismiss(chat string)
}

type Core struct {
	Log    waLog.Logger
	Paths  Paths
	Store  *hs.Store
	Notify Notifier
	// Emit pushes an event to every connected UI client.
	Emit func(event string, data any)

	container *sqlstore.Container
	cli       *whatsmeow.Client

	mu        sync.RWMutex
	state     string // starting, pairing, connecting, connected, disconnected, logged_out
	qrCode    string
	syncing   bool
	uiFocus   string // chat currently open in a focused UI window
	recording *recording
	nameCache map[types.JID]string

	transcribeQ chan transcribeJob
	ocrQ        chan ocrJob
	ocr         ocrState
	digest      digestState
	mediaWait   map[string]chan *events.MediaRetry // message ID -> waiter for a re-upload
}

func New(log waLog.Logger, paths Paths, db *sql.DB, st *hs.Store) (*Core, error) {
	for _, d := range []string{paths.MediaDir(), paths.ThumbDir(), paths.AvatarDir(), paths.TmpDir()} {
		if err := os.MkdirAll(d, 0o700); err != nil {
			return nil, err
		}
	}
	container := sqlstore.NewWithDB(db, "sqlite3", log.Sub("Store"))
	if err := container.Upgrade(context.Background()); err != nil {
		return nil, fmt.Errorf("whatsmeow store upgrade: %w", err)
	}
	c := &Core{
		Log:       log,
		Paths:     paths,
		Store:     st,
		Emit:      func(string, any) {},
		container: container,
		state:     "starting",
		nameCache: map[types.JID]string{},

		transcribeQ: make(chan transcribeJob, 256),
		ocrQ:        make(chan ocrJob, 256),
		mediaWait:   map[string]chan *events.MediaRetry{},
	}
	return c, nil
}

func (c *Core) setState(s string) {
	c.mu.Lock()
	c.state = s
	if s != "pairing" {
		c.qrCode = ""
	}
	c.mu.Unlock()
	c.Emit("state", c.Status())
}

type Status struct {
	State   string `json:"state"`
	QR      string `json:"qr,omitempty"`
	QRPath  string `json:"qrPath,omitempty"`
	MeJID   string `json:"meJid,omitempty"`
	MeName  string `json:"meName,omitempty"`
	Syncing bool   `json:"syncing"`
	Version string `json:"waVersion"`
}

func (c *Core) Status() Status {
	c.mu.RLock()
	defer c.mu.RUnlock()
	st := Status{State: c.state, QR: c.qrCode, Syncing: c.syncing, Version: store.GetWAVersion().String()}
	if c.qrCode != "" {
		st.QRPath = c.qrPNG(c.qrCode)
	}
	if c.cli != nil && c.cli.Store.ID != nil {
		st.MeJID = c.cli.Store.ID.ToNonAD().String()
		st.MeName = c.cli.Store.PushName
	}
	return st
}

// qrPNG renders the pairing code to a PNG the UI can display (cached per code).
func (c *Core) qrPNG(code string) string {
	sum := sha256.Sum256([]byte(code))
	path := filepath.Join(c.Paths.TmpDir(), "qr-"+hex.EncodeToString(sum[:6])+".png")
	if _, err := os.Stat(path); err == nil {
		return path
	}
	q, err := qr.Encode(code, qr.L)
	if err != nil {
		return ""
	}
	q.Scale = 10
	old, _ := filepath.Glob(filepath.Join(c.Paths.TmpDir(), "qr-*.png"))
	for _, o := range old {
		_ = os.Remove(o)
	}
	if err := os.WriteFile(path, q.PNG(), 0o600); err != nil {
		return ""
	}
	return path
}

// refreshWAVersion asks web.whatsapp.com which client version is current and
// advertises that, so we never look like an outdated client.
func (c *Core) refreshWAVersion(ctx context.Context) {
	ctx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	v, err := whatsmeow.GetLatestVersion(ctx, http.DefaultClient)
	if err != nil {
		c.Log.Warnf("Couldn't fetch latest WhatsApp Web version, using built-in %s: %v", store.GetWAVersion(), err)
		return
	}
	if *v != store.GetWAVersion() {
		c.Log.Infof("Updating advertised WhatsApp Web version %s -> %s", store.GetWAVersion(), v)
		store.SetWAVersion(*v)
	}
}

// Start connects (pairing via QR first if there's no session) and blocks until ctx ends.
func (c *Core) Start(ctx context.Context) error {
	store.SetOSInfo("Hermes (Linux)", [3]uint32{0, 1, 0})
	store.DeviceProps.PlatformType = waCompanionReg.DeviceProps_DESKTOP.Enum()
	store.DeviceProps.RequireFullSync = proto.Bool(true)
	c.refreshWAVersion(ctx)

	device, err := c.container.GetFirstDevice(ctx)
	if err != nil {
		return err
	}
	c.cli = whatsmeow.NewClient(device, c.Log.Sub("Client"))
	c.cli.AddEventHandler(c.handleEvent)
	c.cli.EnableAutoReconnect = true
	go c.versionWatcher(ctx)
	go c.schedulerLoop(ctx)
	go c.transcribeLoop(ctx)
	go c.ocrLoop(ctx)
	go c.digestLoop(ctx)

	if err := c.connect(ctx); err != nil {
		return err
	}
	<-ctx.Done()
	c.cli.Disconnect()
	return nil
}

func (c *Core) connect(ctx context.Context) error {
	if c.cli.Store.ID == nil {
		qrChan, err := c.cli.GetQRChannel(ctx)
		if err != nil {
			return err
		}
		go func() {
			for item := range qrChan {
				switch item.Event {
				case "code":
					c.mu.Lock()
					c.state, c.qrCode = "pairing", item.Code
					c.mu.Unlock()
					c.Emit("state", c.Status())
				case "success":
					c.setState("connecting")
				case "timeout":
					c.Log.Infof("QR pairing timed out; restarting pairing")
					c.setState("disconnected")
					go func() {
						time.Sleep(time.Second)
						if err := c.connect(ctx); err != nil {
							c.Log.Errorf("Reconnect for pairing failed: %v", err)
						}
					}()
				default:
					c.Log.Infof("QR channel event: %s %v", item.Event, item.Error)
				}
			}
		}()
	} else {
		c.setState("connecting")
	}
	return c.cli.Connect()
}

// PairPhone starts phone-number pairing; returns the 8-character code to type on the phone.
func (c *Core) PairPhone(ctx context.Context, phone string) (string, error) {
	if c.cli.Store.ID != nil {
		return "", fmt.Errorf("already logged in")
	}
	return c.cli.PairPhone(ctx, phone, true, whatsmeow.PairClientChrome, "Chrome (Linux)")
}

func (c *Core) Logout(ctx context.Context) error {
	if err := c.cli.Logout(ctx); err != nil {
		return err
	}
	c.setState("logged_out")
	go func() {
		time.Sleep(time.Second)
		device := c.container.NewDevice()
		c.cli = whatsmeow.NewClient(device, c.Log.Sub("Client"))
		c.cli.AddEventHandler(c.handleEvent)
		c.cli.EnableAutoReconnect = true
		if err := c.connect(context.Background()); err != nil {
			c.Log.Errorf("Re-pair after logout failed: %v", err)
		}
	}()
	return nil
}

// SetUIFocus tells the core which chat the user is looking at, so we don't notify for it.
func (c *Core) SetUIFocus(chat string) {
	c.mu.Lock()
	c.uiFocus = chat
	c.mu.Unlock()
	if chat != "" && c.Notify != nil {
		c.Notify.Dismiss(chat)
	}
}

func (c *Core) focused(chat string) bool {
	c.mu.RLock()
	defer c.mu.RUnlock()
	return c.uiFocus == chat
}

func (c *Core) loggedIn() error {
	if c.cli == nil || c.cli.Store.ID == nil {
		return fmt.Errorf("not logged in")
	}
	return nil
}
