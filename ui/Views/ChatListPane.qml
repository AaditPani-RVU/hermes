import QtQuick
import QtQuick.Controls
import qs.Services
import qs.Components

// Left pane: title, search, filter chips and the chat list.
Rectangle {
    id: pane
    color: Theme.surfaceContainerLow
    property string filter: "all" // all | unread | groups | personal
    property alias searchText: search.text
    signal newChat
    signal globalSearch(string query)
    function focusSearch() {
        search.input.forceActiveFocus();
    }

    Column {
        id: header
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.topMargin: 14
        spacing: 12

        Item {
            width: parent.width
            height: 44
            IconButton {
                id: backBtn
                visible: Hermes.showArchived
                anchors.left: parent.left
                anchors.leftMargin: 10
                anchors.verticalCenter: parent.verticalCenter
                icon: "arrow_back"
                onClicked: Hermes.showArchived = false
            }
            Text {
                anchors.left: Hermes.showArchived ? backBtn.right : parent.left
                anchors.leftMargin: Hermes.showArchived ? 6 : 22
                anchors.verticalCenter: parent.verticalCenter
                text: Hermes.showArchived ? "Archived" : "Chats"
                color: Theme.fgSurface
                font.family: Theme.font
                font.pixelSize: 26
                font.weight: Font.DemiBold
            }
            Row {
                anchors.right: parent.right
                anchors.rightMargin: 12
                anchors.verticalCenter: parent.verticalCenter
                spacing: 2
                IconButton {
                    icon: "edit_square"
                    tip: "New chat (Ctrl+N)"
                    onClicked: pane.newChat()
                }
                IconButton {
                    icon: "archive"
                    tip: "Archived chats"
                    toggled: Hermes.showArchived
                    visible: !Hermes.showArchived
                    onClicked: Hermes.showArchived = true
                }
            }
        }

        Field {
            id: search
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.leftMargin: 16
            anchors.rightMargin: 16
            placeholder: "Search chats · Enter searches messages"
            onAccepted: if (text.trim() !== "") pane.globalSearch(text.trim())
            onEscaped: text = ""
        }

        Row {
            anchors.left: parent.left
            anchors.leftMargin: 16
            spacing: 8
            visible: !Hermes.showArchived
            Repeater {
                model: [
                    { key: "all", label: "All" },
                    { key: "unread", label: "Unread" + (Hermes.unreadChats > 0 ? " " + Hermes.unreadChats : "") },
                    { key: "personal", label: "Personal" },
                    { key: "groups", label: "Groups" }
                ]
                delegate: Rectangle {
                    required property var modelData
                    readonly property bool on: pane.filter === modelData.key
                    height: 32
                    width: chipText.implicitWidth + 28
                    radius: 10
                    color: on ? Theme.secondaryContainer : "transparent"
                    border.width: on ? 0 : 1
                    border.color: Theme.outlineVariant
                    Behavior on color { ColorAnimation { duration: Theme.durFast } }
                    Text {
                        id: chipText
                        anchors.centerIn: parent
                        text: modelData.label
                        color: on ? Theme.fgSecondaryContainer : Theme.fgSurfaceVariant
                        font.family: Theme.font
                        font.pixelSize: 13
                        font.weight: Font.Medium
                    }
                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: pane.filter = modelData.key
                    }
                }
            }
        }
    }

    ListView {
        id: list
        anchors.top: header.bottom
        anchors.topMargin: 10
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        clip: true
        model: Hermes.chats
        boundsBehavior: Flickable.StopAtBounds
        reuseItems: true
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        add: Transition { NumberAnimation { property: "opacity"; from: 0; to: 1; duration: Theme.durMed } }
        move: Transition { NumberAnimation { properties: "y"; duration: Theme.durMed; easing.type: Easing.OutCubic } }
        displaced: Transition { NumberAnimation { properties: "y"; duration: Theme.durMed; easing.type: Easing.OutCubic } }

        delegate: ChatRow {
            shown: {
                const q = pane.searchText.trim().toLowerCase();
                if (q && name.toLowerCase().indexOf(q) < 0 && jid.indexOf(q) < 0)
                    return false;
                switch (pane.filter) {
                case "unread": return unread > 0 || markedUnread || Hermes.currentChat === jid;
                case "groups": return isGroup;
                case "personal": return !isGroup;
                }
                return true;
            }
            onMenuRequested: (item, x, y) => {
                chatMenu.chat = { jid: jid, name: name, archived: Hermes.showArchived, pinned: pinnedTs > 0, muted: mutedUntil * 1000 > Date.now(), unread: unread > 0 || markedUnread };
                chatMenu.openAt(item, x, y);
            }
        }

        Text {
            anchors.centerIn: parent
            width: parent.width - 64
            visible: Hermes.chats.count === 0
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            text: !Hermes.daemonUp ? "Waiting for the Hermes daemon…"
                : Hermes.status.syncing ? "Syncing your chats from your phone…"
                : Hermes.showArchived ? "No archived chats" : "No chats yet"
            color: Theme.fgSurfaceVariant
            font.family: Theme.font
            font.pixelSize: 14
        }
    }

    PopupMenu {
        id: chatMenu
        property var chat: ({})
        MenuItemRow {
            icon: chatMenu.chat.archived ? "unarchive" : "archive"
            text: chatMenu.chat.archived ? "Unarchive chat" : "Archive chat"
            onTriggered: { chatMenu.close(); Hermes.act("chats.archive", { chat: chatMenu.chat.jid, value: !chatMenu.chat.archived }); }
        }
        MenuItemRow {
            icon: "keep"
            text: chatMenu.chat.pinned ? "Unpin chat" : "Pin chat"
            onTriggered: { chatMenu.close(); Hermes.act("chats.pin", { chat: chatMenu.chat.jid, value: !chatMenu.chat.pinned }); }
        }
        MenuItemRow {
            icon: chatMenu.chat.muted ? "notifications" : "notifications_off"
            text: chatMenu.chat.muted ? "Unmute" : "Mute for 8 hours"
            onTriggered: { chatMenu.close(); Hermes.act("chats.mute", { chat: chatMenu.chat.jid, value: !chatMenu.chat.muted, hours: 8 }); }
        }
        MenuItemRow {
            visible: !chatMenu.chat.muted
            height: visible ? 42 : 0
            icon: "do_not_disturb_on"
            text: "Mute always"
            onTriggered: { chatMenu.close(); Hermes.act("chats.mute", { chat: chatMenu.chat.jid, value: true, hours: 0 }); }
        }
        MenuItemRow {
            icon: chatMenu.chat.unread ? "mark_chat_read" : "mark_chat_unread"
            text: chatMenu.chat.unread ? "Mark as read" : "Mark as unread"
            onTriggered: {
                chatMenu.close();
                Hermes.act(chatMenu.chat.unread ? "chats.markRead" : "chats.markUnread", { chat: chatMenu.chat.jid });
            }
        }
        MenuItemRow {
            icon: "star"
            text: Hermes.focusState.vips.indexOf(chatMenu.chat.jid) >= 0 ? "Remove from VIPs" : "Add to VIPs (focus mode)"
            onTriggered: {
                chatMenu.close();
                const vips = Hermes.focusState.vips.slice();
                const i = vips.indexOf(chatMenu.chat.jid);
                if (i >= 0) vips.splice(i, 1); else vips.push(chatMenu.chat.jid);
                Hermes.act("focus.set", { until: Hermes.focusState.until, vips: vips }, i >= 0 ? "Removed from VIPs" : "Added to VIPs");
            }
        }
    }
}
