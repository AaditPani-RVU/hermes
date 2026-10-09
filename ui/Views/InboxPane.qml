import QtQuick
import QtQuick.Controls
import qs.Services
import qs.Components
import "../Services/Format.js" as F

// Triage inbox: what needs you, grouped, cleared with e / snoozed with s.
Rectangle {
    id: pane
    color: Theme.surfaceContainerLow
    signal newChat
    signal snoozeRequested(string jid, string name, var item)
    signal chatOpened

    readonly property int actionable: Hermes.inboxCounts.reply + Hermes.inboxCounts.mention + Hermes.inboxCounts.fyi

    function focusList() {
        list.forceActiveFocus();
        if (list.currentIndex < 0 && Hermes.inbox.count > 0)
            list.currentIndex = firstChat();
    }
    function firstChat() {
        for (let i = 0; i < Hermes.inbox.count; i++)
            if (Hermes.inbox.get(i).kind === "chat")
                return i;
        return 0;
    }
    function cursorRow() {
        return list.currentIndex >= 0 && list.currentIndex < Hermes.inbox.count ? Hermes.inbox.get(list.currentIndex) : null;
    }
    function clearFyi() {
        let n = 0;
        for (let i = 0; i < Hermes.inbox.count; i++) {
            const r = Hermes.inbox.get(i);
            if (r.kind === "chat" && r.bucket === "fyi") {
                Hermes.call("chats.done", { chat: r.jid, value: true });
                n++;
            }
        }
        if (n)
            Hermes.toast("Cleared " + n + " FYI chat" + (n > 1 ? "s" : ""), false);
    }

    // ---- header ----
    Column {
        id: header
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.topMargin: 18
        anchors.leftMargin: 22
        anchors.rightMargin: 12
        spacing: 2

        Item {
            width: parent.width
            height: 36
            Text {
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                text: "Inbox"
                color: Theme.fgSurface
                font.family: Theme.font
                font.pixelSize: 28
                font.weight: Font.DemiBold
            }
            Row {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                spacing: 2
                IconButton {
                    icon: "clear_all"
                    visible: Hermes.inboxCounts.fyi > 0
                    tip: "Mark all FYI as done"
                    onClicked: pane.clearFyi()
                }
                IconButton {
                    icon: "edit_square"
                    tip: "New chat (Ctrl+N)"
                    onClicked: pane.newChat()
                }
            }
        }
        Text {
            width: parent.width
            elide: Text.ElideRight
            textFormat: Text.StyledText
            color: Theme.fgSurfaceVariant
            font.family: Theme.font
            font.pixelSize: 13
            text: {
                const d = new Date();
                const day = d.toLocaleDateString(Qt.locale(), "dddd, d MMMM");
                const n = Hermes.needsYou;
                if (Hermes.status.syncing)
                    return day + " · syncing…";
                if (n === 0)
                    return day + " · nothing needs you";
                return day + " · <font color='" + Theme.primary + "'><b>" + n + "</b> need" + (n === 1 ? "s" : "") + " you</font>";
            }
        }
    }

    // ---- list ----
    ListView {
        id: list
        anchors.top: header.bottom
        anchors.topMargin: 8
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: hints.top
        clip: true
        model: Hermes.inbox
        boundsBehavior: Flickable.StopAtBounds
        currentIndex: -1
        keyNavigationEnabled: false
        highlightMoveDuration: 0
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        displaced: Transition { NumberAnimation { properties: "y"; duration: Theme.durMed; easing.type: Easing.OutCubic } }
        remove: Transition {
            NumberAnimation { property: "opacity"; to: 0; duration: Theme.durFast }
            NumberAnimation { property: "x"; to: 40; duration: Theme.durMed; easing.type: Easing.OutCubic }
        }
        add: Transition { NumberAnimation { property: "opacity"; from: 0; to: 1; duration: Theme.durMed } }

        // Inbox zero sits above the quiet sections (waiting / snoozed) when nothing is actionable.
        header: Item {
            width: list.width
            height: pane.actionable === 0 && Hermes.ready ? zero.implicitHeight + 48 : 0
            visible: height > 0
            Column {
                id: zero
                anchors.centerIn: parent
                spacing: 10
                Rectangle {
                    anchors.horizontalCenter: parent.horizontalCenter
                    width: 72; height: 72; radius: 24
                    color: Theme.primaryContainer
                    Icon { anchors.centerIn: parent; name: "done_all"; size: 38; color: Theme.fgPrimaryContainer }
                    NumberAnimation on scale { id: zeroSpin; from: 0.6; to: 1; duration: 420; easing.type: Easing.OutBack; running: pane.actionable === 0 }
                }
                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: Hermes.status.syncing ? "Syncing…" : "Inbox zero"
                    color: Theme.fgSurface
                    font.family: Theme.font
                    font.pixelSize: 20
                    font.weight: Font.DemiBold
                }
                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    width: list.width - 64
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.WordWrap
                    text: Hermes.inboxCounts.waiting > 0
                        ? "Nothing needs you. " + Hermes.inboxCounts.waiting + " conversation" + (Hermes.inboxCounts.waiting > 1 ? "s are" : " is") + " waiting on someone else."
                        : "Nothing needs you right now."
                    color: Theme.fgSurfaceVariant
                    font.family: Theme.font
                    font.pixelSize: 13
                }
            }
        }

        delegate: InboxRow {
            cursor: list.activeFocus && ListView.isCurrentItem
            onActivated: {
                list.currentIndex = index;
                Hermes.openChat(jid);
            }
            onDoneClicked: Hermes.markDone(jid, true)
            onSnoozeClicked: item => {
                if (bucket === "snoozed")
                    Hermes.snooze(jid, 0, "");
                else
                    pane.snoozeRequested(jid, name, item);
            }
            onMenuRequested: (item, x, y) => {
                rowMenu.chat = { jid: jid, name: name, bucket: bucket, muted: mutedUntil * 1000 > Date.now(), unread: unread > 0 || markedUnread };
                rowMenu.openAt(item, x, y);
            }
        }

        Keys.onPressed: e => {
            const n = Hermes.inbox.count;
            const r = pane.cursorRow();
            if (e.modifiers & (Qt.ControlModifier | Qt.AltModifier))
                return;
            switch (e.key) {
            case Qt.Key_J:
            case Qt.Key_Down:
                list.currentIndex = Math.min(n - 1, list.currentIndex + 1);
                break;
            case Qt.Key_K:
            case Qt.Key_Up:
                list.currentIndex = Math.max(0, list.currentIndex - 1);
                break;
            case Qt.Key_G:
                list.currentIndex = (e.modifiers & Qt.ShiftModifier) ? n - 1 : 0;
                break;
            case Qt.Key_Return:
            case Qt.Key_Enter:
            case Qt.Key_O:
            case Qt.Key_L:
            case Qt.Key_Space:
                if (!r)
                    return;
                if (r.kind === "header")
                    Hermes.toggleSection(r.bucket);
                else {
                    Hermes.openChat(r.jid);
                    if (e.key !== Qt.Key_Space)
                        pane.chatOpened();
                }
                break;
            case Qt.Key_E:
                if (!r || r.kind !== "chat")
                    return;
                if (e.modifiers & Qt.ShiftModifier) {
                    Hermes.undoDone();
                } else {
                    const keep = list.currentIndex;
                    Hermes.markDone(r.jid, Hermes.currentChat === r.jid);
                    Qt.callLater(() => list.currentIndex = Math.min(keep, Hermes.inbox.count - 1));
                }
                break;
            case Qt.Key_S:
                if (!r || r.kind !== "chat")
                    return;
                if (r.bucket === "snoozed")
                    Hermes.snooze(r.jid, 0, "");
                else
                    pane.snoozeRequested(r.jid, r.name, list.currentItem);
                break;
            case Qt.Key_U:
                if (!r || r.kind !== "chat")
                    return;
                Hermes.act("chats.markUnread", { chat: r.jid });
                break;
            default:
                return;
            }
            e.accepted = true;
        }
    }
    // Keyboard hint strip
    Rectangle {
        id: hints
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        height: list.activeFocus ? 34 : 0
        visible: height > 0
        color: Theme.surfaceContainer
        Behavior on height { NumberAnimation { duration: Theme.durFast } }
        Text {
            anchors.centerIn: parent
            textFormat: Text.StyledText
            color: Theme.fgSurfaceVariant
            font.family: Theme.font
            font.pixelSize: 12
            readonly property string k: "<font color='" + Theme.primary + "' face='" + Theme.monoFont + "'>"
            text: k + "j/k</font> move  " + k + "↵</font> open  " + k + "e</font> done  " + k + "s</font> snooze  " + k + "u</font> unread  " + k + "E</font> undo"
        }
    }

    PopupMenu {
        id: rowMenu
        property var chat: ({})
        MenuItemRow {
            icon: "check"
            text: "Done"
            onTriggered: { rowMenu.close(); Hermes.markDone(rowMenu.chat.jid, true); }
        }
        MenuItemRow {
            icon: rowMenu.chat.bucket === "snoozed" ? "alarm_off" : "snooze"
            text: rowMenu.chat.bucket === "snoozed" ? "Unsnooze" : "Snooze…"
            onTriggered: {
                rowMenu.close();
                if (rowMenu.chat.bucket === "snoozed")
                    Hermes.snooze(rowMenu.chat.jid, 0, "");
                else
                    pane.snoozeRequested(rowMenu.chat.jid, rowMenu.chat.name, null);
            }
        }
        MenuItemRow {
            icon: rowMenu.chat.unread ? "mark_chat_read" : "mark_chat_unread"
            text: rowMenu.chat.unread ? "Mark as read" : "Mark as unread"
            onTriggered: { rowMenu.close(); Hermes.act(rowMenu.chat.unread ? "chats.markRead" : "chats.markUnread", { chat: rowMenu.chat.jid }); }
        }
        MenuItemRow {
            icon: rowMenu.chat.muted ? "notifications" : "notifications_off"
            text: rowMenu.chat.muted ? "Unmute" : "Mute for 8 hours"
            onTriggered: { rowMenu.close(); Hermes.act("chats.mute", { chat: rowMenu.chat.jid, value: !rowMenu.chat.muted, hours: 8 }); }
        }
        MenuItemRow {
            icon: "archive"
            text: "Archive"
            onTriggered: { rowMenu.close(); Hermes.act("chats.archive", { chat: rowMenu.chat.jid, value: true }); }
        }
    }
}
