import QtQuick
import QtQuick.Layouts
import qs.Services
import "../Services/Format.js" as F

// One message in the conversation transcript (list is bottom-to-top: index+1 is older).
// Messages read like a document: avatar + name + time on the first of a run, then the
// sender's follow-ups stacked underneath, all left-aligned. No bubbles.
Item {
    id: root
    required property int index
    required property string chat
    required property string id
    required property string sender
    required property string senderName
    required property bool fromMe
    required property real ts
    required property string type
    required property string text
    required property string mediaMime
    required property string mediaPath
    required property string thumbPath
    required property real mediaSize
    required property int mediaW
    required property int mediaH
    required property int mediaSecs
    required property string fileName
    required property string quotedId
    required property string quotedSender
    required property string quotedText
    required property int status
    required property bool edited
    required property bool revoked
    required property bool viewOnce
    required property bool starred
    required property string extra
    required property string reactions

    property bool isGroup: false
    property string chatName: ""
    property string chatAvatar: ""
    property bool highlighted: false
    signal menuRequested(var item, real x, real y)
    signal replyRequested
    signal remindRequested
    signal quoteClicked(string id)
    signal mediaOpened(string path, string kind)

    readonly property int gutter: 72
    readonly property real maxBubble: Math.max(200, Math.min(720, width - gutter - 32))
    readonly property var older: index + 1 < Hermes.messages.count ? Hermes.messages.get(index + 1) : null
    readonly property bool newDay: !older || F.dayKey(older.ts) !== F.dayKey(ts)
    readonly property bool system: type === "system"
    readonly property bool groupedWithOlder: !!older && !newDay && older.fromMe === fromMe && older.sender === sender && ts - older.ts < 300 && older.type !== "system" && !system
    readonly property var reactionList: { try { return JSON.parse(reactions); } catch (e) { return []; } }
    readonly property var extraObj: { try { return extra ? JSON.parse(extra) : ({}); } catch (e) { return {}; } }
    readonly property bool bare: (type === "sticker" || (type === "text" && F.isJumboEmoji(text))) && !quotedId && !revoked
    readonly property bool isMedia: (type === "image" || type === "video" || type === "gif") && !revoked
    readonly property bool isAudio: type === "voice" || type === "audio"
    readonly property string transcriptState: isAudio ? (extraObj.transcript || "") : ""
    // Something aimed at you: an @-mention or a reply to your message.
    readonly property bool forMe: !fromMe && !revoked && (quotedSender === "You" || /(^|\s)@You\b/.test(text))
    readonly property string displayName: fromMe ? "You" : isGroup ? senderName : (chatName || senderName)
    readonly property color nameInk: fromMe ? Theme.primary : isGroup ? Theme.nameColor(sender) : Theme.fgSurface
    // Content components below expect these.
    readonly property color inkColor: Theme.fgSurface
    readonly property color subColor: Theme.fgSurfaceVariant

    width: ListView.view ? ListView.view.width : 600
    height: col.implicitHeight

    HoverHandler { id: hover }
    TapHandler {
        acceptedButtons: Qt.RightButton
        onTapped: (pt, button) => root.menuRequested(root, pt.position.x, pt.position.y)
    }

    Column {
        id: col
        width: parent.width
        spacing: 0

        // Day divider: a rule with the date on it
        Item {
            visible: root.newDay
            width: parent.width
            height: visible ? 48 : 0
            Rectangle {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.leftMargin: 20
                anchors.rightMargin: 20
                anchors.verticalCenter: parent.verticalCenter
                height: 1
                color: Theme.alpha(Theme.outlineVariant, 0.6)
            }
            Rectangle {
                anchors.centerIn: parent
                width: dayText.implicitWidth + 20
                height: 22
                radius: 11
                color: Theme.surface
                border.width: 1
                border.color: Theme.alpha(Theme.outlineVariant, 0.6)
                Text {
                    id: dayText
                    anchors.centerIn: parent
                    text: F.dayLabel(root.ts)
                    color: Theme.fgSurfaceVariant
                    font.family: Theme.font
                    font.pixelSize: 11
                    font.weight: Font.DemiBold
                    font.letterSpacing: 0.4
                }
            }
        }

        // System notices (joins, changes): one quiet centered line
        Text {
            visible: root.system
            width: parent.width
            height: visible ? implicitHeight + 16 : 0
            verticalAlignment: Text.AlignVCenter
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.Wrap
            text: root.text
            color: Theme.fgSurfaceVariant
            font.family: Theme.font
            font.pixelSize: 12
            font.italic: true
        }

        Item {
            id: rowItem
            visible: !root.system
            width: parent.width
            height: visible ? content.implicitHeight + (root.groupedWithOlder ? 4 : 14) : 0

            // Row tint: hover, jump highlight, or "this is for you"
            Rectangle {
                anchors.fill: parent
                color: root.highlighted ? Theme.alpha(Theme.primary, 0.16)
                    : root.forMe ? Theme.alpha(Theme.tertiary, hover.hovered ? 0.12 : 0.08)
                    : hover.hovered ? Theme.alpha(Theme.fgSurface, 0.035) : "transparent"
                Behavior on color { ColorAnimation { duration: Theme.durFast } }
            }
            Rectangle {
                visible: root.forMe
                width: 3
                height: parent.height
                color: Theme.tertiary
            }

            Avatar {
                visible: !root.groupedWithOlder
                x: 22
                y: 10
                size: 36
                jid: root.fromMe ? Hermes.status.meJid || "" : root.isGroup ? "" : Hermes.currentChat
                name: root.displayName
                path: !root.fromMe && !root.isGroup ? root.chatAvatar : ""
            }

            // Follow-up rows: time in the gutter on hover; your ticks otherwise
            Text {
                visible: root.groupedWithOlder && hover.hovered
                x: 8
                width: root.gutter - 18
                y: 3
                horizontalAlignment: Text.AlignRight
                text: F.clock(root.ts)
                color: Theme.fgSurfaceVariant
                font.family: Theme.monoFont
                font.pixelSize: 10
                lineHeight: 1.6
            }
            Ticks {
                visible: root.groupedWithOlder && root.fromMe && !hover.hovered && !root.revoked
                x: root.gutter - 26
                y: 5
                status: root.status
                size: 14
            }

            ColumnLayout {
                id: content
                x: root.gutter
                y: root.groupedWithOlder ? 2 : 10
                width: root.maxBubble
                spacing: 4

                // Name · time · ticks · edited
                Row {
                    visible: !root.groupedWithOlder
                    spacing: 8
                    Text {
                        id: nameText
                        text: root.displayName
                        color: root.nameInk
                        font.family: Theme.font
                        font.pixelSize: 14
                        font.weight: Font.DemiBold
                        elide: Text.ElideRight
                        width: Math.min(implicitWidth, root.maxBubble - 120)
                    }
                    Text {
                        anchors.baseline: nameText.baseline
                        text: F.clock(root.ts)
                        color: Theme.fgSurfaceVariant
                        font.family: Theme.monoFont
                        font.pixelSize: 11
                    }
                    Ticks {
                        visible: root.fromMe && !root.revoked
                        anchors.verticalCenter: parent.verticalCenter
                        status: root.status
                        size: 14
                    }
                    // Channel posts: view count
                    Text {
                        visible: (root.extraObj.views || 0) > 0
                        anchors.baseline: nameText.baseline
                        text: "👁 " + (root.extraObj.views >= 1e6 ? (root.extraObj.views / 1e6).toFixed(1) + "M" : root.extraObj.views >= 1e3 ? (root.extraObj.views / 1e3).toFixed(1) + "K" : root.extraObj.views)
                        color: Theme.fgSurfaceVariant
                        font.family: Theme.font
                        font.pixelSize: 11
                    }
                }

                // Quoted reply: an indented excerpt with a rule
                Item {
                    visible: root.quotedId !== "" && !root.revoked
                    Layout.preferredWidth: Math.min(root.maxBubble, Math.max(quoteName.implicitWidth, quoteBody.implicitWidth) + 16)
                    implicitHeight: quoteCol.implicitHeight + 4
                    Rectangle {
                        width: 3
                        height: parent.height
                        radius: 1.5
                        color: Theme.alpha(root.quotedSender === "You" ? Theme.primary : Theme.nameColor(root.quotedSender || "?"), 0.8)
                    }
                    Column {
                        id: quoteCol
                        x: 12
                        y: 2
                        width: parent.width - 12
                        spacing: 1
                        Text {
                            id: quoteName
                            text: root.quotedSender || "Message"
                            color: Theme.fgSurfaceVariant
                            font.family: Theme.font
                            font.pixelSize: 12
                            font.weight: Font.DemiBold
                            width: Math.min(implicitWidth, parent.width)
                            elide: Text.ElideRight
                        }
                        Text {
                            id: quoteBody
                            text: root.quotedText
                            color: Theme.fgSurfaceVariant
                            font.family: Theme.font
                            font.pixelSize: 13
                            maximumLineCount: 2
                            wrapMode: Text.Wrap
                            elide: Text.ElideRight
                            width: Math.min(implicitWidth, parent.width)
                        }
                    }
                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.quoteClicked(root.quotedId)
                    }
                }

                // Media / special content
                Loader {
                    id: mediaLoader
                    Layout.alignment: Qt.AlignLeft
                    Layout.topMargin: 2
                    active: !root.revoked && root.type !== "text"
                    visible: active
                    sourceComponent: {
                        switch (root.type) {
                        case "image":
                        case "gif":
                        case "video": return visualComp;
                        case "sticker": return stickerComp;
                        case "voice":
                        case "audio": return audioComp;
                        case "document": return docComp;
                        case "location": return locationComp;
                        case "contact": return contactComp;
                        case "poll": return pollComp;
                        }
                        return null;
                    }
                }

                // Voice notes: transcription progress (the transcript itself is the body below)
                Row {
                    visible: root.transcriptState === "pending" || (root.transcriptState === "failed" && root.text === "")
                    spacing: 6
                    Icon {
                        name: root.transcriptState === "pending" ? "graphic_eq" : "error"
                        size: 16
                        color: root.transcriptState === "pending" ? Theme.primary : Theme.error
                        anchors.verticalCenter: parent.verticalCenter
                        SequentialAnimation on opacity {
                            running: root.transcriptState === "pending"
                            loops: Animation.Infinite
                            NumberAnimation { to: 0.3; duration: 600 }
                            NumberAnimation { to: 1; duration: 600 }
                        }
                    }
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        textFormat: Text.StyledText
                        text: root.transcriptState === "pending" ? "Transcribing…" : "Couldn't transcribe · <a href='retry'>Retry</a>"
                        linkColor: Theme.primary
                        color: Theme.fgSurfaceVariant
                        font.family: Theme.font
                        font.pixelSize: 13
                        onLinkActivated: Hermes.act("messages.transcribe", { chat: root.chat, id: root.id })
                    }
                }

                // Text body (captions too; the transcript for voice notes)
                TextEdit {
                    id: body
                    visible: (root.text !== "" && root.type !== "poll" && root.type !== "contact" && root.type !== "location") || root.revoked
                    Layout.fillWidth: true
                    readOnly: true
                    selectByMouse: true
                    wrapMode: TextEdit.Wrap
                    textFormat: TextEdit.RichText
                    color: root.revoked || root.isAudio ? Theme.fgSurfaceVariant : Theme.fgSurface
                    selectionColor: Theme.primary
                    selectedTextColor: Theme.fgPrimary
                    font.family: Theme.font
                    font.pixelSize: root.bare ? 40 : root.isAudio ? 14 : 15
                    font.italic: root.revoked
                    readonly property string suffix: (root.edited && !root.revoked ? " <span style='font-size:11px; color:" + Theme.fgSurfaceVariant + "'>(edited)</span>" : "")
                        + (root.starred ? " <span style='font-size:12px; color:" + Theme.tertiary + "'>★</span>" : "")
                    text: root.revoked
                        ? (root.fromMe ? "You deleted this message" : "This message was deleted")
                        : root.isAudio ? "<span style='color:" + Theme.primary + "'>“</span>" + F.escapeHtml(root.text) + "<span style='color:" + Theme.primary + "'>”</span>"
                        : F.richText(root.text, Theme.primary, Theme.alpha(Theme.fgSurface, 0.1)) + suffix
                    onLinkActivated: link => Qt.openUrlExternally(link)
                    HoverHandler {
                        enabled: body.hoveredLink !== ""
                        cursorShape: Qt.PointingHandCursor
                    }
                }

                // Reactions: click one to add or remove yours
                Flow {
                    visible: chipRep.count > 0
                    Layout.fillWidth: true
                    Layout.topMargin: 2
                    spacing: 6
                    Repeater {
                        id: chipRep
                        model: {
                            const out = [];
                            const idx = {};
                            // Channel posts carry aggregate counts from WhatsApp.
                            const counts = root.extraObj.reactionCounts || {};
                            for (const emoji in counts) {
                                idx[emoji] = out.length;
                                out.push({ emoji: emoji, count: counts[emoji], mine: false, names: [] });
                            }
                            for (const r of root.reactionList) {
                                if (idx[r.emoji] === undefined) {
                                    idx[r.emoji] = out.length;
                                    out.push({ emoji: r.emoji, count: 0, mine: false, names: [] });
                                }
                                const e = out[idx[r.emoji]];
                                if (counts[r.emoji] === undefined)
                                    e.count++; // server counts already include everyone
                                e.names.push(r.fromMe || r.sender === Hermes.status.meJid ? "You" : (r.senderName || "").split(" ")[0]);
                                if (r.fromMe || r.sender === Hermes.status.meJid)
                                    e.mine = true;
                            }
                            return out;
                        }
                        Rectangle {
                            required property var modelData
                            height: 26
                            width: chip.implicitWidth + 18
                            radius: 13
                            color: modelData.mine ? Theme.alpha(Theme.primary, 0.18) : Theme.surfaceContainerHigh
                            border.width: 1
                            border.color: modelData.mine ? Theme.alpha(Theme.primary, 0.6) : "transparent"
                            Row {
                                id: chip
                                anchors.centerIn: parent
                                spacing: 5
                                Text { text: modelData.emoji; font.pixelSize: 14; anchors.verticalCenter: parent.verticalCenter }
                                Text {
                                    visible: modelData.count > 1
                                    text: modelData.count
                                    color: modelData.mine ? Theme.primary : Theme.fgSurfaceVariant
                                    font.family: Theme.font
                                    font.pixelSize: 12
                                    font.weight: Font.DemiBold
                                    anchors.verticalCenter: parent.verticalCenter
                                }
                            }
                            HoverHandler { id: chipHover; cursorShape: Qt.PointingHandCursor }
                            Tip { shown: chipHover.hovered; text: modelData.names.join(", ") }
                            TapHandler { onTapped: Hermes.react(root.id, modelData.mine ? "" : modelData.emoji) }
                        }
                    }
                }
            }

            // Hover toolbar
            Rectangle {
                visible: hover.hovered && !root.revoked
                anchors.right: parent.right
                anchors.rightMargin: 20
                y: -12
                z: 5
                height: 34
                width: tools.implicitWidth + 8
                radius: 10
                color: Theme.surfaceContainerHigh
                border.width: 1
                border.color: Theme.alpha(Theme.outlineVariant, 0.6)
                Row {
                    id: tools
                    anchors.centerIn: parent
                    IconButton { size: 30; iconSize: 18; icon: "add_reaction"; tip: "React"; onClicked: root.menuRequested(this, 0, height + 4) }
                    IconButton { visible: !root.chat.endsWith("@newsletter"); size: 30; iconSize: 18; icon: "reply"; tip: "Reply"; onClicked: root.replyRequested() }
                    IconButton { size: 30; iconSize: 18; icon: "alarm"; tip: "Remind me"; onClicked: root.remindRequested() }
                    IconButton { size: 30; iconSize: 18; icon: "more_horiz"; tip: "More"; onClicked: root.menuRequested(this, 0, height + 4) }
                }
            }
        }
    }

    // ---- content components ----

    function ensureMedia(cb) {
        if (root.mediaPath !== "") {
            cb(root.mediaPath);
            return;
        }
        Hermes.download(root.id, (path, err) => {
            if (!err && path)
                cb(path);
        });
    }

    Component {
        id: visualComp
        Item {
            id: vis
            readonly property real aspect: root.mediaW > 0 && root.mediaH > 0 ? root.mediaW / root.mediaH : 1.33
            readonly property real w: Math.min(root.maxBubble - 8, 330, aspect >= 1 ? 330 : 360 * aspect)
            implicitWidth: Math.max(160, w)
            implicitHeight: Math.max(120, Math.min(360, implicitWidth / aspect))
            property bool downloading: false

            Rectangle {
                anchors.fill: parent
                radius: 14
                color: Theme.surfaceContainerHighest
            }
            Image {
                id: pic
                anchors.fill: parent
                source: F.fileUrl(root.type === "image" && root.mediaPath ? root.mediaPath : root.thumbPath)
                fillMode: Image.PreserveAspectCrop
                asynchronous: true
                smooth: true
                sourceSize.width: parent.width * 2
                visible: false
            }
            Rectangle {
                id: picMask
                anchors.fill: parent
                radius: 14
                layer.enabled: true
                visible: false
            }
            ShaderMask {
                anchors.fill: parent
                source: pic
                mask: picMask
                blurred: root.type === "image" && !root.mediaPath
            }
            // Download / play overlay
            Rectangle {
                anchors.centerIn: parent
                width: 52
                height: 52
                radius: 26
                color: Theme.alpha("#000000", 0.5)
                visible: root.type !== "image" || root.mediaPath === ""
                Icon {
                    anchors.centerIn: parent
                    name: vis.downloading ? "hourglass_top" : root.type === "image" ? "download" : root.type === "gif" ? "gif" : "play_arrow"
                    filled: true
                    size: 30
                    color: "#ffffff"
                    RotationAnimation on rotation {
                        running: vis.downloading
                        from: 0; to: 360; duration: 1200; loops: Animation.Infinite
                        onRunningChanged: if (!running) parent.rotation = 0
                    }
                }
            }
            Text {
                visible: root.type === "video" && root.mediaSecs > 0
                anchors.left: parent.left
                anchors.bottom: parent.bottom
                anchors.margins: 10
                text: "▶ " + F.duration(root.mediaSecs) + (root.mediaPath ? "" : "  ·  " + F.size(root.mediaSize))
                color: "#ffffff"
                font.family: Theme.font
                font.pixelSize: 11
                style: Text.Outline
                styleColor: Theme.alpha("#000000", 0.4)
            }
            Rectangle {
                visible: root.viewOnce
                anchors.left: parent.left
                anchors.top: parent.top
                anchors.margins: 8
                width: 26; height: 26; radius: 13
                color: Theme.alpha("#000000", 0.5)
                Icon { anchors.centerIn: parent; name: "filter_1"; size: 16; color: "#fff" }
            }
            MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                acceptedButtons: Qt.LeftButton
                onClicked: {
                    vis.downloading = root.mediaPath === "";
                    root.ensureMedia(path => {
                        vis.downloading = false;
                        root.mediaOpened(path, root.type);
                    });
                }
            }
        }
    }

    Component {
        id: stickerComp
        Item {
            implicitWidth: 150
            implicitHeight: 150
            AnimatedImage {
                anchors.fill: parent
                source: F.fileUrl(root.mediaPath)
                fillMode: Image.PreserveAspectFit
                asynchronous: true
                playing: hover.hovered || true
            }
            Icon {
                visible: root.mediaPath === ""
                anchors.centerIn: parent
                name: "sticky_note_2"
                size: 48
                color: Theme.outline
            }
            Component.onCompleted: if (root.mediaPath === "") Hermes.download(root.id)
        }
    }

    Component {
        id: audioComp
        Item {
            id: audio
            readonly property bool current: Player.currentId === root.id
            readonly property bool playing: current && Player.playing
            readonly property real progress: current && root.mediaSecs > 0 ? Player.position / root.mediaSecs : 0
            readonly property var wave: root.extraObj.waveform || []
            implicitWidth: Math.min(root.maxBubble - 24, 300)
            implicitHeight: 52
            property bool loading: false

            Rectangle {
                id: playBtn
                width: 42; height: 42; radius: 21
                anchors.verticalCenter: parent.verticalCenter
                color: root.fromMe ? Theme.primary : Theme.secondaryContainer
                Icon {
                    anchors.centerIn: parent
                    name: audio.loading ? "hourglass_top" : audio.playing ? "pause" : "play_arrow"
                    filled: true
                    size: 26
                    color: root.fromMe ? Theme.fgPrimary : Theme.fgSecondaryContainer
                }
                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                        audio.loading = root.mediaPath === "";
                        root.ensureMedia(path => {
                            audio.loading = false;
                            Player.toggle(root.id, path, root.mediaSecs);
                        });
                    }
                }
            }
            Row {
                id: bars
                anchors.left: playBtn.right
                anchors.leftMargin: 10
                anchors.right: speedBtn.left
                anchors.rightMargin: 8
                anchors.verticalCenter: parent.verticalCenter
                anchors.verticalCenterOffset: -6
                height: 26
                spacing: 2
                readonly property int n: Math.max(12, Math.floor(width / 4))
                Repeater {
                    model: bars.n
                    Rectangle {
                        required property int index
                        readonly property real v: {
                            const w = audio.wave;
                            if (!w.length)
                                return 0.25 + 0.5 * Math.abs(Math.sin(index * 1.7 + root.ts));
                            return Math.max(0.12, w[Math.floor(index * w.length / bars.n)] / 100);
                        }
                        width: 2
                        radius: 1
                        height: Math.max(3, v * bars.height)
                        anchors.verticalCenter: parent.verticalCenter
                        color: index / bars.n <= audio.progress ? (root.fromMe ? Theme.primary : Theme.secondary) : Theme.alpha(root.inkColor, 0.35)
                    }
                }
            }
            Text {
                anchors.left: bars.left
                anchors.top: bars.bottom
                anchors.topMargin: 4
                text: audio.current && Player.position > 0 ? F.duration(Player.position) : F.duration(root.mediaSecs)
                color: root.subColor
                font.family: Theme.font
                font.pixelSize: 11
            }
            Rectangle {
                id: speedBtn
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                visible: audio.current
                width: visible ? 36 : (root.type === "voice" ? 0 : 0)
                height: 22
                radius: 11
                color: Theme.alpha(root.inkColor, 0.12)
                Text {
                    anchors.centerIn: parent
                    text: Player.speed + "×"
                    color: root.inkColor
                    font.family: Theme.font
                    font.pixelSize: 11
                    font.weight: Font.DemiBold
                }
                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: Player.cycleSpeed()
                }
            }
        }
    }

    Component {
        id: docComp
        Rectangle {
            implicitWidth: Math.min(root.maxBubble - 24, 320)
            implicitHeight: 62
            radius: 12
            color: Theme.alpha(root.inkColor, 0.07)
            property bool loading: false
            Rectangle {
                id: docIcon
                anchors.left: parent.left
                anchors.leftMargin: 10
                anchors.verticalCenter: parent.verticalCenter
                width: 40; height: 44; radius: 8
                color: Theme.alpha(Theme.tertiary, 0.25)
                Icon {
                    anchors.centerIn: parent
                    name: F.docIcon(root.mediaMime, root.fileName)
                    color: Theme.tertiary
                    filled: true
                }
            }
            Column {
                anchors.left: docIcon.right
                anchors.leftMargin: 10
                anchors.right: dl.left
                anchors.rightMargin: 6
                anchors.verticalCenter: parent.verticalCenter
                spacing: 2
                Text {
                    width: parent.width
                    text: root.fileName || "Document"
                    elide: Text.ElideMiddle
                    color: root.inkColor
                    font.family: Theme.font
                    font.pixelSize: 14
                    font.weight: Font.Medium
                }
                Text {
                    text: [root.extraObj.pages ? root.extraObj.pages + " pages" : "", (root.fileName.split(".").pop() || "").toUpperCase(), F.size(root.mediaSize)].filter(x => x).join(" · ")
                    color: root.subColor
                    font.family: Theme.font
                    font.pixelSize: 12
                }
            }
            IconButton {
                id: dl
                anchors.right: parent.right
                anchors.rightMargin: 6
                anchors.verticalCenter: parent.verticalCenter
                icon: parent.loading ? "hourglass_top" : root.mediaPath ? "open_in_new" : "download"
                tint: root.inkColor
                onClicked: {
                    parent.loading = root.mediaPath === "";
                    root.ensureMedia(path => {
                        parent.loading = false;
                        Qt.openUrlExternally(F.fileUrl(path));
                    });
                }
            }
        }
    }

    Component {
        id: locationComp
        Column {
            spacing: 6
            readonly property var loc: root.extraObj
            Rectangle {
                width: 260
                height: 130
                radius: 12
                color: Theme.alpha(root.inkColor, 0.07)
                clip: true
                Image {
                    anchors.fill: parent
                    source: F.fileUrl(root.thumbPath)
                    fillMode: Image.PreserveAspectCrop
                    visible: root.thumbPath !== ""
                }
                Icon {
                    anchors.centerIn: parent
                    name: "location_on"
                    filled: true
                    size: 40
                    color: Theme.error
                }
                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: Qt.openUrlExternally("https://www.openstreetmap.org/?mlat=" + loc.lat + "&mlon=" + loc.lng + "#map=17/" + loc.lat + "/" + loc.lng)
                }
            }
            Text {
                visible: !!(loc.name || loc.address || loc.live)
                width: 260
                wrapMode: Text.Wrap
                text: (loc.live ? "🔴 Live location" : "") + (loc.name ? "<b>" + F.escapeHtml(loc.name) + "</b><br>" : "") + F.escapeHtml(loc.address || "")
                textFormat: Text.StyledText
                color: root.inkColor
                font.family: Theme.font
                font.pixelSize: 13
            }
        }
    }

    Component {
        id: contactComp
        Column {
            spacing: 6
            Repeater {
                model: Array.isArray(root.extraObj) ? root.extraObj : []
                Row {
                    required property var modelData
                    spacing: 10
                    Avatar {
                        size: 40
                        name: modelData.name
                    }
                    Column {
                        anchors.verticalCenter: parent.verticalCenter
                        Text {
                            text: modelData.name
                            color: root.inkColor
                            font.family: Theme.font
                            font.pixelSize: 14
                            font.weight: Font.Medium
                        }
                        Text {
                            readonly property var m: (modelData.vcard || "").match(/TEL[^:]*:([+\d\s-]+)/)
                            text: m ? m[1].trim() : ""
                            color: root.subColor
                            font.family: Theme.font
                            font.pixelSize: 12
                        }
                    }
                }
            }
        }
    }

    Component {
        id: pollComp
        Column {
            id: poll
            spacing: 8
            width: Math.min(root.maxBubble - 24, 320)
            readonly property var opts: root.extraObj.options || []
            readonly property var votes: root.extraObj.votes || {}
            readonly property var counts: {
                const c = {};
                let total = 0;
                for (const voter in votes) {
                    for (const o of votes[voter]) {
                        c[o] = (c[o] || 0) + 1;
                        total++;
                    }
                }
                c.__total = total;
                return c;
            }
            readonly property var mine: {
                const me = Hermes.status.meJid;
                return votes[me] || [];
            }
            Row {
                spacing: 8
                Icon { name: "ballot"; size: 20; color: root.inkColor }
                Text {
                    width: poll.width - 30
                    text: root.text
                    wrapMode: Text.Wrap
                    color: root.inkColor
                    font.family: Theme.font
                    font.pixelSize: 15
                    font.weight: Font.DemiBold
                }
            }
            Text {
                text: root.extraObj.selectable === 1 ? "Select one" : "Select one or more"
                color: root.subColor
                font.family: Theme.font
                font.pixelSize: 12
            }
            Repeater {
                model: poll.opts
                Item {
                    required property string modelData
                    readonly property bool chosen: poll.mine.indexOf(modelData) >= 0
                    readonly property int count: poll.counts[modelData] || 0
                    width: poll.width
                    height: 40
                    Row {
                        spacing: 10
                        width: parent.width
                        Rectangle {
                            width: 20; height: 20; radius: 10
                            border.width: 2
                            border.color: chosen ? Theme.primary : Theme.alpha(root.inkColor, 0.5)
                            color: chosen ? Theme.primary : "transparent"
                            Icon { anchors.centerIn: parent; visible: chosen; name: "check"; size: 14; color: Theme.fgPrimary }
                        }
                        Column {
                            width: parent.width - 30
                            spacing: 4
                            Item {
                                width: parent.width
                                height: optText.implicitHeight
                                Text { id: optText; text: modelData; color: root.inkColor; font.family: Theme.font; font.pixelSize: 14; width: parent.width - 30; elide: Text.ElideRight }
                                Text { anchors.right: parent.right; text: count; color: root.subColor; font.family: Theme.font; font.pixelSize: 13 }
                            }
                            Rectangle {
                                width: parent.width; height: 5; radius: 3
                                color: Theme.alpha(root.inkColor, 0.12)
                                Rectangle {
                                    height: parent.height; radius: 3
                                    width: poll.counts.__total ? parent.width * count / Math.max(1, Object.keys(poll.votes).length) : 0
                                    color: Theme.primary
                                    Behavior on width { NumberAnimation { duration: Theme.durMed } }
                                }
                            }
                        }
                    }
                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            let sel = poll.mine.slice();
                            if (chosen)
                                sel = sel.filter(o => o !== modelData);
                            else if (root.extraObj.selectable === 1)
                                sel = [modelData];
                            else
                                sel.push(modelData);
                            Hermes.act("polls.vote", { chat: root.chat, id: root.id, options: sel });
                        }
                    }
                }
            }
        }
    }
}
