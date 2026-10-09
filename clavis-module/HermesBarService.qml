pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// Lightweight hermesd client for the Clavis bar: how many chats need you, the
// chats to look at first, quick replies and focus mode. The full UI lives in `hermes-ui`.
Singleton {
    id: root

    readonly property string socketPath: Quickshell.env("HERMES_SOCKET") || ((Quickshell.env("XDG_RUNTIME_DIR")
                                                                             || "/tmp") + "/hermes.sock")
    readonly property int recentCount: 6

    property bool daemonUp: false
    property bool loggedIn: false
    property int unreadChats: 0
    property int unreadMessages: 0
    property bool focusActive: false
    property var recent: []
    // Triage counts from the daemon's buckets (reply + mention = needs you).
    property int needsYou: 0
    property int fyi: 0

    property int _nextId: 1
    property var _pending: ({})
    property var _all: ({}) // jid -> chat (non-archived)

    function call(method, params, cb) {
        if (!sock.connected) {
            if (cb)
                cb(null, qsTr("Hermes daemon is not running"));
            return;
        }
        const id = _nextId++;
        if (cb)
            _pending[id] = cb;
        sock.write(JSON.stringify({
            "id": id,
            "method": method,
            "params": params || {}
        }) + "\n");
        sock.flush();
    }

    function refresh() {
        call("status", {}, res => {
            root.loggedIn = !!(res && res.meJid);
        });
        call("chats.unread", {}, res => {
            if (res) {
                root.unreadChats = res.chats;
                root.unreadMessages = res.messages;
            }
        });
        call("focus.get", {}, res => {
            if (res)
                root.focusActive = !!res.active;
        });
        reloadChats();
    }

    function reloadChats() {
        call("chats.list", {
            "archived": false
        }, res => {
            if (!res)
                return;
            const map = {};
            for (const c of res)
                map[c.jid] = c;
            root._all = map;
            root._publish();
        });
    }

    // Chats that need you come first (like the inbox), then the most recent.
    function _rank(c) {
        return c.bucket === "reply" || c.bucket === "mention" ? 0 : c.bucket === "fyi" ? 1 : 2;
    }

    function _publish() {
        const all = Object.values(root._all).filter(c => !c.archived && c.lastTs > 0);
        let needs = 0, fyi = 0;
        for (const c of all) {
            if (c.bucket === "reply" || c.bucket === "mention")
                needs++;
            else if (c.bucket === "fyi")
                fyi++;
        }
        root.needsYou = needs;
        root.fyi = fyi;
        root.recent = all.sort((a, b) => (root._rank(a) - root._rank(b)) || (b.lastTs - a.lastTs)).slice(0, root.recentCount);
    }

    function markDone(jid) {
        call("chats.done", {
            "chat": jid,
            "value": true
        });
    }

    function _upsert(chat) {
        if (!chat || !chat.jid)
            return;
        const map = Object.assign({}, root._all);
        map[chat.jid] = chat;
        root._all = map;
        root._publish();
    }

    function sendText(jid, text, cb) {
        call("messages.sendText", {
            "chat": jid,
            "text": text
        }, (res, err) => {
            if (!err)
                call("chats.markRead", {
                    "chat": jid
                });
            if (cb)
                cb(err);
        });
    }

    function markRead(jid) {
        call("chats.markRead", {
            "chat": jid
        });
    }

    function openChat(jid) {
        // ui.open launches hermes-ui if needed and focuses the chat.
        call("ui.open", {
            "chat": jid || ""
        });
    }

    function toggleFocus() {
        call("focus.set", {
            "until": root.focusActive ? 0 : -1
        }, (res, err) => {
            if (!err)
                root.focusActive = !root.focusActive;
        });
    }

    function _handleLine(line) {
        let msg;
        try {
            msg = JSON.parse(line);
        } catch (e) {
            return;
        }
        if (msg.event !== undefined) {
            switch (msg.event) {
            case "unread":
                root.unreadChats = msg.data.chats;
                root.unreadMessages = msg.data.messages;
                break;
            case "chat":
                root._upsert(msg.data);
                break;
            case "chats.changed":
                reloadDebounce.restart();
                break;
            case "focus":
                call("focus.get", {}, res => {
                    if (res)
                        root.focusActive = !!res.active;
                });
                break;
            case "state":
                root.loggedIn = !!(msg.data && msg.data.meJid);
                break;
            }
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
            onRead: data => root._handleLine(data)
        }
        onConnectionStateChanged: {
            root.daemonUp = connected;
            if (connected) {
                root._pending = {};
                // Not a UI client: the daemon keeps sending desktop notifications.
                root.call("events.subscribe", {});
                root.refresh();
            }
        }
    }

    Timer {
        // Reconnect when the daemon restarts.
        interval: 5000
        running: !sock.connected
        repeat: true
        onTriggered: sock.connected = true
    }

    Timer {
        id: reloadDebounce

        interval: 800
        onTriggered: root.reloadChats()
    }
}
