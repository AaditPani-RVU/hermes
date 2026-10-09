import QtQuick
import QtQuick.Controls
import QtQuick.Dialogs
import qs.Services
import "../Services/Format.js" as F

// Message input: reply/edit context, attachments, emoji, voice notes, send/schedule.
Rectangle {
    id: root
    color: Theme.surface
    implicitHeight: col.implicitHeight + 16

    property var replyTo: null // message fields
    property var editing: null // message fields
    property string _draftChat: ""
    property real _lastTyping: 0
    signal pollRequested
    signal scheduleRequested(string text)

    function focusInput() {
        input.forceActiveFocus();
    }
    function startReply(m) {
        editing = null;
        replyTo = m;
        focusInput();
    }
    function startEdit(m) {
        replyTo = null;
        editing = m;
        input.text = m.text;
        input.cursorPosition = input.length;
        focusInput();
    }
    function cancelContext() {
        if (editing)
            input.text = "";
        replyTo = null;
        editing = null;
    }
    function insertText(t) {
        input.insert(input.cursorPosition, t);
        focusInput();
    }

    function send() {
        const text = input.text.trim();
        if (text === "")
            return;
        if (editing) {
            Hermes.act("messages.edit", { chat: Hermes.currentChat, id: editing.id, text: text });
        } else {
            Hermes.sendText(text, replyTo ? replyTo.id : "");
        }
        input.text = "";
        replyTo = null;
        editing = null;
        typingIdle.stop();
        Hermes.setTyping(false);
        _lastTyping = 0;
    }

    // Save the draft of the chat we're leaving, restore the one we're entering.
    Connections {
        target: Hermes
        function onCurrentChatChanged() {
            if (root._draftChat && root._draftChat !== Hermes.currentChat)
                Hermes.call("chats.setDraft", { chat: root._draftChat, text: root.editing ? "" : input.text });
            root.replyTo = null;
            root.editing = null;
            root._draftChat = Hermes.currentChat;
            input.text = Hermes.currentInfo && Hermes.currentInfo.draft ? Hermes.currentInfo.draft : "";
            root.focusInput();
        }
    }

    Timer {
        id: typingIdle
        interval: 5000
        onTriggered: {
            Hermes.setTyping(false);
            root._lastTyping = 0;
        }
    }

    Column {
        id: col
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.margins: 8
        anchors.leftMargin: 14
        anchors.rightMargin: 14
        spacing: 6

        // Reply / edit context bar
        Rectangle {
            visible: root.replyTo !== null || root.editing !== null
            width: parent.width
            height: visible ? 56 : 0
            radius: Theme.radiusMd
            color: Theme.surfaceContainerHigh
            clip: true
            Rectangle {
                width: 4
                height: parent.height - 16
                anchors.verticalCenter: parent.verticalCenter
                x: 10
                radius: 2
                color: root.editing ? Theme.tertiary : Theme.nameColor(root.replyTo ? (root.replyTo.fromMe ? "you" : root.replyTo.senderName) : "")
            }
            Column {
                x: 24
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width - 80
                spacing: 2
                Text {
                    text: root.editing ? "Edit message" : root.replyTo ? (root.replyTo.fromMe ? "Replying to yourself" : "Replying to " + root.replyTo.senderName) : ""
                    color: root.editing ? Theme.tertiary : Theme.primary
                    font.family: Theme.font
                    font.pixelSize: 13
                    font.weight: Font.DemiBold
                }
                Text {
                    width: parent.width
                    elide: Text.ElideRight
                    text: {
                        const m = root.editing || root.replyTo;
                        if (!m) return "";
                        return m.text || ({ image: "📷 Photo", video: "🎥 Video", voice: "🎤 Voice message", audio: "🎵 Audio", document: "📄 " + m.fileName, sticker: "💟 Sticker" })[m.type] || "";
                    }
                    color: Theme.fgSurfaceVariant
                    font.family: Theme.font
                    font.pixelSize: 13
                }
            }
            IconButton {
                anchors.right: parent.right
                anchors.rightMargin: 6
                anchors.verticalCenter: parent.verticalCenter
                icon: "close"
                size: 34
                onClicked: root.cancelContext()
            }
        }

        // Recording bar
        Rectangle {
            visible: Hermes.recording
            width: parent.width
            height: visible ? 52 : 0
            radius: 26
            color: Theme.surfaceContainerHigh
            property real started: 0
            onVisibleChanged: if (visible) started = Date.now()
            Row {
                anchors.left: parent.left
                anchors.leftMargin: 8
                anchors.verticalCenter: parent.verticalCenter
                spacing: 10
                IconButton {
                    icon: "delete"
                    tint: Theme.error
                    tip: "Discard"
                    onClicked: Hermes.act("voice.stop", { send: false })
                }
                Rectangle {
                    width: 12; height: 12; radius: 6
                    color: Theme.error
                    anchors.verticalCenter: parent.verticalCenter
                    SequentialAnimation on opacity {
                        running: Hermes.recording
                        loops: Animation.Infinite
                        NumberAnimation { to: 0.2; duration: 600 }
                        NumberAnimation { to: 1; duration: 600 }
                    }
                }
                Text {
                    id: recTime
                    anchors.verticalCenter: parent.verticalCenter
                    color: Theme.fgSurface
                    font.family: Theme.font
                    font.pixelSize: 15
                    font.features: { "tnum": 1 }
                    Timer {
                        interval: 250
                        repeat: true
                        running: Hermes.recording
                        triggeredOnStart: true
                        onTriggered: recTime.text = F.duration((Date.now() - recTime.parent.parent.started) / 1000)
                    }
                }
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: "Recording voice message…"
                    color: Theme.fgSurfaceVariant
                    font.family: Theme.font
                    font.pixelSize: 14
                }
            }
            IconButton {
                anchors.right: parent.right
                anchors.rightMargin: 6
                anchors.verticalCenter: parent.verticalCenter
                icon: "send"
                filled: true
                container: Theme.primary
                tint: Theme.fgPrimary
                tip: "Send voice message"
                onClicked: Hermes.act("voice.stop", { send: true, replyTo: root.replyTo ? root.replyTo.id : "" }, "", () => root.replyTo = null)
            }
        }

        // Input row
        Row {
            visible: !Hermes.recording
            width: parent.width
            spacing: 8

            Rectangle {
                id: box
                width: parent.width - sendBtn.width - parent.spacing
                height: Math.max(52, Math.min(180, input.contentHeight + 30))
                radius: 26
                color: Theme.surfaceContainerHigh
                anchors.bottom: parent.bottom
                Behavior on height { NumberAnimation { duration: Theme.durFast } }

                IconButton {
                    id: emojiBtn
                    anchors.left: parent.left
                    anchors.leftMargin: 6
                    anchors.bottom: parent.bottom
                    anchors.bottomMargin: 6
                    icon: "mood"
                    tip: "Emoji"
                    toggled: emojiPicker.opened
                    onClicked: emojiPicker.opened ? emojiPicker.close() : emojiPicker.openAt(emojiBtn, 0, -emojiPicker.height - 8)
                }
                IconButton {
                    id: attachBtn
                    anchors.left: emojiBtn.right
                    anchors.bottom: parent.bottom
                    anchors.bottomMargin: 6
                    icon: "attach_file"
                    tip: "Attach"
                    toggled: attachMenu.opened
                    onClicked: attachMenu.opened ? attachMenu.close() : attachMenu.openAt(attachBtn, 0, -attachMenu.implicitHeight - 8)
                }
                ScrollView {
                    anchors.left: attachBtn.right
                    anchors.leftMargin: 4
                    anchors.right: parent.right
                    anchors.rightMargin: 16
                    anchors.top: parent.top
                    anchors.bottom: parent.bottom
                    anchors.topMargin: 6
                    anchors.bottomMargin: 6
                    TextArea {
                        id: input
                        background: null
                        color: Theme.fgSurface
                        placeholderText: root.editing ? "Edit message" : Hermes.currentInfo && Hermes.currentInfo.ephemeral > 0 ? "Disappearing message" : "Message"
                        placeholderTextColor: Theme.fgSurfaceVariant
                        selectionColor: Theme.primary
                        selectedTextColor: Theme.fgPrimary
                        font.family: Theme.font
                        font.pixelSize: 15
                        wrapMode: TextArea.Wrap
                        verticalAlignment: TextArea.AlignVCenter
                        topPadding: 9
                        bottomPadding: 9
                        leftPadding: 4
                        Keys.onPressed: e => {
                            if ((e.key === Qt.Key_Return || e.key === Qt.Key_Enter) && !(e.modifiers & Qt.ShiftModifier)) {
                                e.accepted = true;
                                if (e.modifiers & Qt.ControlModifier)
                                    root.scheduleRequested(input.text);
                                else
                                    root.send();
                            } else if (e.key === Qt.Key_Escape && (root.replyTo || root.editing)) {
                                e.accepted = true;
                                root.cancelContext();
                            } else if (e.key === Qt.Key_Up && input.text === "" && !root.editing) {
                                // Up arrow edits your last message, like Slack/Telegram.
                                for (let i = 0; i < Hermes.messages.count; i++) {
                                    const m = Hermes.messages.get(i);
                                    if (m.fromMe && m.type === "text" && !m.revoked && Date.now() / 1000 - m.ts < 900) {
                                        e.accepted = true;
                                        root.startEdit(m);
                                        break;
                                    }
                                }
                            }
                        }
                        onTextChanged: {
                            if (text === "" || root.editing)
                                return;
                            const now = Date.now();
                            if (now - root._lastTyping > 8000) {
                                Hermes.setTyping(true);
                                root._lastTyping = now;
                            }
                            typingIdle.restart();
                        }
                    }
                }
            }

            IconButton {
                id: sendBtn
                anchors.bottom: parent.bottom
                size: 52
                iconSize: 24
                filled: true
                container: Theme.primary
                tint: Theme.fgPrimary
                readonly property bool hasText: input.text.trim() !== ""
                icon: root.editing ? "check" : hasText ? "send" : "mic"
                tip: root.editing ? "Save edit" : hasText ? "Send (Enter) · Ctrl+Enter to schedule" : "Record voice message"
                onClicked: {
                    if (hasText || root.editing)
                        root.send();
                    else
                        Hermes.act("voice.start", { chat: Hermes.currentChat });
                }
                onRightClicked: if (hasText) root.scheduleRequested(input.text)
            }
        }
    }

    // ---- popups ----

    PopupMenu {
        id: attachMenu
        width: 230
        MenuItemRow {
            icon: "image"
            text: "Photos & videos"
            onTriggered: { attachMenu.close(); fileDialog.kind = "auto"; fileDialog.nameFilters = ["Images & videos (*.jpg *.jpeg *.png *.webp *.gif *.heic *.mp4 *.mov *.mkv *.webm)", "All files (*)"]; fileDialog.open(); }
        }
        MenuItemRow {
            icon: "description"
            text: "Document"
            onTriggered: { attachMenu.close(); fileDialog.kind = "document"; fileDialog.nameFilters = ["All files (*)"]; fileDialog.open(); }
        }
        MenuItemRow {
            icon: "sticky_note_2"
            text: "Sticker from image"
            onTriggered: { attachMenu.close(); fileDialog.kind = "sticker"; fileDialog.nameFilters = ["Images (*.jpg *.jpeg *.png *.webp *.gif)"]; fileDialog.open(); }
        }
        MenuItemRow {
            icon: "headphones"
            text: "Audio file"
            onTriggered: { attachMenu.close(); fileDialog.kind = "audio"; fileDialog.nameFilters = ["Audio (*.mp3 *.ogg *.opus *.m4a *.wav *.flac *.aac)", "All files (*)"]; fileDialog.open(); }
        }
        MenuItemRow {
            icon: "ballot"
            text: "Poll"
            onTriggered: { attachMenu.close(); root.pollRequested(); }
        }
        MenuItemRow {
            icon: "schedule_send"
            text: "Schedule message"
            onTriggered: { attachMenu.close(); root.scheduleRequested(input.text); }
        }
    }

    FileDialog {
        id: fileDialog
        property string kind: "auto"
        title: "Send to " + (Hermes.currentInfo ? Hermes.currentInfo.name : "")
        fileMode: FileDialog.OpenFiles
        onAccepted: {
            for (const f of selectedFiles) {
                const path = decodeURIComponent(f.toString().replace("file://", ""));
                Hermes.sendFile(path, input.text.trim() && selectedFiles.length === 1 ? input.text.trim() : "", kind, root.replyTo ? root.replyTo.id : "");
            }
            if (selectedFiles.length === 1 && input.text.trim())
                input.text = "";
            root.replyTo = null;
        }
    }

    EmojiPicker {
        id: emojiPicker
        onPicked: e => root.insertText(e)
    }
}
