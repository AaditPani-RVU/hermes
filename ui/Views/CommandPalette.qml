import QtQuick
import QtQuick.Controls
import qs.Services
import qs.Components

// Ctrl+K: jump to any chat or run an action by typing.
Popup {
    id: pal
    parent: Overlay.overlay
    x: parent ? (parent.width - width) / 2 : 0
    y: parent ? parent.height * 0.14 : 0
    width: parent ? Math.min(560, parent.width - 40) : 560
    height: Math.min(460, box.implicitHeight + list.contentHeight + 32)
    modal: true
    focus: true
    padding: 10
    signal action(string key)
    property int sel: 0
    property var items: []

    readonly property var actions: [
        { kind: "action", key: "inbox", name: "Go to inbox", icon: "inbox" },
        { kind: "action", key: "status", name: "Status", icon: "motion_photos_on" },
        { kind: "action", key: "new", name: "New chat", icon: "edit_square" },
        { kind: "action", key: "snippets", name: "Manage snippets", icon: "text_snippet" },
        { kind: "action", key: "settings", name: "Settings & privacy", icon: "settings" },
        { kind: "action", key: "search", name: "Search messages", icon: "manage_search" },
        { kind: "action", key: "focus", name: "Toggle focus mode", icon: "do_not_disturb_on" },
        { kind: "action", key: "archived", name: "Show archived chats", icon: "archive" },
        { kind: "action", key: "scheduled", name: "Scheduled messages", icon: "schedule_send" },
        { kind: "action", key: "starred", name: "Starred messages", icon: "star" },
        { kind: "action", key: "markall", name: "Mark all chats as read", icon: "done_all" },
        { kind: "action", key: "export", name: "Export this chat to Markdown", icon: "description" },
        { kind: "action", key: "autofile", name: "Auto-file media rules", icon: "drive_file_move" },
        { kind: "action", key: "backup", name: "Back up Hermes", icon: "backup" },
        { kind: "action", key: "storage", name: "Storage & cleanup", icon: "hard_drive" },
        { kind: "action", key: "summarize", name: "Summarise this chat", icon: "summarize" }
    ]

    function score(name, q) {
        name = name.toLowerCase();
        if (!q) return 1;
        if (name.startsWith(q)) return 100 - name.length / 100;
        const i = name.indexOf(q);
        if (i >= 0) return 50 - i;
        // subsequence match
        let j = 0;
        for (let k = 0; k < name.length && j < q.length; k++)
            if (name[k] === q[j]) j++;
        return j === q.length ? 10 : -1;
    }
    function refresh() {
        const q = field.text.trim().toLowerCase();
        const out = [];
        for (let i = 0; i < Hermes.chats.count; i++) {
            const c = Hermes.chats.get(i);
            const s = score(c.name, q);
            if (s >= 0) out.push({ kind: "chat", key: c.jid, name: c.name, avatarPath: c.avatarPath, isGroup: c.isGroup, unread: c.unread, s: s + (c.unread > 0 ? 1 : 0) });
        }
        for (const a of actions) {
            const s = score(a.name, q);
            if (s >= 0 && q) out.push(Object.assign({ s: s - 5 }, a));
        }
        out.sort((a, b) => b.s - a.s);
        items = out.slice(0, 40);
        sel = 0;
    }
    function activate(i) {
        const it = items[i];
        if (!it) return;
        close();
        if (it.kind === "chat") Hermes.openChat(it.key); else action(it.key);
    }
    onOpened: { field.text = ""; refresh(); field.input.forceActiveFocus(); }

    Overlay.modal: Rectangle { color: Theme.alpha(Theme.scrim, 0.35) }
    background: Rectangle {
        radius: Theme.radiusXl
        color: Theme.surfaceContainerHigh
        border.width: 1
        border.color: Theme.alpha(Theme.outlineVariant, 0.5)
    }
    enter: Transition {
        NumberAnimation { property: "opacity"; from: 0; to: 1; duration: Theme.durFast }
        NumberAnimation { property: "opacity"; from: 0; to: 1; duration: Theme.durMed; easing.type: Easing.OutCubic }
    }

    contentItem: Column {
        id: box
        spacing: 8
        Field {
            id: field
            width: parent.width
            placeholder: "Jump to chat or type a command…"
            icon: "bolt"
            onTextChanged: pal.refresh()
            onAccepted: pal.activate(pal.sel)
            onEscaped: pal.close()
            input.Keys.onDownPressed: { pal.sel = Math.min(pal.items.length - 1, pal.sel + 1); list.positionViewAtIndex(pal.sel, ListView.Contain); }
            input.Keys.onUpPressed: { pal.sel = Math.max(0, pal.sel - 1); list.positionViewAtIndex(pal.sel, ListView.Contain); }
        }
        ListView {
            id: list
            width: parent.width
            height: Math.min(contentHeight, 380)
            clip: true
            model: pal.items
            delegate: Rectangle {
                required property var modelData
                required property int index
                width: ListView.view.width
                height: 48
                radius: 12
                color: pal.sel === index ? Theme.secondaryContainer : "transparent"
                Row {
                    x: 10
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 12
                    Loader {
                        anchors.verticalCenter: parent.verticalCenter
                        sourceComponent: modelData.kind === "chat" ? av : ic
                        Component { id: av; Avatar { size: 32; jid: modelData.key; name: modelData.name; path: modelData.avatarPath || ""; group: !!modelData.isGroup } }
                        Component { id: ic; Item { width: 32; height: 32; Icon { anchors.centerIn: parent; name: modelData.icon } } }
                    }
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: modelData.name
                        color: pal.sel === index ? Theme.fgSecondaryContainer : Theme.fgSurface
                        font.family: Theme.font
                        font.pixelSize: 15
                    }
                }
                Text {
                    anchors.right: parent.right
                    anchors.rightMargin: 14
                    anchors.verticalCenter: parent.verticalCenter
                    visible: modelData.kind === "chat" && modelData.unread > 0
                    text: modelData.unread + " unread"
                    color: Theme.primary
                    font.family: Theme.font
                    font.pixelSize: 12
                }
                MouseArea {
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onEntered: pal.sel = index
                    onClicked: pal.activate(index)
                }
            }
        }
    }
}
