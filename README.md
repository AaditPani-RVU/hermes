# Hermes

A native WhatsApp client for Linux, built for [niri](https://github.com/YaLTeR/niri) and the Clavis Quickshell desktop.

Hermes is organised around a **triage inbox** rather than a chat list: chats are grouped by what they need from you
(*Needs reply*, *Mentions*, *FYI*, *Waiting on them*, *Snoozed*) and you clear them with the keyboard,
like an email client such as Superhuman.

> **Unofficial.** Hermes is not affiliated with, endorsed by, or connected to WhatsApp or Meta.
> It links to your account as a companion device (like WhatsApp Web) using the open-source
> [whatsmeow](https://github.com/tulir/whatsmeow) library. Using third-party clients is against WhatsApp's
> Terms of Service and may get your account restricted. Use at your own risk, and only with your own account.

## Features

- **Triage inbox:** `j`/`k` to move, `e` done, `s` snooze, `Ctrl+E` done and open next, "remind me about this message".
  Snoozed chats come back with a notification.
- **Messaging:** text with formatting, replies, mentions, reactions, edits, deletes, forwards, stars, polls.
- **Media:** photos, video, GIFs, voice notes (record and play), documents, stickers, locations, contacts.
- **Sync with your phone:** archive, pin, mute, read state; history sync; read receipts, typing, online status.
- **Productivity:** full-text search across all chats, scheduled messages, focus mode with a VIP list,
  per-chat drafts, `Ctrl+K` command palette.
- **Desktop integration:** grouped notifications, a status-bar module with quick reply, a niri keybind,
  and colours that follow your wallpaper (Material 3 via matugen).
- **CLI:** `hermes inbox`, `hermes send "Mom" "on my way"`, `hermes search invoice`, `hermes schedule …`.
- **Keeps up with WhatsApp:** tracks the current WhatsApp Web version automatically; `hermes-update`
  pulls protocol-library updates, tests, rebuilds and rolls back on failure.

Calls and payments are not supported (no open implementation exists).

## Architecture

```
hermes-ui (Quickshell/QML) ──┐
Clavis bar module (QML) ─────┼── JSON-RPC over a Unix socket ── hermesd (Go, systemd --user)
hermes CLI ──────────────────┘                                    ├─ whatsmeow (multi-device protocol, E2E)
                                                                  ├─ SQLite + FTS5 (messages, search, triage)
                                                                  └─ notifications, scheduler, media pipeline
```

The daemon owns the connection, so notifications and scheduled messages work with no window open.

## Install

Requires Go 1.27+, [Quickshell](https://quickshell.outfoxxed.me/) 0.3+, Qt 6.8, ffmpeg, mpv and PipeWire.
Everything installs into `~/.local`; no root needed.

```sh
./install.sh            # build, install, enable the hermesd user service
hermes pair             # link: scan the QR code with WhatsApp → Linked devices
hermes-ui               # open the window
```

Optional: `qt6-image-formats-plugins` for native animated WebP stickers.

## Layout

| Path | What |
|---|---|
| `daemon/` | `hermesd` daemon and `hermes` CLI (Go) |
| `ui/` | Quickshell UI (`Services/`, `Components/`, `Views/`) |
| `clavis-module/` | Bar widget for Clavis Shell |
| `packaging/` | systemd unit, launcher, updater, desktop entry, niri keybind |
| `PLAN.md` | Design notes, feature matrix, roadmap and progress log |

Your data (session keys, messages, media) lives in `~/.local/share/hermes` and is never part of this repository.
