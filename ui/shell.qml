//@ pragma UseQApplication
//@ pragma Env QT_QUICK_CONTROLS_STYLE=Basic

import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Services
import qs.Components
import qs.Views

ShellRoot {
    id: shell

    FloatingWindow {
        id: win
        title: Hermes.needsYou > 0 ? "Hermes (" + Hermes.needsYou + ")" : "Hermes"
        color: Theme.surface
        implicitWidth: 1180
        implicitHeight: 780
        minimumSize: Qt.size(720, 480)
        visible: true

        Binding {
            target: Hermes
            property: "windowActive"
            value: win.active
        }

        readonly property bool narrow: width < 980
        property string section: rail.section

        Item {
            id: root
            anchors.fill: parent
            focus: true

            NavRail {
                id: rail
                anchors.left: parent.left
                anchors.top: parent.top
                anchors.bottom: parent.bottom
                visible: Hermes.ready
            }

            // Middle column swaps with the rail section.
            Item {
                id: middle
                anchors.left: rail.right
                anchors.top: parent.top
                anchors.bottom: parent.bottom
                width: win.narrow && Hermes.currentChat ? 0 : (win.narrow ? parent.width - rail.width : 380)
                visible: Hermes.ready && width > 0

                InboxPane {
                    id: inboxPane
                    anchors.fill: parent
                    visible: rail.section === "inbox"
                    onNewChat: newChat.open()
                    onSnoozeRequested: (jid, name, item) => snoozePicker.openFor(jid, name, "")
                    onChatOpened: convo.focusComposer()
                }
                ChatListPane {
                    id: chatList
                    anchors.fill: parent
                    visible: rail.section === "chats"
                    onNewChat: newChat.open()
                    onGlobalSearch: q => {
                        rail.section = "search";
                        search.run(q);
                    }
                }
                SearchPane {
                    id: search
                    anchors.fill: parent
                    visible: rail.section === "search" || rail.section === "starred"
                    starredMode: rail.section === "starred"
                    onOpenResult: (chat, id) => Hermes.openChat(chat)
                }
                ScheduledPane {
                    anchors.fill: parent
                    visible: rail.section === "scheduled"
                    onOpenChat: chat => Hermes.openChat(chat)
                }
                Rectangle {
                    anchors.right: parent.right
                    width: 1
                    height: parent.height
                    color: Theme.alpha(Theme.outlineVariant, 0.35)
                }
            }

            ConversationPane {
                id: convo
                anchors.left: middle.right
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.bottom: parent.bottom
                visible: Hermes.ready && Hermes.currentChat !== ""
                onSnoozeRequested: msgId => snoozePicker.openFor(Hermes.currentChat, Hermes.currentInfo ? Hermes.currentInfo.name : "", msgId)
                onSearchInChat: {
                    search.scopeChat = Hermes.currentChat;
                    rail.section = "search";
                    search.focusField();
                }
            }

            // Empty state when no chat is open
            Rectangle {
                anchors.fill: convo
                visible: Hermes.ready && Hermes.currentChat === "" && !win.narrow
                color: Theme.surfaceContainerLowest
                Column {
                    anchors.centerIn: parent
                    spacing: 14
                    Rectangle {
                        anchors.horizontalCenter: parent.horizontalCenter
                        width: 96; height: 96; radius: 32
                        color: Theme.primaryContainer
                        Icon { anchors.centerIn: parent; name: "bolt"; filled: true; size: 56; color: Theme.fgPrimaryContainer }
                    }
                    Text {
                        anchors.horizontalCenter: parent.horizontalCenter
                        text: "Hermes"
                        color: Theme.fgSurface
                        font.family: Theme.font
                        font.pixelSize: 30
                        font.weight: Font.DemiBold
                    }
                    Text {
                        anchors.horizontalCenter: parent.horizontalCenter
                        horizontalAlignment: Text.AlignHCenter
                        text: Hermes.status.syncing ? "Syncing messages from your phone…"
                            : Hermes.needsYou > 0 ? Hermes.needsYou + (Hermes.needsYou === 1 ? " conversation needs" : " conversations need") + " you. Press J to start."
                            : "Nothing needs you. Ctrl+K jumps anywhere."
                        color: Theme.fgSurfaceVariant
                        font.family: Theme.font
                        font.pixelSize: 15
                    }
                    Grid {
                        anchors.horizontalCenter: parent.horizontalCenter
                        columns: 2
                        columnSpacing: 18
                        rowSpacing: 8
                        topPadding: 10
                        Repeater {
                            model: ["j / k", "Move through inbox", "e", "Done", "s", "Snooze", "Ctrl+E", "Done, open next", "Ctrl+S", "Snooze open chat", "Ctrl+Shift+E", "Undo done", "Ctrl+K", "Jump to chat", "Ctrl+Shift+F", "Search all messages", "Esc", "Back to inbox"]
                            Text {
                                required property string modelData
                                required property int index
                                text: modelData
                                color: index % 2 === 0 ? Theme.primary : Theme.fgSurfaceVariant
                                font.family: index % 2 === 0 ? Theme.monoFont : Theme.font
                                font.pixelSize: 13
                                horizontalAlignment: index % 2 === 0 ? Text.AlignRight : Text.AlignLeft
                                width: 150
                            }
                        }
                    }
                }
            }

            // Back button in narrow mode
            IconButton {
                visible: win.narrow && Hermes.currentChat !== ""
                z: 10
                x: rail.width + 4
                y: 14
                icon: "arrow_back"
                onClicked: Hermes.closeChat()
            }

            PairingView {
                anchors.fill: parent
                visible: !Hermes.ready
            }

            // Daemon / update banner
            Rectangle {
                id: banner
                readonly property bool outdated: !!(Hermes.updateInfo && Hermes.updateInfo.libraryOutdated && Hermes.updateInfo.libraryAgeDays >= 3)
                readonly property bool offline: Hermes.ready && Hermes.status.state !== "connected"
                visible: (outdated || offline) && !dismissed
                property bool dismissed: false
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.top: parent.top
                anchors.topMargin: 10
                z: 50
                height: 40
                width: bannerRow.implicitWidth + 24
                radius: 20
                color: offline ? Theme.errorContainer : Theme.tertiaryContainer
                Row {
                    id: bannerRow
                    anchors.centerIn: parent
                    spacing: 10
                    Icon {
                        anchors.verticalCenter: parent.verticalCenter
                        name: banner.offline ? "cloud_off" : "system_update"
                        size: 18
                        color: banner.offline ? Theme.fgErrorContainer : Theme.fgTertiaryContainer
                    }
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: banner.offline
                            ? (Hermes.status.state === "banned" ? "WhatsApp temporarily restricted this account" : "Reconnecting to WhatsApp…")
                            : "WhatsApp protocol update available — run hermes-update"
                        color: banner.offline ? Theme.fgErrorContainer : Theme.fgTertiaryContainer
                        font.family: Theme.font
                        font.pixelSize: 13
                    }
                    IconButton {
                        visible: !banner.offline
                        size: 28
                        iconSize: 16
                        icon: "close"
                        tint: Theme.fgTertiaryContainer
                        onClicked: banner.dismissed = true
                    }
                }
            }

            // Incoming call banner
            Rectangle {
                id: callBanner
                property string who: ""
                property bool video: false
                visible: false
                z: 60
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.top: parent.top
                anchors.topMargin: 60
                width: 380
                height: 72
                radius: 36
                color: Theme.secondaryContainer
                Row {
                    anchors.left: parent.left
                    anchors.leftMargin: 20
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 14
                    Icon { anchors.verticalCenter: parent.verticalCenter; name: callBanner.video ? "videocam" : "call"; filled: true; color: Theme.fgSecondaryContainer; size: 28 }
                    Column {
                        anchors.verticalCenter: parent.verticalCenter
                        Text { text: callBanner.who; color: Theme.fgSecondaryContainer; font.family: Theme.font; font.pixelSize: 16; font.weight: Font.DemiBold }
                        Text { text: "Incoming " + (callBanner.video ? "video" : "voice") + " call — answer on your phone"; color: Theme.fgSecondaryContainer; font.family: Theme.font; font.pixelSize: 12 }
                    }
                }
                IconButton { anchors.right: parent.right; anchors.rightMargin: 14; anchors.verticalCenter: parent.verticalCenter; icon: "close"; onClicked: callBanner.visible = false }
                Timer { id: callHide; interval: 30000; onTriggered: callBanner.visible = false }
            }

            // Toasts
            Column {
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.bottom: parent.bottom
                anchors.bottomMargin: 96
                spacing: 8
                z: 100
                Repeater {
                    model: toastModel
                    Rectangle {
                        required property string text
                        required property bool error
                        anchors.horizontalCenter: parent.horizontalCenter
                        height: 44
                        width: Math.min(560, tt.implicitWidth + 40)
                        radius: 12
                        color: error ? Theme.errorContainer : Theme.inverseSurface
                        Text {
                            id: tt
                            anchors.centerIn: parent
                            width: Math.min(implicitWidth, 520)
                            elide: Text.ElideRight
                            text: parent.text
                            color: parent.error ? Theme.fgErrorContainer : Theme.inverseOnSurface
                            font.family: Theme.font
                            font.pixelSize: 14
                        }
                    }
                }
            }

            Keys.onPressed: e => {
                const ctrl = e.modifiers & Qt.ControlModifier;
                const shift = e.modifiers & Qt.ShiftModifier;
                if (ctrl && e.key === Qt.Key_K) {
                    palette.open();
                } else if (ctrl && e.key === Qt.Key_N) {
                    newChat.open();
                } else if (ctrl && shift && e.key === Qt.Key_F) {
                    search.scopeChat = "";
                    rail.section = "search";
                    search.focusField();
                } else if (ctrl && e.key === Qt.Key_F) {
                    search.scopeChat = Hermes.currentChat;
                    rail.section = "search";
                    search.focusField();
                } else if (ctrl && e.key === Qt.Key_1) {
                    rail.section = "inbox";
                    inboxPane.focusList();
                } else if (ctrl && e.key === Qt.Key_2) {
                    rail.section = "chats";
                } else if (ctrl && e.key === Qt.Key_Tab && rail.section === "inbox") {
                    const next = Hermes.nextInInbox(Hermes.currentChat);
                    if (next) Hermes.openChat(next);
                } else if (ctrl && (e.key === Qt.Key_Tab || e.key === Qt.Key_Backtab)) {
                    // Next/previous unread chat
                    const dir = shift ? -1 : 1;
                    const n = Hermes.chats.count;
                    let start = Math.max(0, Hermes.chatIndex(Hermes.currentChat));
                    for (let k = 1; k <= n; k++) {
                        const c = Hermes.chats.get((start + dir * k + n) % n);
                        if (c.unread > 0 || c.markedUnread) { Hermes.openChat(c.jid); break; }
                    }
                } else if (e.key === Qt.Key_Escape && Hermes.currentChat) {
                    Hermes.closeChat();
                    if (rail.section === "inbox")
                        inboxPane.focusList();
                } else if (!ctrl && rail.section === "inbox" && (e.key === Qt.Key_J || e.key === Qt.Key_K || e.key === Qt.Key_Down)) {
                    // Nothing focused yet (fresh window): start triage.
                    inboxPane.focusList();
                } else {
                    return;
                }
                e.accepted = true;
            }
        }

        Shortcut {
            sequences: ["Ctrl+K"]
            context: Qt.ApplicationShortcut
            onActivated: palette.open()
        }
        Shortcut {
            sequences: ["Ctrl+E"]
            context: Qt.ApplicationShortcut
            onActivated: Hermes.markDone(Hermes.currentChat, true)
        }
        Shortcut {
            sequences: ["Ctrl+S"]
            context: Qt.ApplicationShortcut
            enabled: Hermes.currentChat !== ""
            onActivated: snoozePicker.openFor(Hermes.currentChat, Hermes.currentInfo ? Hermes.currentInfo.name : "", "")
        }
        Shortcut {
            sequences: ["Ctrl+Shift+E"]
            context: Qt.ApplicationShortcut
            onActivated: Hermes.undoDone()
        }
        Shortcut {
            sequences: ["Ctrl+N"]
            context: Qt.ApplicationShortcut
            onActivated: newChat.open()
        }
        Shortcut {
            sequences: ["Ctrl+Shift+F"]
            context: Qt.ApplicationShortcut
            onActivated: { search.scopeChat = ""; rail.section = "search"; search.focusField(); }
        }

        CommandPalette {
            id: palette
            onAction: key => {
                switch (key) {
                case "new": newChat.open(); break;
                case "search": rail.section = "search"; search.focusField(); break;
                case "focus": Hermes.act("focus.set", { until: Hermes.focusState.active ? 0 : -1 }, Hermes.focusState.active ? "Focus mode off" : "Focus mode on"); break;
                case "archived": rail.section = "chats"; Hermes.showArchived = true; break;
                case "inbox": rail.section = "inbox"; inboxPane.focusList(); break;
                case "scheduled": rail.section = "scheduled"; break;
                case "starred": rail.section = "starred"; break;
                case "markall": Hermes.act("chats.markAllRead", {}, "All chats marked as read"); break;
                }
            }
        }
        NewChatSheet {
            id: newChat
        }
        SnoozePicker {
            id: snoozePicker
            onClosed: if (rail.section === "inbox" && !Hermes.currentChat) inboxPane.focusList()
        }
    }

    ListModel {
        id: toastModel
    }
    Timer {
        id: toastTimer
        interval: 3200
        repeat: true
        running: toastModel.count > 0
        onTriggered: toastModel.remove(0)
    }
    Connections {
        target: Hermes
        function onToast(text, error) {
            toastModel.append({ text: text, error: error });
            if (toastModel.count > 3)
                toastModel.remove(0);
            toastTimer.restart();
        }
        function onOpenChatRequested(jid) {
            if (rail.section !== "inbox")
                rail.section = "chats";
            if (jid)
                Hermes.openChat(jid);
            win.visible = true;
        }
        function onIncomingCall(name, video) {
            callBanner.who = name;
            callBanner.video = video;
            callBanner.visible = true;
            callHide.restart();
        }
    }

    Component.onCompleted: {
        const open = Quickshell.env("HERMES_OPEN_CHAT");
        if (open)
            Qt.callLater(() => Hermes.openChat(open));
    }

    IpcHandler {
        target: "hermes"
        function open(jid: string): void {
            win.visible = true;
            if (jid)
                Hermes.openChat(jid);
        }
        function toggle(): void {
            win.visible = !win.visible;
        }
        function commandPalette(): void {
            win.visible = true;
            palette.open();
        }
    }
}
