import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import qs.Services
import qs.Components
import "../Services/Format.js" as F

// Right pane: header, messages, composer, plus message actions and dialogs.
Rectangle {
    id: pane
    color: Theme.surface
    property bool infoOpen: false
    property bool noteEditing: false
    readonly property string note: info ? (info.note || "") : ""
    signal searchInChat
    signal snoozeRequested(string msgId)

    readonly property var info: Hermes.currentInfo
    readonly property bool isGroup: info ? info.isGroup : false
    readonly property var typingInfo: Hermes.typing[Hermes.currentChat]

    function focusComposer() {
        composer.focusInput();
    }

    // ---- header ----
    Rectangle {
        id: header
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        height: 68
        color: Theme.surface
        z: 2

        Avatar {
            id: hAvatar
            anchors.left: parent.left
            anchors.leftMargin: 18
            anchors.verticalCenter: parent.verticalCenter
            size: 42
            jid: Hermes.currentChat
            name: pane.info ? pane.info.name : ""
            path: pane.info ? pane.info.avatarPath : ""
            group: pane.isGroup
        }
        Column {
            anchors.left: hAvatar.right
            anchors.leftMargin: 14
            anchors.right: actions.left
            anchors.rightMargin: 8
            anchors.verticalCenter: parent.verticalCenter
            spacing: 1
            Text {
                width: parent.width
                text: pane.info ? pane.info.name : ""
                elide: Text.ElideRight
                color: Theme.fgSurface
                font.family: Theme.font
                font.pixelSize: 17
                font.weight: Font.DemiBold
            }
            Text {
                width: parent.width
                elide: Text.ElideRight
                font.family: Theme.font
                font.pixelSize: 13
                color: pane.typingInfo ? Theme.primary : Theme.fgSurfaceVariant
                text: {
                    const t = pane.typingInfo;
                    if (t) {
                        const names = Object.values(t.names).map(n => n.split(" ")[0]);
                        const verb = t.recording ? "recording audio…" : "typing…";
                        return pane.isGroup ? names.join(", ") + (names.length > 1 ? " are " : " is ") + verb : verb;
                    }
                    if (Hermes.currentIsChannel) {
                        const ch = Hermes.channels.find(c => c.jid === Hermes.currentChat);
                        return "Channel" + (ch ? " · " + (ch.subscribers >= 1000 ? Math.round(ch.subscribers / 100) / 10 + "K" : ch.subscribers) + " followers" : "");
                    }
                    if (pane.isGroup)
                        return "Click for group info";
                    const s = F.lastSeen(Hermes.presence[Hermes.currentChat]);
                    if (s)
                        return s;
                    const jid = Hermes.currentChat;
                    return jid.endsWith("@s.whatsapp.net") ? "+" + jid.split("@")[0] : "";
                }
            }
        }
        MouseArea {
            anchors.left: parent.left
            anchors.right: actions.left
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            cursorShape: Qt.PointingHandCursor
            onClicked: pane.infoOpen = !pane.infoOpen
        }
        Row {
            id: actions
            anchors.right: parent.right
            anchors.rightMargin: 12
            anchors.verticalCenter: parent.verticalCenter
            spacing: 2
            Rectangle {
                visible: pane.info && pane.info.ephemeral > 0
                anchors.verticalCenter: parent.verticalCenter
                height: 28
                width: ephText.implicitWidth + 34
                radius: 14
                color: Theme.surfaceContainerHigh
                Row {
                    anchors.centerIn: parent
                    spacing: 4
                    Icon { name: "timer"; size: 16 }
                    Text {
                        id: ephText
                        text: pane.info ? (pane.info.ephemeral >= 86400 * 7 ? Math.round(pane.info.ephemeral / 86400) + "d" : pane.info.ephemeral >= 86400 ? "24h" : Math.round(pane.info.ephemeral / 3600) + "h") : ""
                        color: Theme.fgSurfaceVariant
                        font.family: Theme.font
                        font.pixelSize: 12
                    }
                }
            }
            // Triage: the primary actions on any open chat.
            Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                visible: !!pane.info && pane.info.bucket === "snoozed"
                height: 28
                width: snoozeText.implicitWidth + 34
                radius: 14
                color: Theme.tertiaryContainer
                Row {
                    anchors.centerIn: parent
                    spacing: 4
                    Icon { name: "snooze"; size: 16; color: Theme.fgTertiaryContainer }
                    Text {
                        id: snoozeText
                        text: pane.info && pane.info.snoozeUntil ? F.whenLabel(pane.info.snoozeUntil) : ""
                        color: Theme.fgTertiaryContainer
                        font.family: Theme.font
                        font.pixelSize: 12
                    }
                }
            }
            IconButton {
                icon: "sticky_note_2"
                filled: pane.note !== ""
                toggled: noteBar.visible
                tip: "Private note: only you can see it"
                onClicked: {
                    if (noteBar.visible && pane.note === "")
                        pane.noteEditing = false;
                    else {
                        pane.noteEditing = true;
                        noteInput.forceActiveFocus();
                    }
                }
            }
            IconButton {
                visible: !Hermes.currentIsChannel
                icon: "snooze"
                tip: "Snooze (Ctrl+S)"
                onClicked: pane.snoozeRequested("")
            }
            TextButton {
                visible: !Hermes.currentIsChannel
                anchors.verticalCenter: parent.verticalCenter
                readonly property bool isDone: !!pane.info && (pane.info.bucket === "done" || pane.info.bucket === "waiting")
                text: isDone ? "Cleared" : "Done"
                icon: isDone ? "done_all" : "check"
                tonal: !isDone
                onClicked: Hermes.markDone(Hermes.currentChat, true)
            }
            Item { width: 6; height: 1 }
            IconButton {
                visible: !Hermes.currentIsChannel
                icon: "videocam"
                tip: "Calls aren't supported on desktop yet — use your phone"
                onClicked: Hermes.toast("Calls aren't supported by the open WhatsApp protocol yet. Use your phone for calls.", false)
            }
            IconButton {
                icon: "search"
                tip: "Search in chat (Ctrl+F)"
                onClicked: pane.searchInChat()
            }
            IconButton {
                visible: !Hermes.currentIsChannel
                icon: "info"
                tip: "Chat info"
                toggled: pane.infoOpen
                onClicked: pane.infoOpen = !pane.infoOpen
            }
        }
        Rectangle {
            anchors.bottom: parent.bottom
            width: parent.width
            height: 1
            color: Theme.alpha(Theme.outlineVariant, 0.4)
        }
    }

    // ---- private note (local only, never sent) ----
    Rectangle {
        id: noteBar
        anchors.top: header.bottom
        anchors.left: parent.left
        anchors.right: infoPanel.left
        visible: pane.note !== "" || pane.noteEditing
        height: visible ? Math.min(160, noteInput.contentHeight + 22) : 0
        color: Theme.alpha(Theme.tertiaryContainer, 0.55)
        z: 1

        Icon {
            id: noteIcon
            x: 22
            y: 11
            name: "sticky_note_2"
            filled: true
            size: 18
            color: Theme.fgTertiaryContainer
        }
        Flickable {
            id: noteFlick
            anchors.left: noteIcon.right
            anchors.leftMargin: 10
            anchors.right: noteHint.left
            anchors.rightMargin: 10
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            anchors.topMargin: 9
            contentHeight: noteInput.contentHeight
            clip: true
            TextEdit {
                id: noteInput
                width: noteFlick.width
                wrapMode: TextEdit.Wrap
                color: Theme.fgTertiaryContainer
                selectionColor: Theme.tertiary
                selectedTextColor: Theme.fgTertiary
                font.family: Theme.font
                font.pixelSize: 14
                Text {
                    visible: noteInput.text === ""
                    text: "Private note for this chat: context, birthdays, what you owe them…"
                    color: Theme.alpha(Theme.fgTertiaryContainer, 0.6)
                    font: noteInput.font
                }
                // Load the chat's note, but never overwrite what you're typing.
                Connections {
                    target: Hermes
                    function onCurrentChatChanged() {
                        pane.noteEditing = false;
                        noteInput.text = pane.note;
                    }
                }
                Connections {
                    target: pane
                    function onNoteChanged() {
                        if (!noteInput.activeFocus)
                            noteInput.text = pane.note;
                    }
                }
                Component.onCompleted: text = pane.note
                onTextChanged: if (activeFocus) noteSave.restart()
                onActiveFocusChanged: {
                    if (!activeFocus) {
                        if (noteSave.running) { noteSave.stop(); noteSave.triggered(); }
                        if (text.trim() === "") pane.noteEditing = false;
                    }
                }
                Keys.onPressed: e => {
                    if (e.key === Qt.Key_Escape) {
                        pane.focusComposer();
                        e.accepted = true;
                    }
                }
            }
        }
        Text {
            id: noteHint
            anchors.right: parent.right
            anchors.rightMargin: 18
            y: 12
            text: noteSave.running ? "saving…" : "only you see this"
            color: Theme.alpha(Theme.fgTertiaryContainer, 0.6)
            font.family: Theme.font
            font.pixelSize: 11
        }
        Timer {
            id: noteSave
            interval: 600
            onTriggered: {
                if (Hermes.currentChat && noteInput.text !== pane.note)
                    Hermes.call("chats.setNote", { chat: Hermes.currentChat, text: noteInput.text });
            }
        }
    }

    // ---- messages ----
    Rectangle {
        id: wall
        anchors.top: noteBar.bottom
        anchors.bottom: composer.top
        anchors.left: parent.left
        anchors.right: infoPanel.left
        color: Theme.surface
        clip: true

        ListView {
            id: list
            anchors.fill: parent
            anchors.bottomMargin: 6
            model: Hermes.messages
            verticalLayoutDirection: ListView.BottomToTop
            spacing: 0
            cacheBuffer: 1600
            boundsBehavior: Flickable.StopAtBounds
            ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
            property string highlightId: ""

            header: Item { height: 8; width: 1 }
            footer: Item {
                width: list.width
                height: Hermes.loadingOlder ? 48 : 16
                BusyIndicator {
                    anchors.centerIn: parent
                    running: Hermes.loadingOlder
                    visible: running
                    width: 28; height: 28
                }
            }

            onContentYChanged: {
                // With BottomToTop, "top" is the end of the model.
                if (atYBeginning && count > 0)
                    Hermes.loadOlder();
            }

            delegate: MessageRow {
                isGroup: pane.isGroup
                chatName: pane.info ? pane.info.name : ""
                chatAvatar: pane.info ? pane.info.avatarPath : ""
                onReplyRequested: composer.startReply(Hermes.messages.get(index))
                onRemindRequested: pane.snoozeRequested(id)
                highlighted: list.highlightId === id
                onMenuRequested: (item, x, y) => msgMenu.show(Hermes.messages.get(index), item, x, y)
                onQuoteClicked: qid => {
                    const i = Hermes.msgIndex(qid);
                    if (i >= 0) {
                        list.positionViewAtIndex(i, ListView.Center);
                        list.highlightId = qid;
                        clearHighlight.restart();
                    } else {
                        Hermes.toast("That message is older than what's loaded", false);
                    }
                }
                onMediaOpened: (path, kind) => {
                    if (kind === "image")
                        viewer.show(path);
                    else
                        Quickshell.execDetached(["mpv", "--force-window", "--loop-file=" + (kind === "gif" ? "inf" : "no"), path]);
                }
            }

            Connections {
                target: Hermes
                function onMessagesLoaded() {
                    if (!Hermes.jumpTo)
                        return;
                    const i = Hermes.msgIndex(Hermes.jumpTo);
                    Hermes.jumpTo = "";
                    if (i < 0)
                        return;
                    list.positionViewAtIndex(i, ListView.Center);
                    list.highlightId = Hermes.messages.get(i).id;
                    clearHighlight.interval = 3000;
                    clearHighlight.restart();
                }
            }

            Timer {
                id: clearHighlight
                interval: 1600
                onTriggered: {
                    list.highlightId = "";
                    interval = 1600;
                }
            }
        }

        // Jump-to-latest button
        IconButton {
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            anchors.margins: 18
            visible: list.contentY < list.originY + list.contentHeight - list.height - 400 && list.count > 0 && !list.atYEnd
            size: 44
            icon: "keyboard_double_arrow_down"
            container: Theme.surfaceContainerHigh
            onClicked: list.positionViewAtBeginning()
        }

        Text {
            anchors.centerIn: parent
            visible: Hermes.messages.count === 0
            text: "No messages here yet"
            color: Theme.fgSurfaceVariant
            font.family: Theme.font
            font.pixelSize: 14
        }

        // Drag files in to send
        DropArea {
            id: drop
            anchors.fill: parent
            keys: ["text/uri-list"]
            onDropped: e => {
                for (const u of e.urls)
                    Hermes.sendFile(decodeURIComponent(u.toString().replace("file://", "")), "", "auto", "");
            }
            Rectangle {
                anchors.fill: parent
                anchors.margins: 16
                visible: drop.containsDrag
                radius: Theme.radiusXl
                color: Theme.alpha(Theme.primaryContainer, 0.85)
                border.width: 2
                border.color: Theme.primary
                Column {
                    anchors.centerIn: parent
                    spacing: 8
                    Icon { anchors.horizontalCenter: parent.horizontalCenter; name: "upload_file"; size: 48; color: Theme.fgPrimaryContainer }
                    Text {
                        text: "Drop to send to " + (pane.info ? pane.info.name : "")
                        color: Theme.fgPrimaryContainer
                        font.family: Theme.font
                        font.pixelSize: 18
                    }
                }
            }
        }
    }

    Rectangle {
        visible: Hermes.currentIsChannel
        anchors.left: parent.left
        anchors.right: infoPanel.left
        anchors.bottom: parent.bottom
        height: visible ? 44 : 0
        z: 1
        color: Theme.surfaceContainer
        Row {
            anchors.centerIn: parent
            spacing: 8
            Icon { name: "campaign"; size: 18; anchors.verticalCenter: parent.verticalCenter }
            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: "Channel · only admins post. Hover a post to react."
                color: Theme.fgSurfaceVariant
                font.family: Theme.font
                font.pixelSize: 13
            }
        }
    }

    Composer {
        id: composer
        anchors.left: parent.left
        anchors.right: infoPanel.left
        anchors.bottom: parent.bottom
        // Channels are read-only: react to posts instead.
        visible: !Hermes.currentIsChannel
        height: visible ? implicitHeight : 0
        onPollRequested: pollSheet.open()
        onScheduleRequested: text => {
            scheduleSheet.text = text;
            scheduleSheet.open();
        }
    }

    InfoPanel {
        id: infoPanel
        anchors.top: header.bottom
        anchors.bottom: parent.bottom
        anchors.right: parent.right
        width: pane.infoOpen ? 340 : 0
        visible: width > 0
        clip: true
        Behavior on width { NumberAnimation { duration: Theme.durMed; easing.type: Easing.OutCubic } }
        onCloseRequested: pane.infoOpen = false
    }

    // ---- message menu ----
    PopupMenu {
        id: msgMenu
        property var msg: ({})
        width: 268
        function show(m, item, x, y) {
            msg = m;
            openAt(item, x, y);
        }
        readonly property bool canEdit: !!msg.fromMe && msg.type === "text" && !msg.revoked && Date.now() / 1000 - msg.ts < 900
        readonly property bool hasMedia: ["image", "video", "gif", "voice", "audio", "document", "sticker"].indexOf(msg.type) >= 0

        Row {
            x: 6
            height: 48
            spacing: 2
            Repeater {
                model: ["👍", "❤️", "😂", "😮", "😢", "🙏"]
                Rectangle {
                    required property string modelData
                    readonly property bool mine: {
                        try {
                            return JSON.parse(msgMenu.msg.reactions || "[]").some(r => r.sender === Hermes.status.meJid && r.emoji === modelData);
                        } catch (e) { return false; }
                    }
                    width: 38; height: 38; radius: 19
                    anchors.verticalCenter: parent.verticalCenter
                    color: mine ? Theme.secondaryContainer : rm.containsMouse ? Theme.alpha(Theme.fgSurface, 0.08) : "transparent"
                    Text { anchors.centerIn: parent; text: modelData; font.pixelSize: 22 }
                    scale: rm.pressed ? 0.85 : rm.containsMouse ? 1.15 : 1
                    Behavior on scale { NumberAnimation { duration: Theme.durFast; easing.type: Easing.OutBack } }
                    MouseArea {
                        id: rm
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            msgMenu.close();
                            Hermes.react(msgMenu.msg.id, parent.mine ? "" : modelData);
                        }
                    }
                }
            }
        }
        Rectangle { width: parent.width; height: 1; color: Theme.alpha(Theme.outlineVariant, 0.5) }
        MenuItemRow {
            visible: !msgMenu.msg.revoked
            height: visible ? 42 : 0
            icon: "reply"
            text: "Reply"
            onTriggered: { msgMenu.close(); composer.startReply(msgMenu.msg); }
        }
        MenuItemRow {
            visible: !!msgMenu.msg.text && !msgMenu.msg.revoked
            height: visible ? 42 : 0
            icon: "content_copy"
            text: "Copy text"
            onTriggered: { msgMenu.close(); Quickshell.clipboardText = msgMenu.msg.text; Hermes.toast("Copied", false); }
        }
        MenuItemRow {
            visible: msgMenu.canEdit
            height: visible ? 42 : 0
            icon: "edit"
            text: "Edit"
            onTriggered: { msgMenu.close(); composer.startEdit(msgMenu.msg); }
        }
        MenuItemRow {
            visible: !msgMenu.msg.revoked
            height: visible ? 42 : 0
            icon: "forward"
            text: "Forward"
            onTriggered: { msgMenu.close(); forwardSheet.msg = msgMenu.msg; forwardSheet.open(); }
        }
        MenuItemRow {
            visible: !msgMenu.msg.revoked
            height: visible ? 42 : 0
            icon: "star"
            text: msgMenu.msg.starred ? "Unstar" : "Star"
            onTriggered: { msgMenu.close(); Hermes.act("messages.star", { chat: Hermes.currentChat, id: msgMenu.msg.id, value: !msgMenu.msg.starred }); }
        }
        MenuItemRow {
            readonly property var ex: { try { return JSON.parse(msgMenu.msg.extra || "{}"); } catch (e) { return {}; } }
            visible: (msgMenu.msg.type === "voice" || msgMenu.msg.type === "audio") && !msgMenu.msg.revoked && ex.transcript !== "pending"
            height: visible ? 42 : 0
            icon: "subtitles"
            text: msgMenu.msg.text ? "Transcribe again" : "Transcribe"
            onTriggered: { msgMenu.close(); Hermes.act("messages.transcribe", { chat: Hermes.currentChat, id: msgMenu.msg.id }); }
        }
        MenuItemRow {
            icon: "alarm"
            text: "Remind me about this…"
            onTriggered: { msgMenu.close(); pane.snoozeRequested(msgMenu.msg.id); }
        }
        MenuItemRow {
            visible: msgMenu.hasMedia && !msgMenu.msg.revoked
            height: visible ? 42 : 0
            icon: "folder_open"
            text: "Open file"
            onTriggered: {
                msgMenu.close();
                const id = msgMenu.msg.id;
                Hermes.download(id, (p, err) => { if (!err) Qt.openUrlExternally(F.fileUrl(p)); });
            }
        }
        MenuItemRow {
            visible: msgMenu.hasMedia && !msgMenu.msg.revoked
            height: visible ? 42 : 0
            icon: "download"
            text: "Save to Downloads"
            onTriggered: {
                msgMenu.close();
                const m = msgMenu.msg;
                Hermes.download(m.id, (p, err) => {
                    if (err) return;
                    const name = m.fileName || p.split("/").pop();
                    Quickshell.execDetached(["sh", "-c", "mkdir -p \"$HOME/Downloads\" && cp -n -- \"$0\" \"$HOME/Downloads/$1\"", p, name]);
                    Hermes.toast("Saved to ~/Downloads/" + name, false);
                });
            }
        }
        MenuItemRow {
            icon: "delete"
            text: "Delete for me"
            danger: true
            onTriggered: { msgMenu.close(); Hermes.act("messages.delete", { chat: Hermes.currentChat, id: msgMenu.msg.id, forEveryone: false }); }
        }
        MenuItemRow {
            visible: !!msgMenu.msg.fromMe && !msgMenu.msg.revoked
            height: visible ? 42 : 0
            icon: "delete_forever"
            text: "Delete for everyone"
            danger: true
            onTriggered: { msgMenu.close(); Hermes.act("messages.delete", { chat: Hermes.currentChat, id: msgMenu.msg.id, forEveryone: true }); }
        }
    }

    // ---- dialogs ----
    Sheet {
        id: pollSheet
        title: "Create poll"
        icon: "ballot"
        acceptText: "Send"
        acceptEnabled: question.text.trim() !== "" && pollSheet.options.filter(o => o.trim()).length >= 2
        property var options: ["", ""]
        onOpened: { question.text = ""; options = ["", ""]; multi.checked = true; question.forceActiveFocus(); }
        onAccepted: Hermes.act("polls.create", { chat: Hermes.currentChat, question: question.text.trim(), options: options.map(o => o.trim()).filter(o => o), multi: multi.checked })

        Field {
            id: question
            Layout.fillWidth: true
            icon: "help"
            placeholder: "Ask a question"
        }
        Repeater {
            model: pollSheet.options.length
            Field {
                required property int index
                Layout.fillWidth: true
                icon: "radio_button_unchecked"
                placeholder: "Option " + (index + 1)
                text: pollSheet.options[index]
                onTextChanged: {
                    const o = pollSheet.options.slice();
                    o[index] = text;
                    if (index === o.length - 1 && text !== "" && o.length < 12)
                        o.push("");
                    pollSheet.options = o;
                }
            }
        }
        CheckBox {
            id: multi
            text: "Allow multiple answers"
            checked: true
            contentItem: Text {
                text: multi.text
                leftPadding: multi.indicator.width + 8
                color: Theme.fgSurface
                font.family: Theme.font
                font.pixelSize: 14
                verticalAlignment: Text.AlignVCenter
            }
        }
    }

    Sheet {
        id: scheduleSheet
        title: "Schedule message"
        icon: "schedule_send"
        acceptText: "Schedule"
        property string text: ""
        property int presetIndex: 1
        readonly property var presets: {
            const now = new Date();
            const tonight = new Date(now); tonight.setHours(20, 0, 0, 0);
            if (tonight < now) tonight.setDate(tonight.getDate() + 1);
            const morning = new Date(now); morning.setDate(now.getDate() + 1); morning.setHours(9, 0, 0, 0);
            const monday = new Date(now); monday.setDate(now.getDate() + ((8 - now.getDay()) % 7 || 7)); monday.setHours(9, 0, 0, 0);
            return [
                { label: "In 30 minutes", at: new Date(now.getTime() + 30 * 60000) },
                { label: "In 1 hour", at: new Date(now.getTime() + 3600000) },
                { label: "Tonight, " + F.clock(tonight / 1000), at: tonight },
                { label: "Tomorrow, 09:00", at: morning },
                { label: "Monday, 09:00", at: monday },
                { label: "Custom…", at: null }
            ];
        }
        acceptEnabled: schedText.text.trim() !== "" && (presets[presetIndex].at !== null || /^\d{1,2}:\d{2}$/.test(customTime.text.trim()) || /^\d{4}-\d{2}-\d{2} \d{1,2}:\d{2}$/.test(customTime.text.trim()))
        onOpened: { schedText.text = text; presetIndex = 1; customTime.text = ""; }
        onAccepted: {
            let at = presets[presetIndex].at;
            if (!at) {
                const t = customTime.text.trim();
                if (t.indexOf("-") > 0) {
                    at = new Date(t.replace(" ", "T"));
                } else {
                    const [h, m] = t.split(":").map(Number);
                    at = new Date(); at.setHours(h, m, 0, 0);
                    if (at < new Date()) at.setDate(at.getDate() + 1);
                }
            }
            Hermes.act("schedule.add", { chat: Hermes.currentChat, text: schedText.text.trim(), at: Math.floor(at.getTime() / 1000) },
                "Scheduled for " + F.listTime(at.getTime() / 1000) + " " + F.clock(at.getTime() / 1000));
            composer.cancelContext();
        }

        Rectangle {
            Layout.fillWidth: true
            implicitHeight: Math.max(80, schedText.implicitHeight + 20)
            radius: Theme.radiusMd
            color: Theme.surfaceContainerHighest
            TextArea {
                id: schedText
                anchors.fill: parent
                anchors.margins: 6
                background: null
                wrapMode: TextArea.Wrap
                color: Theme.fgSurface
                placeholderText: "Message"
                placeholderTextColor: Theme.fgSurfaceVariant
                font.family: Theme.font
                font.pixelSize: 15
            }
        }
        Flow {
            Layout.fillWidth: true
            spacing: 8
            Repeater {
                model: scheduleSheet.presets
                Rectangle {
                    required property var modelData
                    required property int index
                    readonly property bool on: scheduleSheet.presetIndex === index
                    height: 34
                    width: pt.implicitWidth + 26
                    radius: 10
                    color: on ? Theme.secondaryContainer : "transparent"
                    border.width: on ? 0 : 1
                    border.color: Theme.outlineVariant
                    Text { id: pt; anchors.centerIn: parent; text: modelData.label; color: on ? Theme.fgSecondaryContainer : Theme.fgSurfaceVariant; font.family: Theme.font; font.pixelSize: 13 }
                    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: scheduleSheet.presetIndex = index }
                }
            }
        }
        Field {
            id: customTime
            visible: scheduleSheet.presets[scheduleSheet.presetIndex].at === null
            Layout.fillWidth: true
            icon: "schedule"
            placeholder: "18:30  or  2026-10-12 09:00"
        }
    }

    Sheet {
        id: forwardSheet
        title: "Forward to…"
        icon: "forward"
        acceptText: "Forward"
        property var msg: ({})
        property string target: ""
        acceptEnabled: target !== ""
        onOpened: { fwdSearch.text = ""; target = ""; fwdSearch.input.forceActiveFocus(); }
        onAccepted: Hermes.act("messages.forward", { chat: Hermes.currentChat, id: msg.id, to: target }, "Forwarded")

        Field {
            id: fwdSearch
            Layout.fillWidth: true
            placeholder: "Search chats"
        }
        ListView {
            Layout.fillWidth: true
            Layout.preferredHeight: 280
            clip: true
            model: Hermes.chats
            delegate: Rectangle {
                required property string jid
                required property string name
                required property bool isGroup
                required property string avatarPath
                readonly property bool match: fwdSearch.text === "" || name.toLowerCase().indexOf(fwdSearch.text.toLowerCase()) >= 0
                width: ListView.view.width
                height: match ? 52 : 0
                visible: match
                radius: 12
                color: forwardSheet.target === jid ? Theme.secondaryContainer : "transparent"
                Row {
                    anchors.verticalCenter: parent.verticalCenter
                    x: 8
                    spacing: 12
                    Avatar { size: 36; jid: parent.parent.jid; name: parent.parent.name; path: parent.parent.avatarPath; group: parent.parent.isGroup }
                    Text { anchors.verticalCenter: parent.verticalCenter; text: parent.parent.name; color: Theme.fgSurface; font.family: Theme.font; font.pixelSize: 15 }
                }
                MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: forwardSheet.target = jid; onDoubleClicked: { forwardSheet.target = jid; forwardSheet.accepted(); forwardSheet.close(); } }
            }
        }
    }

    // ---- image viewer ----
    Popup {
        id: viewer
        parent: Overlay.overlay
        x: 0; y: 0
        width: parent ? parent.width : 800
        height: parent ? parent.height : 600
        modal: true
        focus: true
        padding: 0
        property string path: ""
        function show(p) { path = p; open(); }
        background: Rectangle { color: Theme.alpha("#000000", 0.88) }
        enter: Transition { NumberAnimation { property: "opacity"; from: 0; to: 1; duration: Theme.durMed } }
        exit: Transition { NumberAnimation { property: "opacity"; to: 0; duration: Theme.durFast } }
        contentItem: Item {
            Image {
                id: big
                anchors.fill: parent
                anchors.margins: 56
                source: F.fileUrl(viewer.path)
                fillMode: Image.PreserveAspectFit
                asynchronous: true
                scale: viewer.opened ? 1 : 0.92
                Behavior on scale { NumberAnimation { duration: Theme.durMed; easing.type: Easing.OutCubic } }
            }
            MouseArea { anchors.fill: parent; onClicked: viewer.close() }
            Row {
                anchors.top: parent.top
                anchors.right: parent.right
                anchors.margins: 12
                spacing: 4
                IconButton { icon: "open_in_new"; tint: "#ffffff"; tip: "Open externally"; onClicked: Qt.openUrlExternally(F.fileUrl(viewer.path)) }
                IconButton {
                    icon: "download"; tint: "#ffffff"; tip: "Save to Downloads"
                    onClicked: {
                        Quickshell.execDetached(["sh", "-c", "mkdir -p \"$HOME/Downloads\" && cp -n -- \"$0\" \"$HOME/Downloads/\"", viewer.path]);
                        Hermes.toast("Saved to ~/Downloads", false);
                    }
                }
                IconButton { icon: "close"; tint: "#ffffff"; onClicked: viewer.close() }
            }
        }
    }
}
