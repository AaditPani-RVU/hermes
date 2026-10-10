# Hermes — a native WhatsApp client for Clavis Shell + niri

> Personal-use WhatsApp client for Debian 13 / niri / Clavis Shell.
> Goal: everything the official WhatsApp app does that is technically reachable,
> with a custom Material-3 UI that matches Clavis, plus safe productivity extras.

Status: **MVP + triage inbox, running on the live account** · Started 2026-10-09

---

## 1. Architecture

```
 ┌──────────────────────────────┐        ┌──────────────────────────────┐
 │  hermes-ui  (Quickshell/QML) │        │  Clavis bar module (QML)     │
 │  main window, chat list,     │        │  unread badge, popup,        │
 │  conversations, media viewer │        │  quick-reply, DND toggle     │
 └──────────────┬───────────────┘        └──────────────┬───────────────┘
                │  JSON-RPC 2.0 over Unix socket         │
                │  $XDG_RUNTIME_DIR/hermes.sock          │
 ┌──────────────┴────────────────────────────────────────┴───────────────┐
 │  hermesd  (Go daemon, systemd --user service)                         │
 │  ├─ whatsmeow client (multi-device protocol, E2E via libsignal port)  │
 │  ├─ store: SQLite (whatsmeow keys + own message DB with FTS5)          │
 │  ├─ media pipeline: download/decrypt/cache, ffmpeg (opus, thumbs)      │
 │  ├─ notifier: org.freedesktop.Notifications w/ inline reply actions    │
 │  ├─ scheduler: scheduled msgs, reminders, snoozes                      │
 │  └─ plugins: transcription, OCR, summaries (all opt-in)                │
 └───────────────────────────────────────────────────────────────────────┘
                │
        `hermes` CLI (same socket): hermes send / search / open / dnd
```

### Why this split
- **Daemon owns the connection.** Messages, notifications and scheduled sends work
  even when no window is open. The UI is just a view and can crash or restart safely.
- **Quickshell for the UI.** You already run Quickshell 0.3.1 with Clavis. A separate
  Quickshell config (`qs -c hermes`) gets `FloatingWindow`, `Quickshell.Io.Socket`
  (Unix sockets, no C++ needed), the matugen colour scheme and the M3Shapes module for free,
  so it looks native to your desktop.
  *Fallback:* if Quickshell windows feel limiting (text input, IME, drag-and-drop),
  move the UI into a small Qt 6.8 C++ app (`QQmlApplicationEngine` + same QML), keeping the RPC.
- **whatsmeow (Go)** is the most mature unofficial multi-device library (it powers
  mautrix-whatsapp). It links as a "companion device", the same way WhatsApp Web does.

### Must stay compatible with
- Qt **6.8.2** (Debian). Avoid 6.9+ APIs (same rule as the `debian13-qt68` Clavis branch).
- Install into `~/.local` like the rest of the Clavis stack; systemd user unit + `10-local-paths.conf` drop-in.

---

## 2. Feature parity with the official app

| Area | Feature | Feasible? | Notes |
|---|---|---|---|
| Account | Link via QR code | ✅ | Also phone-number pairing code |
| | Multi-device (phone can be offline) | ✅ | |
| | History sync on first link | ✅ | Phone sends recent history; older history depends on the phone |
| Messaging | Text, replies, quotes, mentions | ✅ | |
| | Formatting (*bold* _italic_ ~strike~ `mono`, lists, quotes) | ✅ | Render + live preview in composer |
| | Reactions | ✅ | |
| | Edit message (15 min window) | ✅ | |
| | Delete for me / for everyone | ✅ | |
| | Forward, star, pin message | ✅ | |
| | Link previews | ✅ | Generated locally |
| | Polls (create / vote / results) | ✅ | |
| | Disappearing messages | ✅ | |
| | View-once media | ⚠️ | Can receive/send; must honour "once" locally |
| | Read receipts, delivered ticks, typing, online/last-seen | ✅ | |
| Media | Photos, videos, documents, any file | ✅ | |
| | Voice notes (record, waveform, playback speed) | ✅ | Record via PipeWire → ffmpeg → Opus/OGG |
| | Stickers (receive, send, animated, custom packs) | ✅ | WebP; animated via libwebp/ffmpeg |
| | GIFs | ✅ | Sent as MP4 with gif flag |
| | Location, live location (view) | ✅ / ⚠️ | Live-location *sending* is limited |
| | Contact cards (vCard) | ✅ | |
| | Media gallery per chat, docs & links tabs | ✅ | From local DB |
| Chats | Archive, pin, mute, mark unread, clear, delete | ✅ | App-state sync, so it syncs with the phone |
| | Labels/lists, favourites | ✅ | |
| | Chat wallpaper, per-chat theme | ✅ | Local only |
| Groups | Create, add/remove, admins, invite links, settings | ✅ | |
| | Communities + announcement groups | ✅ | |
| Status | View statuses | ✅ | |
| | Post text/image/video status | ✅ | |
| Channels | Follow, read, react | ✅ | whatsmeow newsletter API |
| Privacy | Block/unblock, privacy settings, profile pic/about/name | ✅ | |
| Calls | Voice / video calls | ❌ | **Not implemented in any open library.** We show incoming call notifications, offer "decline with message", and add a button that opens the call on your phone or in WhatsApp Web |
| Payments | WhatsApp Pay | ❌ | Not supported; not attempting |
| Backup | Google Drive backup | ❌ | Replaced by our own local export (see §3) |

