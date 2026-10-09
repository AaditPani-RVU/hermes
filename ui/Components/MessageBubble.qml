import QtQuick
import QtQuick.Layouts
import qs.Services
import "../Services/Format.js" as F

// One message row in the conversation (list is bottom-to-top: index+1 is older).
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
    property real maxBubble: Math.min(560, width * 0.72)
    property bool highlighted: false
    signal menuRequested(var item, real x, real y)
    signal replyRequested
    signal quoteClicked(string id)
    signal mediaOpened(string path, string kind)

    readonly property var older: index + 1 < Hermes.messages.count ? Hermes.messages.get(index + 1) : null
    readonly property var newer: index > 0 ? Hermes.messages.get(index - 1) : null
    readonly property bool newDay: !older || F.dayKey(older.ts) !== F.dayKey(ts)
    readonly property bool groupedWithOlder: !!older && !newDay && older.sender === sender && ts - older.ts < 300 && older.type !== "system"
    readonly property bool showName: isGroup && !fromMe && !groupedWithOlder
    readonly property var reactionList: { try { return JSON.parse(reactions); } catch (e) { return []; } }
    readonly property var extraObj: { try { return extra ? JSON.parse(extra) : ({}); } catch (e) { return {}; } }
    readonly property bool bare: (type === "sticker" || (type === "text" && F.isJumboEmoji(text))) && !quotedId && !revoked
    readonly property bool isMedia: (type === "image" || type === "video" || type === "gif") && !revoked
    readonly property color bubbleColor: fromMe ? Theme.primaryContainer : Theme.surfaceContainerHigh
    readonly property color inkColor: fromMe ? Theme.fgPrimaryContainer : Theme.fgSurface
    readonly property color subColor: Theme.alpha(inkColor, 0.66)
    readonly property string footerReserve: "<span style='color:transparent'>&nbsp;&nbsp;" + (edited ? "edited " : "") + (starred ? "★ " : "") + "00:00" + (fromMe ? " ✓✓" : "") + "&nbsp;</span>"

    width: ListView.view ? ListView.view.width : 600
    height: col.implicitHeight + (groupedWithOlder ? 2 : 8)

    Column {
        id: col
        width: parent.width
        anchors.bottom: parent.bottom
        spacing: 0

        // Day separator chip
        Item {
            visible: root.newDay
            width: parent.width
            height: visible ? 44 : 0
            Rectangle {
                anchors.centerIn: parent
                height: 26
                width: dayText.implicitWidth + 24
                radius: 13
                color: Theme.surfaceContainerHighest
                Text {
                    id: dayText
                    anchors.centerIn: parent
                    text: F.dayLabel(root.ts)
                    color: Theme.fgSurfaceVariant
                    font.family: Theme.font
                    font.pixelSize: 12
                    font.weight: Font.Medium
                }
            }
        }

        Item {
            id: rowItem
            width: parent.width
            height: bubble.height + (reactionsRow.visible ? 14 : 0)

            Rectangle {
                // Highlight flash when jumping to a quoted message.
                anchors.fill: parent
                color: Theme.alpha(Theme.primary, 0.14)
                opacity: root.highlighted ? 1 : 0
                Behavior on opacity { NumberAnimation { duration: 600 } }
            }

            Rectangle {
                id: bubble
                x: root.fromMe ? parent.width - width - 20 : 20
                width: Math.min(root.maxBubble, Math.max(content.implicitWidth + 2 * pad, root.bare ? footer.implicitWidth + 16 : 72))
                height: content.implicitHeight + 2 * padV + (root.bare ? 26 : 0)
                readonly property int pad: root.bare ? 0 : root.isMedia ? 4 : 10
                readonly property int padV: root.bare ? 0 : root.isMedia ? 4 : 7
                radius: 18
                color: root.bare ? "transparent" : root.bubbleColor
                topLeftRadius: !root.fromMe && !root.groupedWithOlder ? 6 : 18
                topRightRadius: root.fromMe && !root.groupedWithOlder ? 6 : 18

                Behavior on width { enabled: false; NumberAnimation {} }

                ColumnLayout {
                    id: content
                    x: bubble.pad
                    y: bubble.padV
                    width: bubble.width - 2 * bubble.pad
                    spacing: 4

                    // Sender name in groups
                    Text {
                        visible: root.showName && !root.bare
                        Layout.leftMargin: root.isMedia ? 6 : 0
                        Layout.topMargin: root.isMedia ? 2 : 0
                        text: root.senderName
                        color: Theme.nameColor(root.sender)
                        font.family: Theme.font
                        font.pixelSize: 13
                        font.weight: Font.DemiBold
                        elide: Text.ElideRight
                        Layout.maximumWidth: root.maxBubble - 24
                    }

                    // Quoted reply
                    Rectangle {
                        visible: root.quotedId !== "" && !root.revoked
                        Layout.fillWidth: true
                        Layout.preferredWidth: Math.min(root.maxBubble - 24, Math.max(quoteName.implicitWidth, quoteBody.implicitWidth) + 22)
                        implicitHeight: quoteCol.implicitHeight + 12
                        radius: 10
                        color: Theme.alpha(root.inkColor, 0.08)
                        clip: true
                        Rectangle {
                            width: 4
                            height: parent.height
                            color: Theme.nameColor(root.quotedSender || "you")
                        }
                        Column {
                            id: quoteCol
                            x: 12
                            y: 6
                            width: parent.width - 20
                            spacing: 2
                            Text {
                                id: quoteName
                                text: root.quotedSender || "Message"
                                color: Theme.nameColor(root.quotedSender || "you")
                                font.family: Theme.font
                                font.pixelSize: 13
                                font.weight: Font.DemiBold
                                width: Math.min(implicitWidth, parent.width)
                                elide: Text.ElideRight
                            }
                            Text {
                                id: quoteBody
                                text: root.quotedText
                                color: root.subColor
                                font.family: Theme.font
                                font.pixelSize: 13
                                maximumLineCount: 3
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

                    // Text body (captions too)
                    TextEdit {
                        id: body
                        visible: (root.text !== "" && root.type !== "poll" && root.type !== "contact" && root.type !== "location") || root.revoked
                        Layout.fillWidth: true
                        Layout.preferredWidth: Math.min(root.maxBubble - 2 * bubble.pad - (root.isMedia ? 12 : 0), measure.implicitWidth + 1)
                        Layout.leftMargin: root.isMedia ? 6 : 0
                        Layout.rightMargin: root.isMedia ? 6 : 0
                        readOnly: true
                        selectByMouse: true
                        wrapMode: TextEdit.Wrap
                        textFormat: TextEdit.RichText
                        color: root.revoked ? root.subColor : root.inkColor
                        selectionColor: Theme.primary
                        selectedTextColor: Theme.fgPrimary
                        font.family: Theme.font
                        font.pixelSize: root.bare ? 44 : 15
                        font.italic: root.revoked
                        text: root.revoked
                            ? (root.fromMe ? "🚫 You deleted this message" : "🚫 This message was deleted") + root.footerReserve
                            : F.richText(root.text, Theme.primary, Theme.alpha(root.inkColor, 0.1)) + (root.bare ? "" : root.footerReserve)
                        onLinkActivated: link => Qt.openUrlExternally(link)
                        HoverHandler {
                            enabled: body.hoveredLink !== ""
                            cursorShape: Qt.PointingHandCursor
                        }
                        Text {
                            id: measure
                            visible: false
                            textFormat: Text.RichText
                            font: body.font
                            text: body.text
                        }
                    }

                    Item {
                        // Space for the footer when there's no text to float it in.
                        visible: !body.visible && !root.isMedia && root.type !== "sticker"
                        implicitHeight: 14
                        implicitWidth: footer.implicitWidth
                    }
                }

                // Time · edited · star · ticks
                Rectangle {
                    id: footerBg
                    anchors.right: parent.right
                    anchors.bottom: parent.bottom
                    anchors.rightMargin: root.isMedia || root.bare ? 8 : 10
                    anchors.bottomMargin: root.bare ? 2 : root.isMedia ? 8 : 5
                    width: footer.implicitWidth + (overlay ? 12 : 0)
                    height: footer.implicitHeight + (overlay ? 4 : 0)
                    radius: height / 2
                    readonly property bool overlay: (root.isMedia && !body.visible) || root.bare
                    color: overlay ? Theme.alpha("#000000", 0.45) : "transparent"
                    Row {
                        id: footer
                        anchors.centerIn: parent
                        spacing: 3
                        readonly property color ink: footerBg.overlay ? "#ffffff" : root.subColor
                        Text {
                            visible: root.edited && !root.revoked
                            text: "edited"
                            color: footer.ink
                            font.family: Theme.font
                            font.pixelSize: 11
                            anchors.verticalCenter: parent.verticalCenter
                        }
                        Icon {
                            visible: root.starred
                            name: "star"
                            filled: true
                            size: 13
                            color: footer.ink
                            anchors.verticalCenter: parent.verticalCenter
                        }
                        Text {
                            text: F.clock(root.ts)
                            color: footer.ink
                            font.family: Theme.font
                            font.pixelSize: 11
                            anchors.verticalCenter: parent.verticalCenter
                        }
                        Ticks {
                            visible: root.fromMe && !root.revoked
                            status: root.status
                            base: footer.ink
                            size: 15
                            anchors.verticalCenter: parent.verticalCenter
                        }
                    }
                }

                // Hover action: open message menu
                Rectangle {
                    id: chevron
                    visible: hover.hovered
                    anchors.top: parent.top
                    anchors.right: root.fromMe ? undefined : parent.right
                    anchors.left: root.fromMe ? parent.left : undefined
                    anchors.margins: -34
                    anchors.topMargin: 2
                    width: 28
                    height: 28
                    radius: 14
                    color: Theme.surfaceContainerHighest
                    Row {
                        anchors.centerIn: parent
                        Icon {
                            name: "add_reaction"
                            size: 17
                        }
                    }
                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.menuRequested(chevron, 0, chevron.height + 4)
                    }
                }
                HoverHandler {
                    id: hover
                    margin: 40
                }
                TapHandler {
                    acceptedButtons: Qt.RightButton
                    onTapped: (pt, button) => root.menuRequested(bubble, pt.position.x, pt.position.y)
                }
            }

            // Reaction chips
            Row {
                id: reactionsRow
                visible: root.reactionList.length > 0
                anchors.top: bubble.bottom
                anchors.topMargin: -8
                x: root.fromMe ? bubble.x + bubble.width - width - 12 : bubble.x + 12
                spacing: 4
                Rectangle {
                    height: 24
                    width: reactText.implicitWidth + 14
                    radius: 12
                    color: Theme.surfaceContainerHighest
                    border.width: 2
                    border.color: Theme.surface
                    Text {
                        id: reactText
                        anchors.centerIn: parent
                        font.family: Theme.font
                        font.pixelSize: 13
                        color: Theme.fgSurfaceVariant
                        text: {
                            const counts = {};
                            for (const r of root.reactionList)
                                counts[r.emoji] = (counts[r.emoji] || 0) + 1;
                            const keys = Object.keys(counts).slice(0, 4);
                            return keys.join("") + (root.reactionList.length > 1 ? " " + root.reactionList.length : "");
                        }
                    }
                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.menuRequested(reactionsRow, 0, 28)
                    }
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
