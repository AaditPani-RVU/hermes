import QtQuick
import QtQuick.Controls
import Quickshell
import qs.Services
import qs.Components
import "../Services/Format.js" as F

// Small reply window opened from a notification's "Reply" button: the last few
// messages and a text box. Enter sends and closes, Esc closes. Independent of the
// main window, which can stay hidden.
FloatingWindow {
    id: win
    title: "Reply · " + (info ? info.name : "Hermes")
    color: Theme.surface
    implicitWidth: 480
    implicitHeight: 420
    minimumSize: Qt.size(360, 300)
    visible: false

    property string chat: ""
    property var info: null
    property var recent: [] // oldest first
    property bool sending: false

    function openFor(jid) {
        chat = jid;
        info = null;
        recent = [];
        input.text = "";
        sending = false;
        Hermes.call("chats.get", { chat: jid }, res => {
            if (res && jid === win.chat)
                win.info = res;
        });
        Hermes.call("messages.list", { chat: jid, limit: 6 }, res => {
            if (res && jid === win.chat)
                win.recent = res.filter(m => m.type !== "system");
        });
        visible = true;
        input.forceActiveFocus();
    }
    function send() {
        const text = input.text.trim();
        if (!text || sending)
            return;
        sending = true;
        const jid = chat;
        Hermes.call("messages.sendText", { chat: jid, text: text }, (res, err) => {
            sending = false;
            if (err) {
                Hermes.toast(err, true);
                return;
            }
            Hermes.call("chats.markRead", { chat: jid });
            win.visible = false;
        });
    }

    // Keep the preview live while the window is up.
    Connections {
        target: Hermes
        enabled: win.visible
        function onMessageEvent(m) {
            if (m.chat !== win.chat || m.type === "reaction" || m.type === "system")
                return;
            const list = win.recent.filter(x => x.id !== m.id);
            list.push(m);
            list.sort((a, b) => a.ts - b.ts);
            win.recent = list.slice(-6);
        }
    }

    Item {
        anchors.fill: parent
        focus: true
        Keys.onEscapePressed: win.visible = false

        // Header
        Row {
            id: head
            x: 18
            y: 16
            spacing: 12
            Avatar {
                size: 38
                jid: win.chat
                name: win.info ? win.info.name : ""
                path: win.info ? (win.info.avatarPath || "") : ""
                group: win.info ? win.info.isGroup : false
            }
            Column {
                anchors.verticalCenter: parent.verticalCenter
                Text {
                    text: win.info ? win.info.name : ""
                    color: Theme.fgSurface
                    font.family: Theme.font
                    font.pixelSize: 16
                    font.weight: Font.DemiBold
                }
                Text {
                    text: "Quick reply · Enter sends · Esc closes"
                    color: Theme.fgSurfaceVariant
                    font.family: Theme.font
                    font.pixelSize: 12
                }
            }
        }
        IconButton {
            anchors.right: parent.right
            anchors.rightMargin: 12
            y: 14
            icon: "open_in_full"
            tip: "Open in Hermes"
            onClicked: {
                win.visible = false;
                Hermes.openChatRequested(win.chat);
            }
        }

        // Recent messages, newest at the bottom
        ListView {
            id: recentList
            anchors.top: head.bottom
            anchors.topMargin: 12
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: box.top
            anchors.bottomMargin: 8
            clip: true
            spacing: 6
            model: win.recent
            verticalLayoutDirection: ListView.BottomToTop
            delegate: Item {
                required property var modelData
                required property int index
                // BottomToTop: index 0 sits at the bottom, so feed it newest first.
                readonly property var m: win.recent[win.recent.length - 1 - index]
                width: ListView.view.width
                height: col.implicitHeight + 4
                Column {
                    id: col
                    x: 18
                    width: parent.width - 36
                    spacing: 1
                    Text {
                        text: (m.fromMe ? "You" : (win.info && win.info.isGroup ? m.senderName : (win.info ? win.info.name : ""))) + "  ·  " + F.clock(m.ts)
                        color: m.fromMe ? Theme.primary : Theme.fgSurfaceVariant
                        font.family: Theme.font
                        font.pixelSize: 12
                        font.weight: Font.DemiBold
                    }
                    Text {
                        width: parent.width
                        text: m.revoked ? "This message was deleted" : (m.text || "").length ? (m.type === "voice" ? "🎤 " : "") + m.text : F.escapeHtml((m.type === "voice" ? "🎤 Voice message" : m.type === "image" ? "📷 Photo" : m.type === "document" ? "📄 " + (m.fileName || "Document") : m.type))
                        textFormat: Text.PlainText
                        wrapMode: Text.Wrap
                        maximumLineCount: 4
                        elide: Text.ElideRight
                        color: Theme.fgSurface
                        font.family: Theme.font
                        font.pixelSize: 14
                    }
                }
            }
        }

        // Composer
        Rectangle {
            id: box
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            anchors.margins: 14
            height: Math.max(52, Math.min(160, input.contentHeight + 28))
            radius: Theme.radiusMd
            color: Theme.surfaceContainerLow
            border.width: 1
            border.color: input.activeFocus ? Theme.alpha(Theme.primary, 0.7) : Theme.alpha(Theme.outlineVariant, 0.8)
            ScrollView {
                anchors.left: parent.left
                anchors.right: sendBtn.left
                anchors.top: parent.top
                anchors.bottom: parent.bottom
                anchors.margins: 6
                TextArea {
                    id: input
                    background: null
                    wrapMode: TextArea.Wrap
                    placeholderText: "Reply to " + (win.info ? win.info.name : "")
                    placeholderTextColor: Theme.fgSurfaceVariant
                    color: Theme.fgSurface
                    selectionColor: Theme.primary
                    selectedTextColor: Theme.fgPrimary
                    font.family: Theme.font
                    font.pixelSize: 15
                    Keys.onPressed: e => {
                        if ((e.key === Qt.Key_Return || e.key === Qt.Key_Enter) && !(e.modifiers & Qt.ShiftModifier)) {
                            win.send();
                            e.accepted = true;
                        } else if (e.key === Qt.Key_Escape) {
                            win.visible = false;
                            e.accepted = true;
                        }
                    }
                }
            }
            IconButton {
                id: sendBtn
                anchors.right: parent.right
                anchors.rightMargin: 8
                anchors.bottom: parent.bottom
                anchors.bottomMargin: 8
                size: 36
                iconSize: 20
                readonly property bool ready: input.text.trim() !== "" && !win.sending
                filled: ready
                container: ready ? Theme.primary : "transparent"
                tint: ready ? Theme.fgPrimary : Theme.fgSurfaceVariant
                icon: win.sending ? "hourglass_top" : "arrow_upward"
                tip: "Send (Enter)"
                onClicked: win.send()
            }
        }
    }
}
