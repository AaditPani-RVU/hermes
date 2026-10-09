pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import "Format.js" as F

// Connection to hermesd plus the live models the views bind to.
Singleton {
    id: root

    readonly property string socketPath: Quickshell.env("HERMES_SOCKET") || ((Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/hermes.sock")

    property bool daemonUp: false
    property var status: ({ state: "starting" })
    readonly property bool loggedIn: !!status.meJid
    readonly property bool ready: daemonUp && loggedIn

    property int unreadChats: 0
    property int unreadMessages: 0
    property bool showArchived: false

    property string currentChat: ""
    property var currentInfo: null // chat object for the header
    property bool loadingOlder: false
    property bool reachedTop: false
    property var presence: ({}) // jid -> { online, lastSeen }
    property var typing: ({}) // chat -> { names: {jid: name}, recording }
    property int avatarRev: 0
    property var avatars: ({})
    property var updateInfo: null
    property var focusState: ({ active: false, until: 0, vips: [] })
    property bool recording: false
    property var scheduled: []
    property bool windowActive: false

    signal toast(string text, bool error)
    signal openChatRequested(string jid)
    signal incomingCall(string name, bool video)
    signal messagesLoaded
    signal manageSnippetsRequested
    property var snippets: [] // [{trigger, text}]
    property string jumpTo: "" // message to scroll to once the open chat loads (reminders)

    readonly property ListModel chats: ListModel {}
    // Triage view of `chats`: header rows (kind "header") followed by their chats.
    readonly property ListModel inbox: ListModel {}
    property var inboxCounts: ({ reply: 0, mention: 0, fyi: 0, waiting: 0, snoozed: 0 })
    readonly property int needsYou: inboxCounts.reply + inboxCounts.mention
    property var collapsed: ({ waiting: true, snoozed: true })
    property string lastDone: ""
    readonly property var buckets: [
        { key: "reply", title: "Needs reply", icon: "reply" },
        { key: "mention", title: "Mentions", icon: "alternate_email" },
        { key: "fyi", title: "FYI", icon: "visibility" },
        { key: "waiting", title: "Waiting on them", icon: "hourglass_top" },
        { key: "snoozed", title: "Snoozed", icon: "snooze" }
    ]
    readonly property ListModel messages: ListModel {} // index 0 = newest (list is bottom-to-top)

    property int _nextId: 1
    property var _pending: ({})

    // ---- transport ----

    function call(method, params, cb) {
        if (!sock.connected) {
            if (cb)
                cb(null, "Hermes daemon is not running");
            return;
        }
        const id = _nextId++;
        if (cb)
            _pending[id] = cb;
        sock.write(JSON.stringify({ id: id, method: method, params: params || {} }) + "\n");
        sock.flush();
    }

    // Like call(), but surfaces errors as a toast.
    function act(method, params, okText, cb) {
        call(method, params, (res, err) => {
            if (err)
                root.toast(err, true);
            else if (okText)
                root.toast(okText, false);
            if (cb)
                cb(res, err);
        });
    }

    function handleLine(line) {
        let msg;
        try {
            msg = JSON.parse(line);
        } catch (e) {
            console.warn("hermes: bad line", e);
            return;
        }
        if (msg.event !== undefined) {
            handleEvent(msg.event, msg.data);
            return;
        }
        const cb = _pending[msg.id];
        if (cb) {
            delete _pending[msg.id];
            cb(msg.result, msg.error ? msg.error.message : null);
        }
    }

    Socket {
        id: sock
        path: root.socketPath
        connected: true
        parser: SplitParser {
            onRead: data => root.handleLine(data)
        }
        onConnectionStateChanged: {
            root.daemonUp = connected;
            if (connected) {
                root._pending = {};
                root.call("events.subscribe", { ui: true });
                root.refreshAll();
            }
        }
    }

    Timer {
        // Reconnect when the daemon restarts.
        interval: 2000
        running: !sock.connected
        repeat: true
        onTriggered: sock.connected = true
    }

    function refreshAll() {
        call("status", {}, res => {
            if (res)
                root.status = res;
        });
        call("chats.unread", {}, res => {
            if (res) {
                root.unreadChats = res.chats;
                root.unreadMessages = res.messages;
            }
        });
        call("focus.get", {}, res => {
            if (res)
                root.focusState = res;
        });
        reloadChats();
        refreshScheduled();
        refreshSnippets();
        if (currentChat)
            loadMessages(currentChat);
    }

    // ---- chats ----

    function chatFields(c) {
        return {
            jid: c.jid,
            name: c.name || c.jid.split("@")[0],
            isGroup: !!c.isGroup,
            lastTs: c.lastTs || 0,
            lastPreview: c.lastPreview || "",
            lastSender: c.lastSender || "",
            lastFromMe: !!c.lastFromMe,
            lastStatus: c.lastStatus || 0,
            unread: c.unread || 0,
            markedUnread: !!c.markedUnread,
            archived: !!c.archived,
            pinnedTs: c.pinnedTs || 0,
            mutedUntil: c.mutedUntil || 0,
            ephemeral: c.ephemeral || 0,
            avatarPath: c.avatarPath || "",
            draft: c.draft || "",
            bucket: c.bucket || "done",
            doneTs: c.doneTs || 0,
            snoozeUntil: c.snoozeUntil || 0,
            snoozeMsg: c.snoozeMsg || "",
            snoozeNote: c.snoozeNote || "",
            note: c.note || ""
        };
    }

    function chatLess(a, b) {
        if ((a.pinnedTs > 0) !== (b.pinnedTs > 0))
            return a.pinnedTs > 0;
        if (a.pinnedTs !== b.pinnedTs && a.pinnedTs > 0)
            return a.pinnedTs > b.pinnedTs;
        return a.lastTs > b.lastTs;
    }

    function reloadChats() {
        call("chats.list", { archived: showArchived }, (res, err) => {
            if (err || !res)
                return;
            chats.clear();
            for (const c of res)
                chats.append(chatFields(c));
            if (currentChat)
                updateCurrentInfo();
            rebuildInbox.restart();
        });
    }

    // ---- triage ----

    Timer {
        id: rebuildInbox
        interval: 30
        onTriggered: root.buildInbox()
    }
    Timer {
        // Buckets age (waiting expires, stale chats drop out), so refresh now and then.
        interval: 5 * 60 * 1000
        running: root.ready
        repeat: true
        onTriggered: if (!root.showArchived) root.reloadChats()
    }

    function headerRow(b, count) {
        const f = chatFields({ jid: "#" + b.key, name: b.title, bucket: b.key });
        f.kind = "header";
        f.count = count;
        f.icon = b.icon;
        return f;
    }

    function buildInbox() {
        if (showArchived)
            return; // chats holds the archive right now; keep the last inbox
        const groups = {};
        const counts = { reply: 0, mention: 0, fyi: 0, waiting: 0, snoozed: 0 };
        for (const b of buckets)
            groups[b.key] = [];
        for (let i = 0; i < chats.count; i++) {
            const c = chats.get(i);
            if (groups[c.bucket] === undefined)
                continue;
            const f = chatFields(c);
            f.kind = "chat";
            f.count = 0;
            f.icon = "";
            groups[c.bucket].push(f);
            counts[c.bucket]++;
        }
        // Oldest first in "Needs reply" (who's waited longest), newest first elsewhere; snoozes by wake time.
        groups.reply.sort((a, b) => a.lastTs - b.lastTs);
        groups.snoozed.sort((a, b) => a.snoozeUntil - b.snoozeUntil);
        const rows = [];
        for (const b of buckets) {
            if (groups[b.key].length === 0)
                continue;
            rows.push(headerRow(b, groups[b.key].length));
            if (!collapsed[b.key])
                for (const f of groups[b.key])
                    rows.push(f);
        }
        // Patch in place where possible so the ListView keeps its delegates and scroll position.
        for (let i = 0; i < rows.length; i++) {
            if (i < inbox.count && inbox.get(i).jid === rows[i].jid)
                inbox.set(i, rows[i]);
            else if (i < inbox.count) {
                let j = i + 1;
                while (j < inbox.count && inbox.get(j).jid !== rows[i].jid)
                    j++;
                if (j < inbox.count) {
                    inbox.move(j, i, 1);
                    inbox.set(i, rows[i]);
                } else
                    inbox.insert(i, rows[i]);
            } else
                inbox.append(rows[i]);
        }
        if (inbox.count > rows.length)
            inbox.remove(rows.length, inbox.count - rows.length);
        inboxCounts = counts;
    }

    function toggleSection(key) {
        const c = Object.assign({}, collapsed);
        c[key] = !c[key];
        collapsed = c;
        buildInbox();
    }

    // Next actionable chat in inbox order after `jid` (wrapping), skipping headers and `jid` itself.
    function nextInInbox(jid) {
        const n = inbox.count;
        let start = -1;
        for (let i = 0; i < n; i++)
            if (inbox.get(i).jid === jid) {
                start = i;
                break;
            }
        for (let k = 1; k <= n; k++) {
            const r = inbox.get((start + k + n) % n);
            if (r.kind === "chat" && r.jid !== jid && ["reply", "mention", "fyi"].indexOf(r.bucket) >= 0)
                return r.jid;
        }
        return "";
    }

    function markDone(jid, advance) {
        if (!jid)
            return;
        const next = advance && jid === currentChat ? nextInInbox(jid) : "";
        lastDone = jid;
        act("chats.done", { chat: jid, value: true }, "Done · Ctrl+Shift+E to undo");
        if (advance && jid === currentChat) {
            if (next)
                openChat(next);
            else
                closeChat();
        }
    }

    function undoDone() {
        if (!lastDone)
            return;
        act("chats.done", { chat: lastDone, value: false }, "Back in your inbox");
        lastDone = "";
    }

    function snooze(jid, until, msgId) {
        if (!jid)
            return;
        const next = jid === currentChat ? nextInInbox(jid) : "";
        act("chats.snooze", { chat: jid, until: until, msg: msgId || "" }, until ? "Snoozed until " + F.whenLabel(until) : "Unsnoozed");
        if (until && jid === currentChat) {
            if (next)
                openChat(next);
            else
                closeChat();
        }
    }

    onShowArchivedChanged: reloadChats()

    function chatIndex(jid) {
        for (let i = 0; i < chats.count; i++)
            if (chats.get(i).jid === jid)
                return i;
        return -1;
    }

    function upsertChat(c) {
        const f = chatFields(c);
        let idx = chatIndex(f.jid);
        const visible = f.archived === showArchived && (f.lastTs > 0 || f.draft !== "");
        if (!visible) {
            if (idx >= 0)
                chats.remove(idx);
            if (f.jid === currentChat)
                currentInfo = f;
            rebuildInbox.restart();
            return;
        }
        if (idx >= 0)
            chats.set(idx, f);
        else {
            chats.insert(0, f);
            idx = 0;
        }
        // Bubble into sorted position.
        let target = 0;
        while (target < chats.count && (target === idx || chatLess(chats.get(target), f)))
            target++;
        if (target > idx)
            target--;
        if (target !== idx)
            chats.move(idx, target, 1);
        if (f.jid === currentChat)
            currentInfo = f;
        rebuildInbox.restart();
    }

    function updateCurrentInfo() {
        const idx = chatIndex(currentChat);
        if (idx >= 0) {
            currentInfo = chats.get(idx);
            return;
        }
        call("chats.get", { chat: currentChat }, res => {
            if (res && res.jid === currentChat)
                currentInfo = chatFields(res);
        });
    }

    function avatarFor(jid) {
        void avatarRev;
        if (avatars[jid] !== undefined)
            return avatars[jid];
        avatars[jid] = "";
        // Defer: this runs inside bindings, which must not trigger network calls synchronously.
        Qt.callLater(() => call("chats.avatar", { chat: jid }, (res, err) => {
            if (!err && res) {
                avatars[jid] = res;
                avatarRev++;
            }
        }));
        return "";
    }

    // ---- messages ----

    function msgFields(m) {
        return {
            chat: m.chat,
            id: m.id,
            sender: m.sender || "",
            senderName: m.senderName || "",
            fromMe: !!m.fromMe,
            ts: m.ts || 0,
            type: m.type || "text",
            text: m.text || "",
            mediaMime: m.mediaMime || "",
            mediaPath: m.mediaPath || "",
            thumbPath: m.thumbPath || "",
            mediaSize: m.mediaSize || 0,
            mediaW: m.mediaW || 0,
            mediaH: m.mediaH || 0,
            mediaSecs: m.mediaSecs || 0,
            fileName: m.fileName || "",
            quotedId: m.quotedId || "",
            quotedSender: m.quotedSender || "",
            quotedText: m.quotedText || "",
            status: m.status === undefined ? 1 : m.status,
            edited: !!m.edited,
            revoked: !!m.revoked,
            viewOnce: !!m.viewOnce,
            starred: !!m.starred,
            extra: m.extra || "",
            reactions: JSON.stringify(m.reactions || [])
        };
    }

    function openChat(jid) {
        if (!jid)
            return;
        if (currentChat === jid) {
            markRead();
            return;
        }
        currentChat = jid;
        reachedTop = false;
        const ci = chatIndex(jid);
        jumpTo = ci >= 0 ? chats.get(ci).snoozeMsg : "";
        messages.clear();
        updateCurrentInfo();
        loadMessages(jid);
        markRead();
        reportFocus();
        call("presence.subscribe", { chat: jid });
    }

    function closeChat() {
        currentChat = "";
        currentInfo = null;
        messages.clear();
        reportFocus();
    }

    function loadMessages(jid) {
        call("messages.list", { chat: jid, limit: 60 }, (res, err) => {
            if (err || !res || jid !== currentChat)
                return;
            messages.clear();
            for (let i = res.length - 1; i >= 0; i--)
                messages.append(msgFields(res[i]));
            reachedTop = res.length < 60;
            messagesLoaded();
        });
    }

    function loadOlder() {
        if (loadingOlder || reachedTop || messages.count === 0)
            return;
        loadingOlder = true;
        const jid = currentChat;
        const before = messages.get(messages.count - 1).ts;
        call("messages.list", { chat: jid, before: before, limit: 60 }, (res, err) => {
            loadingOlder = false;
            if (err || !res || jid !== currentChat)
                return;
            for (let i = res.length - 1; i >= 0; i--)
                messages.append(msgFields(res[i]));
            if (res.length < 60) {
                reachedTop = true;
                // Ask the phone for more history; it arrives via history sync.
                call("chats.loadOlder", { chat: jid });
            }
        });
    }

    function msgIndex(id) {
        for (let i = 0; i < messages.count; i++)
            if (messages.get(i).id === id)
                return i;
        return -1;
    }

    function upsertMessage(m) {
        if (m.chat !== currentChat || m.type === "reaction")
            return;
        const f = msgFields(m);
        const idx = msgIndex(f.id);
        if (idx >= 0) {
            messages.set(idx, f);
            return;
        }
        // Insert keeping newest-first order (usually index 0).
        let pos = 0;
        while (pos < messages.count && messages.get(pos).ts > f.ts)
            pos++;
        messages.insert(pos, f);
        if (!f.fromMe && windowActive)
            markReadSoon.restart();
    }

    Timer {
        id: markReadSoon
        interval: 600
        onTriggered: root.markRead()
    }

    function markRead() {
        if (!currentChat)
            return;
        const idx = chatIndex(currentChat);
        if (idx >= 0 && chats.get(idx).unread === 0 && !chats.get(idx).markedUnread)
            return;
        call("chats.markRead", { chat: currentChat });
    }

    function reportFocus() {
        call("ui.focus", { chat: windowActive ? currentChat : "", active: windowActive });
    }

    onWindowActiveChanged: {
        reportFocus();
        if (windowActive)
            markRead();
    }

    // ---- actions ----

    function sendText(text, replyTo) {
        act("messages.sendText", { chat: currentChat, text: text, replyTo: replyTo || "" });
    }
    function sendFile(path, caption, kind, replyTo) {
        root.toast("Sending " + path.split("/").pop() + "…", false);
        act("messages.sendFile", { chat: currentChat, path: path, caption: caption || "", kind: kind || "auto", replyTo: replyTo || "" });
    }
    function react(id, emoji) {
        act("messages.react", { chat: currentChat, id: id, emoji: emoji });
    }
    function download(id, cb) {
        call("messages.download", { chat: currentChat, id: id }, (res, err) => {
            if (err)
                root.toast("Download failed: " + err, true);
            if (cb)
                cb(res, err);
        });
    }
    function setTyping(composing) {
        if (currentChat)
            call("presence.typing", { chat: currentChat, composing: composing });
    }
    function refreshSnippets() {
        call("snippets.list", {}, res => {
            if (res)
                root.snippets = res;
        });
    }

    // Fill a snippet's placeholders for the open chat: {first} {name} {date} {time}
    function expandSnippet(text) {
        const name = currentInfo && !currentInfo.isGroup ? currentInfo.name.replace(/^~ /, "") : "";
        const d = new Date();
        // In groups there's no single name: drop the placeholder and the space before it ("Hey {first}," → "Hey,").
        const first = name.split(" ")[0] || "";
        return text.replace(first ? /\{first\}/g : / ?\{first\}/g, first)
            .replace(name ? /\{name\}/g : / ?\{name\}/g, name)
            .replace(/\{date\}/g, d.toLocaleDateString(Qt.locale(), "d MMMM yyyy"))
            .replace(/\{time\}/g, F.clock(d / 1000));
    }

    function refreshScheduled() {
        call("schedule.list", {}, res => {
            if (res)
                root.scheduled = res;
        });
    }

    // ---- events ----

    Timer {
        id: reloadChatsSoon
        interval: 400
        onTriggered: root.reloadChats()
    }

    Timer {
        id: typingExpiry
        interval: 1000
        repeat: true
        running: Object.keys(root.typing).length > 0
        onTriggered: {
            const now = Date.now();
            let changed = false;
            const t = root.typing;
            for (const chat in t) {
                if (t[chat].until < now) {
                    delete t[chat];
                    changed = true;
                }
            }
            if (changed)
                root.typing = Object.assign({}, t);
        }
    }

    function handleEvent(name, data) {
        switch (name) {
        case "state":
            const wasLoggedIn = loggedIn;
            status = data;
            if (!wasLoggedIn && loggedIn)
                refreshAll();
            break;
        case "chat":
            upsertChat(data);
            break;
        case "chats.changed":
            reloadChatsSoon.restart();
            break;
        case "messages.changed":
            // Sender names were re-resolved; refresh the open conversation.
            if (currentChat)
                loadMessages(currentChat);
            break;
        case "unread":
            unreadChats = data.chats;
            unreadMessages = data.messages;
            break;
        case "message":
            upsertMessage(data);
            if (data.chat === currentChat && !data.fromMe && typing[data.chat]) {
                const t = Object.assign({}, typing);
                delete t[data.chat];
                typing = t;
            }
            break;
        case "message.deleted":
            if (data.chat === currentChat) {
                const idx = msgIndex(data.id);
                if (idx >= 0)
                    messages.remove(idx);
            }
            break;
        case "receipt":
            if (data.chat === currentChat) {
                for (const id of data.ids) {
                    const idx = msgIndex(id);
                    if (idx >= 0 && messages.get(idx).status < data.status)
                        messages.setProperty(idx, "status", data.status);
                }
            }
            break;
        case "media":
            if (data.chat === currentChat) {
                const idx = msgIndex(data.id);
                if (idx >= 0)
                    messages.setProperty(idx, "mediaPath", data.path);
            }
            break;
        case "typing":
            const t = Object.assign({}, typing);
            if (data.composing) {
                const entry = t[data.chat] || { names: {}, recording: false };
                entry.names[data.sender] = data.name;
                entry.recording = data.recording;
                entry.until = Date.now() + 15000;
                t[data.chat] = entry;
            } else if (t[data.chat]) {
                delete t[data.chat].names[data.sender];
                if (Object.keys(t[data.chat].names).length === 0)
                    delete t[data.chat];
            }
            typing = t;
            break;
        case "presence":
            const p = Object.assign({}, presence);
            p[data.jid] = { online: data.online, lastSeen: data.lastSeen };
            presence = p;
            break;
        case "avatar.changed":
            delete avatars[data.jid];
            avatarRev++;
            break;
        case "ui.open":
            openChatRequested(data.chat || "");
            break;
        case "call":
            incomingCall(data.name, data.video);
            break;
        case "update":
            updateInfo = data;
            break;
        case "recording":
            recording = data.active;
            break;
        case "snippets.changed":
            refreshSnippets();
            break;
        case "scheduled":
        case "scheduled.changed":
            refreshScheduled();
            break;
        case "focus":
            call("focus.get", {}, res => {
                if (res)
                    root.focusState = res;
            });
            break;
        case "sync":
            reloadChatsSoon.restart();
            break;
        }
    }
}
