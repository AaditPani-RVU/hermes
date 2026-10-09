import QtQuick
import QtQuick.Controls
import Quickshell
import qs.Services
import qs.Components
import "../Services/Format.js" as F

// Full-window story viewer: progress bars, click/←/→ to move, Space to pause,
// Esc to close, and a reply box that sends a private message quoting the status.
Rectangle {
    id: viewer
    color: Theme.alpha("#000000", 0.92)
    visible: false
    focus: visible

    property var authors: []   // StatusAuthor list being browsed
    property int a: 0          // author index
    property int i: 0          // item index within author
    property bool userPaused: false
    readonly property bool paused: userPaused || replyInput.activeFocus
    property real progress: 0
    readonly property var author: authors.length ? authors[a] : null
    readonly property var item: author && author.items.length ? author.items[i] : null
    readonly property bool mineView: !!author && author.name === "My status"
    readonly property var extra: { try { return item && item.extra ? JSON.parse(item.extra) : ({}); } catch (e) { return {}; } }
    readonly property bool isVisual: !!item && (item.type === "image" || item.type === "video" || item.type === "gif")
    readonly property int duration: item && item.type === "video" ? Math.max(5, Math.min(30, item.mediaSecs || 10)) * 1000 : 6000
    property string mediaPath: ""

    signal closed

    function open(list, authorIndex) {
        authors = list;
        a = Math.max(0, authorIndex);
        // Start at the first unseen item, like the phone.
        const au = list[a];
        i = au && au.unseen > 0 ? au.items.length - au.unseen : 0;
        visible = true;
        forceActiveFocus();
        show();
    }
    function close() {
        visible = false;
        anim.stop();
        Hermes.refreshStatus();
        closed();
    }
    function show() {
        if (!item)
            return close();
        progress = 0;
        userPaused = false;
        mediaPath = item.mediaPath || "";
        if (isVisual && !mediaPath)
            Hermes.call("messages.download", { chat: "status@broadcast", id: item.id }, (p, err) => {
                if (!err && viewer.item && p)
                    viewer.mediaPath = p;
            });
        if (!item.fromMe)
            Hermes.call("status.view", { id: item.id });
        anim.restart();
    }
    function next() {
        if (!author)
            return close();
        if (i + 1 < author.items.length) {
            i++;
        } else {
            // Next person with something unseen, else close.
            let n = -1;
            for (let k = a + 1; k < authors.length; k++)
                if (authors[k].unseen > 0) { n = k; break; }
            if (n < 0)
                return close();
            a = n;
            i = authors[a].items.length - authors[a].unseen;
        }
        show();
    }
    function prev() {
        if (i > 0)
            i--;
        else if (a > 0) {
            a--;
            i = authors[a].items.length - 1;
        }
        show();
    }

    NumberAnimation {
        id: anim
        target: viewer
        property: "progress"
        from: 0
        to: 1
        duration: viewer.duration
        paused: viewer.paused || pressHold.pressed
        onFinished: if (viewer.visible && viewer.progress >= 1) viewer.next()
    }

    Keys.onPressed: e => {
        if (replyInput.activeFocus)
            return;
        switch (e.key) {
        case Qt.Key_Escape: close(); break;
        case Qt.Key_Right: case Qt.Key_L: next(); break;
        case Qt.Key_Left: case Qt.Key_H: prev(); break;
        case Qt.Key_Space: userPaused = !userPaused; break;
        case Qt.Key_R: replyInput.forceActiveFocus(); break;
        default: return;
        }
        e.accepted = true;
    }

    MouseArea {
        // Click outside the stage closes.
        anchors.fill: parent
        onClicked: viewer.close()
    }

    // The 9:16 stage
    Rectangle {
        id: stage
        anchors.centerIn: parent
        anchors.verticalCenterOffset: -20
        height: Math.min(parent.height - 140, 760)
        width: Math.min(parent.width - 160, height * 9 / 16)
        radius: Theme.radiusLg
        clip: true
        color: viewer.item && viewer.item.type === "text" ? (viewer.extra.bg ? "#" + viewer.extra.bg.slice(3) : Theme.primaryContainer) : "#000000"

        // Content
        Text {
            visible: !!viewer.item && viewer.item.type === "text"
            anchors.centerIn: parent
            width: parent.width - 56
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.Wrap
            text: viewer.item ? viewer.item.text : ""
            color: "#ffffff"
            font.family: Theme.font
            font.pixelSize: text.length < 60 ? 30 : text.length < 160 ? 22 : 17
            font.weight: Font.Medium
        }
        Image {
            visible: !!viewer.item && viewer.isVisual
            anchors.fill: parent
            fillMode: Image.PreserveAspectFit
            asynchronous: true
            source: !viewer.item ? "" : viewer.item.type === "image" && viewer.mediaPath ? F.fileUrl(viewer.mediaPath) : F.fileUrl(viewer.item.thumbPath || "")
        }
        Rectangle {
            // Play video / GIF in mpv
            visible: !!viewer.item && (viewer.item.type === "video" || viewer.item.type === "gif")
            anchors.centerIn: parent
            width: 64; height: 64; radius: 32
            color: Theme.alpha("#000000", 0.55)
            Icon { anchors.centerIn: parent; name: viewer.mediaPath ? "play_arrow" : "hourglass_top"; filled: true; size: 36; color: "#fff" }
            MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: if (viewer.mediaPath) { viewer.userPaused = true; Quickshell.execDetached(["mpv", "--force-window", viewer.mediaPath]); }
            }
        }
        Text {
            visible: !!viewer.item && viewer.item.type !== "text" && !viewer.isVisual
            anchors.centerIn: parent
            text: viewer.item ? F.escapeHtml(viewer.item.type === "voice" ? "🎤 Voice status" + (viewer.item.text ? "\n“" + viewer.item.text + "”" : "") : viewer.item.type) : ""
            horizontalAlignment: Text.AlignHCenter
            width: parent.width - 48
            wrapMode: Text.Wrap
            color: "#ffffff"
            font.family: Theme.font
            font.pixelSize: 18
        }
        // Caption
        Rectangle {
            visible: !!viewer.item && viewer.item.type !== "text" && viewer.item.text !== "" && viewer.isVisual
            anchors.bottom: parent.bottom
            width: parent.width
            height: cap.implicitHeight + 28
            color: Theme.alpha("#000000", 0.55)
            Text {
                id: cap
                anchors.centerIn: parent
                width: parent.width - 32
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.Wrap
                text: viewer.item ? viewer.item.text : ""
                color: "#ffffff"
                font.family: Theme.font
                font.pixelSize: 15
            }
        }

        // Tap zones: left third back, rest forward; hold to pause
        MouseArea {
            id: pressHold
            anchors.fill: parent
            anchors.topMargin: 70
            anchors.bottomMargin: 60
            pressAndHoldInterval: 200
            onClicked: e => e.x < width / 3 ? viewer.prev() : viewer.next()
        }

        // Top: progress bars and author
        Rectangle {
            anchors.left: parent.left
            anchors.right: parent.right
            height: 84
            gradient: Gradient {
                GradientStop { position: 0; color: Theme.alpha("#000000", 0.55) }
                GradientStop { position: 1; color: "transparent" }
            }
        }
        Row {
            id: bars
            x: 10
            y: 10
            width: parent.width - 20
            spacing: 4
            Repeater {
                model: viewer.author ? viewer.author.items.length : 0
                Rectangle {
                    required property int index
                    width: (bars.width - (bars.spacing * ((viewer.author ? viewer.author.items.length : 1) - 1))) / Math.max(1, viewer.author ? viewer.author.items.length : 1)
                    height: 3
                    radius: 1.5
                    color: Theme.alpha("#ffffff", 0.35)
                    Rectangle {
                        height: parent.height
                        radius: parent.radius
                        color: "#ffffff"
                        width: parent.width * (index < viewer.i ? 1 : index === viewer.i ? viewer.progress : 0)
                    }
                }
            }
        }
        Row {
            x: 14
            y: 24
            spacing: 10
            Avatar {
                size: 36
                jid: viewer.author && !viewer.mineView ? viewer.author.sender : (Hermes.status.meJid || "")
                name: viewer.author ? viewer.author.name : ""
                path: viewer.author ? (viewer.author.avatarPath || "") : ""
            }
            Column {
                anchors.verticalCenter: parent.verticalCenter
                Text { text: viewer.author ? viewer.author.name : ""; color: "#fff"; font.family: Theme.font; font.pixelSize: 14; font.weight: Font.DemiBold }
                Text { text: viewer.item ? F.age(viewer.item.ts) + " ago" : ""; color: Theme.alpha("#ffffff", 0.75); font.family: Theme.font; font.pixelSize: 12 }
            }
        }
        Row {
            anchors.right: parent.right
            anchors.rightMargin: 6
            y: 22
            IconButton { size: 36; icon: viewer.userPaused ? "play_arrow" : "pause"; tint: "#ffffff"; onClicked: viewer.userPaused = !viewer.userPaused }
            IconButton { size: 36; icon: "close"; tint: "#ffffff"; onClicked: viewer.close() }
        }
    }

    // Side arrows
    IconButton {
        anchors.right: stage.left
        anchors.rightMargin: 16
        anchors.verticalCenter: stage.verticalCenter
        icon: "chevron_left"
        tint: "#ffffff"
        container: Theme.alpha("#ffffff", 0.12)
        visible: viewer.a > 0 || viewer.i > 0
        onClicked: viewer.prev()
    }
    IconButton {
        anchors.left: stage.right
        anchors.leftMargin: 16
        anchors.verticalCenter: stage.verticalCenter
        icon: "chevron_right"
        tint: "#ffffff"
        container: Theme.alpha("#ffffff", 0.12)
        onClicked: viewer.next()
    }

    // Reply
    Rectangle {
        visible: !!viewer.item && !viewer.mineView
        anchors.top: stage.bottom
        anchors.topMargin: 14
        anchors.horizontalCenter: stage.horizontalCenter
        width: stage.width
        height: 46
        radius: 23
        color: Theme.alpha("#ffffff", 0.1)
        border.width: 1
        border.color: replyInput.activeFocus ? Theme.primary : Theme.alpha("#ffffff", 0.25)
        TextInput {
            id: replyInput
            anchors.left: parent.left
            anchors.right: sendReply.left
            anchors.leftMargin: 18
            anchors.verticalCenter: parent.verticalCenter
            color: "#ffffff"
            font.family: Theme.font
            font.pixelSize: 14
            clip: true
            Text {
                visible: !replyInput.text
                text: "Reply to " + (viewer.author ? viewer.author.name.split(" ")[0] : "") + "… (R)"
                color: Theme.alpha("#ffffff", 0.6)
                font: replyInput.font
            }
            Keys.onReturnPressed: sendReply.send()
            Keys.onEscapePressed: { text = ""; viewer.forceActiveFocus(); }
        }
        IconButton {
            id: sendReply
            anchors.right: parent.right
            anchors.rightMargin: 5
            anchors.verticalCenter: parent.verticalCenter
            size: 36
            iconSize: 20
            icon: "arrow_upward"
            tint: replyInput.text.trim() ? Theme.fgPrimary : Theme.alpha("#ffffff", 0.6)
            container: replyInput.text.trim() ? Theme.primary : "transparent"
            function send() {
                const t = replyInput.text.trim();
                if (!t || !viewer.item)
                    return;
                Hermes.act("status.reply", { id: viewer.item.id, text: t }, "Reply sent to " + viewer.author.name);
                replyInput.text = "";
                viewer.forceActiveFocus();
            }
            onClicked: send()
        }
    }
}