---

## 3. Productivity extras (safe: local, user-driven, nothing automated toward other people)

**Rules:** every outgoing message is still one you wrote or explicitly scheduled.
No auto-replies, no bulk sending, no scraping other people's data.

### Organisation
1. **Global full-text search.** SQLite FTS5 across all chats, with filters
   (`from:`, `in:`, `has:image`, `before:`). Searches OCR'd image text and transcribed voice notes too.
2. **Snooze a chat.** Hide it until a set time, then bring it back as unread.
3. **"Remind me about this".** Right-click a message → remind in 1h / tonight / tomorrow / custom.
4. **Private chat notes.** A local sticky note per chat (birthdays, context, to-dos). Never sent.
5. **Smart folders.** Rule-based views like "Unread from Family", "Mentions me", "Has files this week".
6. **Bookmarks / saved-items board.** Starred messages, links and files in one searchable place.

### Speed
7. **Command palette (Ctrl+K).** Jump to a chat, run actions, search. Keyboard-first throughout
   (vim-ish `j/k`, `r` reply, `e` react, `/` search).
8. **Snippets / quick replies.** `;addr` expands to your address, etc. Typed by you, not auto-sent.
9. **Scheduled messages.** Write now, send at a time you set (single messages only, by design).
10. **Drafts.** Persist per chat, survive restarts.
11. **Quick-reply popup from the bar** and from notifications (inline reply), plus a niri keybind
    (`Mod+W`) to toggle the main window as a scratchpad.
12. **CLI.** `hermes send "Mom" "on my way"`, `hermes search "invoice"`, `hermes unread --json`.

### Focus
13. **Focus mode.** Mute everything except a VIP list. Follows Clavis DND and can be scheduled.
14. **Digest mode.** Batch notifications from busy groups into one summary every N minutes.
15. **Private reading.** Optionally don't send read receipts or typing indicators per chat
    (same as the phone's privacy setting, but finer-grained).

### Intelligence (all opt-in, local-first)
16. **Voice-note transcription.** Runs locally with whisper.cpp; nothing leaves the machine.
17. **Image OCR.** Tesseract makes text in screenshots and receipts searchable.
18. **Catch-up summaries.** "Summarise the last 200 messages in this group." Off by default.
    Uses the Claude API, sends only the selected chat, on demand.
19. **Detect dates and to-dos.** Highlights "meet Friday 5pm" with a button that adds it to
    Google Calendar or creates a task. Never automatic.
20. **Translate a message** inline (on demand).

### Your data
21. **Export a chat to Markdown/Obsidian** (works with your `BObs vault`), with media in an attachments folder.
22. **Auto-file media.** Rules like "PDFs from 'College' → ~/Documents/College".
23. **Encrypted local backup** of the Hermes DB (age-encrypted tarball).
24. **Stats.** Per-chat activity and storage usage, with a cleanup tool for large media.

---

## 4. UI direction

- **Material 3 Expressive,** using the matugen palette generated by Clavis from your
  wallpaper. Colours change when the wallpaper changes, and M3Shapes is used for avatars and FABs.
- **Layout:** a three-pane window (rail with folders · chat list · conversation),
  with an optional fourth pane for chat info and media. Collapses to one pane when narrow,
  which suits niri column widths.
- **Bubbles:** grouped bubbles, soft shapes, subtle spring animations, and
  inline media that expands into a viewer. Voice notes show a waveform scrubber.
- **Composer:** formatting preview, emoji/sticker/GIF picker, paste or drag-and-drop images,
  hold to record a voice note, and slash commands (`/schedule`, `/remind`, `/snippet`).
- **Bar module:** an icon with an unread count. Clicking opens a popup with the 5 latest chats
  and quick reply, and middle-click toggles focus mode.
- **Accessibility:** a font-scale setting, high-contrast variant, and full keyboard navigation.

---

## 5. Tech stack

| Part | Choice |
|---|---|
| Daemon | Go 1.23+, `go.mau.fi/whatsmeow`, `modernc.org/sqlite` (CGO-free) or `mattn/go-sqlite3` (FTS5) |
| IPC | JSON-RPC 2.0 over a Unix socket, newline-delimited; event stream via subscriptions |
| Notifications | `godbus/dbus` → freedesktop Notifications (actions + inline reply where supported by Clavis) |
| Media | ffmpeg (already installed), libwebp, PipeWire capture for voice notes |
| UI | Quickshell 0.3.1 config + QML (Qt 6.8), QtMultimedia for audio/video |
| Optional | whisper.cpp, tesseract, Claude API (`claude-sonnet-5-5` for summaries) |
| Packaging | `make install` → `~/.local`, systemd user unit, `.desktop` file, niri keybind fragment in `~/.config/niri/clavis/` |

**Prerequisites to install:** `golang` (not installed yet), `sqlite3`, `libwebp-dev`,
`qt6-multimedia-dev` / `qml6-module-qtmultimedia`; later `tesseract-ocr` and a whisper.cpp build.

---

## 6. Repository layout

```
hermes/
├─ PLAN.md
├─ daemon/                 # Go: hermesd + hermes CLI
│  ├─ cmd/hermesd/  cmd/hermes/
│  ├─ internal/wa/         # whatsmeow wrapper, event → model mapping
│  ├─ internal/store/      # SQLite schema, migrations, FTS
│  ├─ internal/rpc/        # JSON-RPC server + event bus
│  ├─ internal/media/      # download, cache, transcode, thumbnails
│  ├─ internal/notify/     # D-Bus notifications
│  ├─ internal/sched/      # scheduled sends, reminders, snooze
│  └─ internal/plugins/    # transcribe, ocr, summarise
├─ ui/                     # Quickshell config (qs -c hermes)
│  ├─ shell.qml
│  ├─ Services/HermesClient.qml   # socket + RPC + models
│  ├─ Views/ (ChatList, Conversation, MediaViewer, Settings, Pairing)
│  └─ Components/ (Bubble, Composer, Avatar, VoiceNote, ...)
├─ clavis-module/          # Bar widget, symlinked into Clavis Modules/Bar
├─ packaging/              # systemd unit, .desktop, niri keybind fragment
└─ docs/rpc.md             # API contract between daemon and UI
```

---

## 7. Roadmap

| Phase | Deliverable | Done when |
|---|---|---|
| **0. Spike** (1–2 days) | Go installed; a tiny whatsmeow program pairs by QR and prints incoming messages | You see your own messages in the terminal |
| **1. Daemon core** | hermesd: session persistence, message DB, history sync, JSON-RPC (`chats.list`, `messages.list`, `messages.send`, events), systemd unit, `hermes` CLI | `hermes send` works and survives a reboot |
| **2. UI MVP** | Pairing screen, chat list, conversation view, send/receive text, read ticks, typing, notifications with reply | Usable for daily texting |
| **3. Media** | Images, video, docs, voice notes (record and play), stickers, GIFs, media gallery | Usable for everything except calls |
| **4. Full parity** | Reactions, edits, deletes, polls, groups admin, communities, status, channels, archive/pin/mute sync, privacy settings | Matches the parity table in §2 |
| **5. Clavis integration** | Bar module, focus/DND sync, niri scratchpad keybind, matugen theming | Feels like part of the shell |
| **6. Productivity** | Search, snooze, reminders, notes, scheduled sends, snippets, command palette, export | Extras 1–12, 21–22 |
| **7. Intelligence** | Transcription, OCR, digests, summaries, date detection | Extras 13–20 |
| **8. Polish** | Animations, accessibility, backup, stats, performance (lazy lists, 100k+ messages) | |

---

## 8. Risks and how we handle them

| Risk | Mitigation |
|---|---|
| **Account ban.** Unofficial clients break WhatsApp ToS. Personal use is low risk, but not zero | Behave like a normal client: no bulk sends, rate-limit outgoing messages, no automation toward others, keep whatsmeow up to date. **Consider testing Phases 0–2 on a secondary number first.** |
| Protocol changes break the library | Pin the whatsmeow version and update deliberately; the daemon/UI split keeps the blast radius small |
| Session keys on disk = account access | DB in `~/.local/share/hermes` with `0700` permissions; optional encryption at rest; socket `0600` |
| No calls | Clear UI affordance that hands off to the phone or WhatsApp Web |
| Quickshell input limitations (IME, DnD) | Fallback to a Qt C++ host app with the same QML (see §1) |
| Qt 6.8 vs newer APIs | Same discipline as the Clavis compat branch |

---

## 9. Open questions

1. Test on a **secondary number** first, or go straight to your main one?
2. Should the summaries feature use the Claude API, or stay strictly offline (local LLM via llama.cpp)?
3. Is the name **Hermes** OK? (Greek messenger god, which fits your other project names.)
4. Main window: a normal tiled niri window, a scratchpad, or both?

## 10. Progress log

### 2026-10-09: MVP
**Toolchain:** Go 1.27.2 in `~/.local/go` (no sudo); whatsmeow `v0.0.0-20261007…`; SQLite via `modernc.org/sqlite` (no CGO).

**Daemon (`daemon/`), done:**
- QR and phone-number pairing; session persists; auto-reconnect
- History sync, plus on-demand older history from the phone
- LID→phone-number normalisation, so each person is one chat
- Messages: text, replies, mentions, reactions, edits, revokes, delete-for-me (synced), star (synced), forward
- Media: images, video, GIFs, voice notes (record via PipeWire, Opus, waveform), audio, documents, stickers (with WebP→PNG/GIF fallback), locations, contacts, polls (create, vote, decrypt votes)
- Receipts and ticks; typing and recording indicators; online/last seen; online only while the UI is focused, so the phone keeps its push notifications
- Archive, pin, mute, mark read/unread, synced with the phone via app state
- Group info (members and admins), avatars cached
- Desktop notifications grouped per chat, with Open and Mark-read actions; call alerts
- SQLite FTS5 full-text search; starred view
- Scheduled messages; focus mode with a VIP list; drafts per chat
- **Staying current:** advertises the latest WhatsApp Web version (refreshed at start and every 6h); handles `ClientOutdated` by refreshing and reconnecting; checks the Go proxy for whatsmeow updates daily and notifies; `hermes-update` bumps, vets, tests, builds and restarts, rolling back on failure
- `hermes` CLI: status, pair, chats, unread, read, send, file, search, schedule, focus, open, updates
- systemd user unit `hermesd.service`

**UI (`ui/`, Quickshell), done:**
- Material 3 theme from Clavis matugen colours (live); Google Sans Flex; colour emoji via a per-app fontconfig
- Nav rail (chats, search, scheduled, starred, focus toggle, connection dot)
- Chat list with filters (All, Unread, Personal, Groups), live search, archived view, context menu
- Conversation: day separators, grouped bubbles, rich text (*bold* _italic_ ~strike~ `code`, links), jumbo emoji, quotes with jump-to, reactions, ticks, edited/star markers, image viewer, video in mpv, voice player (mpv, 1×/1.5×/2×), documents, polls, locations, contacts
- Composer: reply/edit bar, emoji picker, attachments (photos, documents, stickers, audio, poll, schedule), voice recording, Enter to send, Shift+Enter for newline, Ctrl+Enter to schedule, ↑ to edit last message, drag-and-drop files
- Info panel (members, mute/pin/archive/VIP), new-chat dialog (contacts, groups, any number), Ctrl+K command palette, toasts, call banner, offline/update banner
- Pairing screen (QR or phone code)
- IPC (`qs -p … ipc call hermes open|toggle|commandPalette`), `hermes-ui` launcher, `Mod+Ctrl+W` niri bind, `.desktop` entry

### 2026-10-09: Triage inbox redesign
The UI read as a WhatsApp clone (chat list + bubbles). The backbone is now a **triage inbox** (Superhuman-style):
the home view groups chats by what they need from you, and chats are cleared, not scrolled.
- **Buckets** (`store.Bucket`, computed by the daemon, sent as `chat.bucket`): `reply` (a person wrote, you haven't
  answered or cleared it, last 7 days), `mention` (@-mention or reply to you in a group), `fyi` (unread group chatter,
  muted DMs, DMs from senders you never write to), `waiting` (you sent last, 3 days), `snoozed`, `done`.
  The self-chat only appears via snooze/remind-me. Rules are unit-tested in `store/triage_test.go`.
- **New columns** on `hermes_chats` (additive migration): `done_ts`, `snooze_until`, `snooze_msg`, `mention_ts`, `replied_ts`
  (`replied_ts` backfilled once from history). Done/snooze are local-only (WhatsApp has no equivalent) but mark the chat read.
- **RPC:** `chats.done {chat,value}`, `chats.snooze {chat,until,msg}`. Snoozes wake in the scheduler loop: the chat returns
  flagged unread with a "⏰ Back:" notification. A new DM or mention cancels a snooze early.
- **CLI:** `hermes inbox [--json]`, `hermes done <chat>`.
- **UI:** `InboxPane` + `InboxRow` (sections, urgency stripe, age, hover actions), `SnoozePicker` (presets, keys 1–6),
  rail Inbox/All, Done/Snooze in the conversation header, "Remind me about this…" on messages.
  Keys: `j/k` move, `Enter` open, `e` done, `s` snooze, `u` unread, `E` undo; global `Ctrl+E` done & next,
  `Ctrl+S` snooze, `Ctrl+Shift+E` undo, `Ctrl+Tab` next in inbox, `Esc` back to the list.
- Pre-migration DB backup: `~/.local/share/hermes/backup-pre-triage-20261009-1836.db`.

### 2026-10-09: Phase A, finish the redesign
- **Transcript conversation view:** `MessageBubble.qml` → `MessageRow.qml`. Left-aligned rows (avatar + name + time on the
  first of a run, follow-ups stacked with time/ticks in the gutter), day dividers as rules, no wallpaper. Rows that
  @-mention or reply to you get a tertiary accent bar. Hover toolbar: react, reply, remind me, more. Reaction chips toggle yours.
  Group senders use coloured initials (no per-member profile-picture fetches, to avoid hammering WhatsApp).
- **Composer:** outlined box, "Message <chat>", send/mic button inside the box.
- **Snooze:** typed times via `Format.parseWhen` ("in 2h", "tmr 14:00", "fri 9am", "18:30"); start typing in the dialog.
- **Reminders:** `chat.snoozeNote` (preview of `snooze_msg`) shows in the inbox row with ⏰; opening jumps to and highlights it.
- **Clavis bar:** pill counts `needsYou` (reply + mention), popup lists those first with an @ for mentions,
  header says "N need you · M FYI" / "Inbox zero", middle-click = done. Clavis must be restarted to load it
  (inotify watch limit is exhausted on this machine, so Quickshell can't hot-reload).

### 2026-10-09: Phase B (1) voice-note transcription
- `wa/transcribe.go`: a single background worker runs whisper.cpp (`nice`, half the cores) on incoming voice notes after
  auto-download; `messages.transcribe` for older ones; `transcribe.get/set` (kv `transcribe=off` disables).
  The transcript is stored as the message's `text` (voice notes never have text), so FTS, `Preview()` ("🎤 words")
  and the inbox get it for free; state lives in `extra.transcript` = pending | done | failed. Pending jobs requeue on restart.
  Non-speech tags ([BLANK_AUDIO], (music), *laughs*) are stripped.
- `packaging/hermes-whisper-setup [--cuda]`: builds whisper.cpp v1.9.5 into `~/.local/share/hermes/whisper`.
  With `--cuda`: GPU build + large-v3-turbo-q5_0 as `default.bin`, plus a CPU build + small-q5_1 as `fallback.bin`
  that the daemon retries on GPU failure. Benchmark (Ryzen 5600H / GTX 1650, 11 s clip): CPU small 5.5 s,
  CPU turbo 26 s, CUDA turbo 5.6 s. This machine uses the CUDA setup.
- `wa/mediaretry.go`: downloads that 404/410 (expired on WhatsApp's CDN) send a media-retry receipt asking the phone to
  re-upload, under both the PN and LID form of the chat, and wait 45 s for `events.MediaRetry`; the new direct path is saved
  to `raw`. **Untested end to end:** the first tries got no reply from the phone (probably asleep); retest with WhatsApp open on it.
- UI: transcript under the voice player (quoted), "Transcribing…" / "Couldn't transcribe · Retry", Transcribe in the message menu.

### 2026-10-09: Phase B (2) chat notes and snippets
- **Notes:** `hermes_chats.note` (migration), `chats.setNote`, `chat.note`. UI: tertiary strip under the conversation header,
  edited in place, autosaved after 600 ms (never overwritten while focused), toggle via the header note button;
  note icon with tooltip in inbox rows. CLI `hermes note <chat> [text|-]`.
- **Snippets:** `hermes_snippets(name, text)`, `snippets.list/set` (empty text deletes; names are one lowercase word),
  `snippets.changed` event. Composer: `;query` before the cursor opens a picker (↑/↓, Tab/Enter inserts, Esc dismisses,
  `;name␣` expands an exact match). Placeholders `{first}` `{name}` `{date}` `{time}`; in groups `{first}` drops out with its space.
  `SnippetsSheet` from Ctrl+K or the picker. CLI `hermes snippets`, `hermes snippet <name> [text]`.

### 2026-10-09: Phase B (3) reply from notifications
- Notifications carry a third action. If the server advertises `inline-reply` (KDE, swaync, dunst) it's the standard
  inline-reply action and `NotificationReplied(id, text)` sends straight away; otherwise it's a "Reply" button.
  Clavis advertises no inline-reply, and adding a text field to its Keystone island would mean reworking its layer-shell
  focus logic in a third-party shell, so instead "Reply" opens Hermes' own `QuickReply` window: a floating toplevel
  (niri rule on title "Reply · …") with the last 6 messages and a composer; Enter sends + marks read, Esc closes.
- Daemon: `notify.OnQuickReply` → `ui.quickReply` event, or launches `hermes-ui` with `HERMES_QUICK_REPLY=<jid>`
  (main window starts hidden). IPC: `qs -p ~/.local/share/hermes/ui ipc call hermes reply <jid>`.
- No Clavis changes needed.

### 2026-10-09: Phase C (1) Status
- Found no status had ever reached Hermes (no `status@broadcast` sender keys). Statuses posted before linking come in
  history sync's `StatusV3Messages`, which was ignored; now ingested (`storeHistoryStatuses`). Live statuses are logged
  ("Status from …") so we can confirm they arrive; none had in the first ~6 h after linking.
- `wa/status.go`: `status.list` (last 24 h grouped by author, unseen first; seen state in `hermes_status_seen`),
  `status.view` (local seen + read receipt unless kv `status_receipts=off`), `status.reply` (DM quoting the status with
  RemoteJID status@broadcast, like the phone), `status.postText` (ExtendedTextMessage with BackgroundArgb),
  `status.postFile` (SendFile to status@broadcast; whatsmeow picks recipients from status privacy).
  Text-status background colours are kept in `extra.bg`.
- UI: Status rail tab with unseen badge, `StatusPane` (segmented `StatusRing`s, my status, private-viewing switch),
  `StatusViewer` (9:16 stage, progress bars, ←/→/Space/Esc/R, tap zones, auto-advance 6 s, videos in mpv, reply box),
  `StatusComposer` (coloured text or photo/video with caption, explicit Post).
- Fixed `Theme.alpha()/mix()` silently turning colour *strings* into black.
- **Untested live:** posting (it goes to all your contacts) and receiving real statuses.

### 2026-10-09: Phase C (2) groups, disappearing messages, blocking
- `wa/groups.go`: `groups.members` (add/remove/promote/demote; per-member results, 403 = their privacy blocks adds),
  `groups.setName`, `groups.setTopic`, `groups.setFlags` (announce/locked), `groups.inviteLink` (copy/reset), `groups.leave`,
  `chats.setDisappearing` (0/24h/7d/90d), `blocklist.get/set`. `GroupInfo` now reports `iAmAdmin`, `iAmMember`, `topicId`,
  and each member's raw `id` (often a LID), which admin actions must use.
- `InfoPanel` rewritten: edit name/description when allowed, disappearing-messages menu, admin section (invite link,
  two toggles), member ⋮ menu, Add-members sheet (contact search + typed numbers, chips), Leave/Block with confirmations.
  New `Toggle` (M3 switch) replaces Basic `Switch`.
- Live read-only checks: blocklist (29) and a 755-member group's info (finds you, not admin). Mutating actions untested live.

### 2026-10-09: Phase C (3) settings
- `wa/settings.go`: `settings.get` (push name, About via GetUserInfo, phone, 8 privacy settings), `settings.setPrivacy`
  (validated against the values the phone offers), `settings.setAbout` (≤139), `settings.setName` (app-state push name, ≤25).
  Own profile photo is left to the phone (whatsmeow only documents group photos).
- `SettingsPane` (gear in the rail, or Ctrl+K): profile, privacy choices, read receipts toggle, blocked list with Unblock,
  Hermes options (transcription, private status viewing, snippets, compatibility). Live read of settings works.

### 2026-10-09: Phase C (4) channels
- `wa/channels.go`: `channels.list` (GetSubscribedNewsletters; picture cached from URL or `mmg.whatsapp.net`+DirectPath),
  `channels.fetch` (40 posts via GetNewsletterMessages, converted and stored as messages in the channel chat with
  `extra.serverId/views/reactionCounts`; `view:true` marks them viewed), `channels.react` (needs serverId),
  `channels.follow` (invite link), `channels.unfollow`. Channels excluded from ListChats, TotalUnread and notifications.
- UI: Channels rail tab and `ChannelsPane` (follow-by-link field, list, right-click unfollow); opening a channel reuses
  the conversation view in read-only mode (no composer, no Done/Snooze/call/info), with 👁 view counts and aggregate
  reaction chips. Live: 2 followed channels listed with pictures; fetch stored 39 posts.

**Phase C is complete.**

### 2026-10-09: Phase D, your data
- **Export** (`wa/export.go`, `export.chat`): one Markdown file per chat in the export folder (kv `export_dir`, default
  `~/Documents/WhatsApp`; set to `~/Projects/BObs vault/WhatsApp` on this machine). YAML frontmatter (`whatsapp: <jid>`,
  chat, type, messages, `tags: [whatsapp]`), the private note as a callout, `## YYYY-MM-DD (Day)` per day,
  `**HH:MM · Name:** text`, quotes, reactions, voice transcripts. Downloaded media is copied to `attachments/<chat>/` and
  embedded with relative `![](<…>)` links; undownloaded media becomes a placeholder (`download:true` fetches it first).
  Re-export regenerates the file; a different chat with the same name gets `Name (<number>).md` (owner read from frontmatter).
  Lines that would become headings/quotes/lists and `[[` are escaped. UI: chat info panel and Ctrl+K. CLI `hermes export`.
- **Auto-file** (`wa/autofile.go`): rules in kv `autofile_rules` (chat or any, kind, extensions, name/caption match, folder).
  The first matching rule downloads the attachment (≤200 MB) and copies it in; Hermes keeps its copy. The target path is
  saved in `extra.filed` (document rows show "· in <folder>"). Also "Save to folder…" in the message menu (`messages.saveTo`).
  UI: `AutoFileSheet` (Settings, chat info, Ctrl+K). CLI `hermes autofile [add|rm]`.
- **Backup** (`wa/backup.go`, `internal/backup`): `VACUUM INTO` snapshot (Hermes + whatsmeow tables, so it includes the
  device link) + optional media, tar.gz, encrypted with an age scrypt passphrase (≥8 chars). Written to kv `backup_dir`
  (default `~/Documents/Hermes backups`), keeps the last 5. `hermes backup extract <file> <dir>` runs without hermesd and
  only extracts into an empty folder; restoring is a manual copy with hermesd stopped. No scheduled backups (would need a
  stored passphrase). Verified live: 6.4 MB backup, extracted DB passes integrity_check with all messages and the device row.
- **Storage** (`wa/stats.go`): `storage.stats` (DB/media/cache bytes, per-chat messages + media) and `storage.clean`
  (older-than / min-size / per-chat, dry run by default in the CLI). Only deletes files inside the media folder, keeps
  starred messages, clears `media_path` so the message can be downloaded again. UI: `StorageSheet`; CLI `hermes storage`, `hermes clean`.
- Gotcha: hermesd has `PrivateTmp=yes`, so an export/backup folder under `/tmp` lands in the service's private tmp.

### 2026-10-09: Phase E, intelligence (all local)
- Open question 2 answered: everything runs offline. **Ollama** was already on this machine (gemma3:4b, gemma4:e4b, qwen3:8b);
  `wa/llm.go` talks to it (kv `llm_url`, `llm_model` = "" picks the first of gemma3:4b → qwen2.5:3b → … installed; kv `llm=off`
  disables). Streaming `/api/chat`, `keep_alive` 10 m, `num_ctx` 8192, `<think>` blocks stripped. gemma3:4b: ~7 s cold load, then
  ~30 tok/s on the GTX 1650; 50-message catch-up ≈ 17 s cold.
  **Speed-up (2026-10-10):** Ollama's own estimate left gemma3:4b 45 % on the CPU (it only used 2.9 of 4 GB), so requests
  now ask for all layers on the GPU (`num_gpu` 999, falls back to Ollama's split on error; kv `llm_gpu=auto` disables) and
  size `num_ctx` to the prompt. Reading the prompt is the bottleneck (~170 tok/s even fully on a GTX 1650), so the transcript
  is compact: consecutive messages merged with " / ", first names, times only after 20-min gaps, URLs → "[link: site]".
  150-message summary: 58 s → 17–29 s warm. Prompt now forbids a preamble and limits "For you" to explicit mentions/replies.
  Tried qwen2.5 1.5B (user's local GGUF, imported as `qwen2.5-1.5b-local`): 12.5 s but missed every @-mention and garbled
  dates, so gemma3:4b stays the default. DeepSeek-R1 distills were ruled out: they think for hundreds of tokens first.
- **Translate** (`messages.translate`, cached in `hermes_translations`): message menu → Translate; shown under the message,
  Hide to dismiss. Prompt handles romanised Hindi/Kannada ("haan bhai…"). Target language kv `translate_lang` (default English).
- **Catch-up summaries** (`chats.summarize` scope unread | recent n ≤ 400, streamed as `summary` events by token): header
  button (only when a model is ready), Ctrl+K, `hermes catchup <chat> [--last N]`. Sections Gist / For you / Plans & dates / Decisions.
- **Digest mode** (`wa/digest.go`, kv `digest_chats` {jid: minutes}): notifications for those chats are held and sent as one
  roundup ("Hostel · 23 new / From Ravi, Asha and 3 others / last lines") every N minutes; mentions/replies to you bypass it;
  reading the chat drops the pending digest. Optional one-line LLM gist (kv `digest_ai`). Chat info → Digest notifications;
  `hermes digest <chat> <min|off>`.
- **Dates in messages** (`Format.findWhen`, UI only; tests `node ui/tests/format.test.js`): "fri 5pm", "kal 6 baje", "15/10",
  "12th oct at 9:30", "aaj raat", "parso shaam 5 baje"… read relative to when the message was sent; only upcoming ones get a chip.
  Bare numbers and a lone "today" are ignored; 1–7 without am/pm means evening. Chip → Remind me then / an hour before
  (Hermes reminder) or Add to Google Calendar (opens a prefilled event page; nothing is added automatically). To-do detection
  beyond dates was left out: too noisy with regexes, and running the LLM on every message isn't worth it.
- **OCR** (`wa/ocr.go`, `packaging/hermes-ocr-setup`): RapidOCR (ONNX, CPU) in `~/.local/share/hermes/ocr/venv`, ready once
  `.ready` exists. One long-lived Python helper (`assets/ocr.py`, embedded) under `nice`, 2 threads, exits after 3 idle minutes.
  New images are queued after download; a backfill scans 40 older downloaded images every 10 minutes. Text goes to `hermes_ocr`
  + `hermes_ocr_fts`; search merges hits, marked 🔍. Message menu → Copy text from image (`messages.ocr`).
- Settings → "Intelligence · runs on this computer": OCR, translate & summarise, model, translate language, digest gist.

**Not done yet / next:**
- [ ] Live verification: media retry (phone awake), posting a status, group admin actions, receiving live statuses
- [ ] Polish: smart folders, animations, performance with 100k+ messages
- [x] `qt6-image-formats-plugins` installed: native (animated) WebP stickers
