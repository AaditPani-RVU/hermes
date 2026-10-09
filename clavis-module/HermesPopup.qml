import QtQuick
import QtQuick.Effects
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland
import qs.Common
import qs.Components
import qs.Services
import qs.Widgets.common

// Recent chats with inline quick reply, shown under the bar pill.
//
// This is a full-screen transparent layer-shell surface rather than an xdg popup of the
// bar: the bar never takes keyboard focus, so a popup parented to it can't receive typing
// either. Owning a layer with exclusive keyboard focus while open makes quick reply work,
// and clicking outside the card (or Esc) closes it.
PanelWindow {
    id: root

    property Item anchorItem: null
    property string edge: "top"
    property string replyJid: ""
    readonly property real gap: 8

    function open() {
        HermesBarService.reloadChats();
        root.replyJid = "";
        root.place();
        root.visible = true;
        keyScope.forceActiveFocus();
    }

    function close() {
        root.visible = false;
    }

    // Put the card next to the pill. The bar spans its whole edge, so the pill's
    // position inside the bar window plus the bar's offset on screen is its screen position.
    property real cardX: 0
    property real cardY: 0
    function place() {
        if (!root.anchorItem)
            return;
        const barWin = root.anchorItem.QsWindow.window;
        const p = root.anchorItem.mapToItem(null, 0, 0);
        const aw = root.anchorItem.width, ah = root.anchorItem.height;
        const offX = root.edge === "right" && barWin ? root.width - barWin.width : 0;
        const offY = root.edge === "bottom" && barWin ? root.height - barWin.height : 0;
        const cw = card.width, ch = card.implicitHeight;
        const clampX = x => Math.max(root.gap, Math.min(root.width - cw - root.gap, x));
        const clampY = y => Math.max(root.gap, Math.min(root.height - ch - root.gap, y));
        switch (root.edge) {
        case "bottom":
            root.cardX = clampX(p.x + aw / 2 - cw / 2);
            root.cardY = offY + p.y - ch - root.gap;
            break;
        case "left":
            root.cardX = p.x + aw + root.gap;
            root.cardY = clampY(p.y);
            break;
        case "right":
            root.cardX = offX + p.x - cw - root.gap;
            root.cardY = clampY(p.y);
            break;
        default:
            root.cardX = clampX(p.x + aw / 2 - cw / 2);
            root.cardY = p.y + ah + root.gap;
        }
    }

    function timeLabel(ts) {
        if (!ts)
            return "";
        const d = new Date(ts * 1000);
        const now = new Date();
        if (d.toDateString() === now.toDateString())
            return Qt.formatTime(d, "hh:mm");
        const yesterday = new Date(now.getTime() - 86400000);
        if (d.toDateString() === yesterday.toDateString())
            return qsTr("Yesterday");
        if (now - d < 6 * 86400000)
            return Qt.formatDate(d, "ddd");
        return Qt.formatDate(d, "dd/MM/yy");
    }

    visible: false
    color: "transparent"
    exclusiveZone: 0
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "clavis-shell-hermes"
    WlrLayershell.exclusionMode: ExclusionMode.Ignore
    WlrLayershell.keyboardFocus: root.visible ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

    anchors {
        top: true
        bottom: true
        left: true
        right: true
    }

    // Click anywhere outside the card to close.
    MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.AllButtons
        onClicked: root.close()
    }

    FocusScope {
        id: keyScope

        anchors.fill: parent
        focus: root.visible
        Keys.onEscapePressed: event => {
            if (root.replyJid)
                root.replyJid = "";
            else
                root.close();
            event.accepted = true;
        }

        StyledRectangularShadow {
            target: card
        }

        Rectangle {
            id: card

            x: root.cardX
            y: root.cardY
            width: implicitWidth
            implicitWidth: 360
            implicitHeight: column.implicitHeight + 16
            color: BlurService.backgroundColor(Appearance.colors.colLayer0)
            radius: 18
            border.width: 1
            border.color: Appearance.colors.colLayer0Border
            clip: true

            // Swallow clicks on the card's empty space so they don't close it.
            MouseArea {
                anchors.fill: parent
                acceptedButtons: Qt.AllButtons
            }

            Behavior on implicitHeight {
                NumberAnimation {
                    duration: Appearance.animation.elementResize.duration
                    easing.type: Appearance.animation.elementResize.type
                    easing.bezierCurve: Appearance.animation.elementResize.bezierCurve
                }
            }

            ColumnLayout {
                id: column

                anchors {
                    left: parent.left
                    right: parent.right
                    top: parent.top
                    margins: 8
                }
                spacing: 2

                // Header
                RowLayout {
                    Layout.fillWidth: true
                    Layout.leftMargin: 8
                    Layout.bottomMargin: 4
                    spacing: 4

                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 0

                        Text {
                            text: "WhatsApp"
                            font.family: Fonts.ui
                            font.pixelSize: 15
                            font.weight: Font.DemiBold
                            color: Appearance.colors.colOnLayer0
                        }

                        Text {
                            text: !HermesBarService.daemonUp ? qsTr("Daemon not running") : HermesBarService.focusActive
                                                              ? qsTr("Focus mode · only VIPs notify") :
                                                                HermesBarService.needsYou > 0 ? qsTr("%1 need you").arg(HermesBarService.needsYou)
                                                                    + (HermesBarService.fyi > 0 ? qsTr(" · %1 FYI").arg(HermesBarService.fyi) : "") :
                                                                qsTr("Inbox zero")
                            font.family: Fonts.ui
                            font.pixelSize: 12
                            color: Appearance.colors.colSubtext
                        }
                    }

                    HeaderButton {
                        icon: HermesBarService.focusActive ? "do_not_disturb_on" : "do_not_disturb_off"
                        active: HermesBarService.focusActive
                        enabled: HermesBarService.daemonUp
                        onClicked: HermesBarService.toggleFocus()
                    }

                    HeaderButton {
                        icon: "open_in_new"
                        onClicked: {
                            HermesBarService.openChat("");
                            root.close();
                        }
                    }
                }

                Text {
                    Layout.fillWidth: true
                    Layout.margins: 12
                    visible: !HermesBarService.daemonUp || !HermesBarService.loggedIn
                    wrapMode: Text.Wrap
                    text: !HermesBarService.daemonUp ? qsTr("Start it with: systemctl --user start hermesd") :
                                                       qsTr("This computer isn't linked yet. Open Hermes to scan the QR code.")
                    font.family: Fonts.ui
                    font.pixelSize: 13
                    color: Appearance.colors.colOnLayer1
                }

                Repeater {
                    model: HermesBarService.daemonUp ? HermesBarService.recent : []

                    delegate: ChatEntry {
                        required property var modelData

                        Layout.fillWidth: true
                        chat: modelData
                    }
                }
            }
        }
    }

    component HeaderButton: Rectangle {
        id: hb

        property string icon
        property bool active: false

        signal clicked

        implicitWidth: 34
        implicitHeight: 34
        radius: 17
        color: hb.active ? Appearance.colors.colSecondaryContainer : hbMouse.containsMouse ? Appearance.colors.colLayer0Hover :
                                                                                             "transparent"
        opacity: enabled ? 1 : 0.4

        MaterialSymbol {
            anchors.centerIn: parent
            text: hb.icon
            iconSize: 20
            fill: hb.active ? 1 : 0
            color: hb.active ? Appearance.colors.colOnSecondaryContainer : Appearance.colors.colOnLayer0
        }

        MouseArea {
            id: hbMouse

            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: hb.clicked()
        }
    }

    component ChatEntry: Rectangle {
        id: entry

        property var chat
        readonly property bool replying: root.replyJid === entry.chat.jid
        readonly property bool unread: entry.chat.unread > 0 || entry.chat.markedUnread
        readonly property bool muted: entry.chat.mutedUntil > Date.now() / 1000

        implicitHeight: entryColumn.implicitHeight + 12
        radius: 14
        color: entry.replying ? Appearance.colors.colLayer2 : rowMouse.containsMouse ? Appearance.colors.colLayer0Hover :
                                                                                       "transparent"

        ColumnLayout {
            id: entryColumn

            anchors {
                left: parent.left
                right: parent.right
                verticalCenter: parent.verticalCenter
                leftMargin: 8
                rightMargin: 8
            }
            spacing: 8

            RowLayout {
                Layout.fillWidth: true
                spacing: 10

                Rectangle {
                    // Avatar: photo if cached, otherwise the first letter.
                    Layout.preferredWidth: 38
                    Layout.preferredHeight: 38
                    radius: 19
                    color: Appearance.colors.colSecondaryContainer

                    Text {
                        anchors.centerIn: parent
                        visible: avatar.status !== Image.Ready
                        text: entry.chat.isGroup ? "" : (entry.chat.name.replace(/^[\s+~@._-]+/, "") || "?").charAt(0).toUpperCase()
                        font.family: Fonts.ui
                        font.pixelSize: 16
                        font.weight: Font.DemiBold
                        color: Appearance.colors.colOnSecondaryContainer
                    }

                    MaterialSymbol {
                        anchors.centerIn: parent
                        visible: entry.chat.isGroup && avatar.status !== Image.Ready
                        text: "group"
                        iconSize: 20
                        color: Appearance.colors.colOnSecondaryContainer
                    }

                    Image {
                        id: avatar

                        anchors.fill: parent
                        source: entry.chat.avatarPath ? "file://" + encodeURI(entry.chat.avatarPath) : ""
                        sourceSize: Qt.size(76, 76)
                        fillMode: Image.PreserveAspectCrop
                        asynchronous: true
                        visible: false
                    }

                    Rectangle {
                        id: avatarMask

                        anchors.fill: parent
                        radius: width / 2
                        layer.enabled: true
                        visible: false
                    }

                    MultiEffect {
                        anchors.fill: parent
                        source: avatar
                        visible: avatar.status === Image.Ready
                        maskEnabled: true
                        maskSource: avatarMask
                        maskThresholdMin: 0.5
                        maskSpreadAtMin: 1.0
                    }
                }

                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 1

                    RowLayout {
                        Layout.fillWidth: true

                        Text {
                            Layout.fillWidth: true
                            text: entry.chat.name
                            elide: Text.ElideRight
                            font.family: Fonts.ui
                            font.pixelSize: 14
                            font.weight: entry.unread ? Font.DemiBold : Font.Medium
                            color: Appearance.colors.colOnLayer0
                        }

                        MaterialSymbol {
                            visible: entry.chat.bucket === "mention"
                            text: "alternate_email"
                            iconSize: 14
                            color: Appearance.colors.colTertiary
                        }

                        Text {
                            text: root.timeLabel(entry.chat.lastTs)
                            font.family: Fonts.ui
                            font.pixelSize: 11
                            color: entry.unread ? Appearance.colors.colPrimary : Appearance.colors.colSubtext
                        }
                    }

                    RowLayout {
                        Layout.fillWidth: true

                        Text {
                            Layout.fillWidth: true
                            text: {
                                const c = entry.chat;
                                const who = c.lastFromMe ? qsTr("You") : c.isGroup ? (c.lastSender || "") : "";
                                return (who ? who + ": " : "") + (c.lastPreview || "").replace(/\s+/g, " ");
                            }
                            elide: Text.ElideRight
                            maximumLineCount: 1
                            textFormat: Text.PlainText
                            font.family: Fonts.ui
                            font.pixelSize: 12
                            color: Appearance.colors.colSubtext
                        }

                        MaterialSymbol {
                            visible: entry.muted
                            text: "notifications_off"
                            iconSize: 14
                            color: Appearance.colors.colSubtext
                        }

                        Rectangle {
                            visible: entry.unread
                            implicitWidth: Math.max(18, badge.implicitWidth + 10)
                            implicitHeight: 18
                            radius: 9
                            color: entry.muted ? Appearance.colors.colSubtext : Appearance.colors.colPrimary

                            Text {
                                id: badge

                                anchors.centerIn: parent
                                text: entry.chat.unread > 0 ? entry.chat.unread : ""
                                font.family: Fonts.numeric
                                font.pixelSize: 10
                                font.weight: Font.Bold
                                color: Appearance.colors.colOnPrimary
                            }
                        }
                    }
                }
            }

            // Quick reply
            Rectangle {
                Layout.fillWidth: true
                Layout.leftMargin: 48
                Layout.bottomMargin: 2
                visible: entry.replying
                implicitHeight: Math.max(36, input.implicitHeight + 16)
                radius: 18
                color: Appearance.colors.colLayer0
                border.width: 1
                border.color: input.activeFocus ? Appearance.colors.colPrimary : Appearance.colors.colLayer0Border

                TextInput {
                    id: input

                    property bool sending: false

                    anchors {
                        left: parent.left
                        right: sendButton.left
                        verticalCenter: parent.verticalCenter
                        leftMargin: 14
                        rightMargin: 6
                    }
                    wrapMode: TextInput.Wrap
                    font.family: Fonts.ui
                    font.pixelSize: 13
                    color: Appearance.colors.colOnLayer0
                    selectionColor: Appearance.colors.colPrimary
                    selectedTextColor: Appearance.colors.colOnPrimary
                    readOnly: input.sending
                    onVisibleChanged: {
                        if (visible)
                            forceActiveFocus();
                        else
                            text = "";
                    }
                    Keys.onReturnPressed: event => {
                        if (event.modifiers & Qt.ShiftModifier)
                            input.insert(input.cursorPosition, "\n");
                        else
                            input.send();
                    }
                    Keys.onEnterPressed: input.send()

                    function send() {
                        const text = input.text.trim();
                        if (!text || input.sending)
                            return;
                        input.sending = true;
                        HermesBarService.sendText(entry.chat.jid, text, err => {
                            input.sending = false;
                            if (err) {
                                placeholder.text = err;
                                return;
                            }
                            input.text = "";
                            root.replyJid = "";
                        });
                    }

                    Text {
                        id: placeholder

                        anchors.fill: parent
                        visible: !input.text
                        text: qsTr("Reply to %1").arg(entry.chat.name)
                        elide: Text.ElideRight
                        font: input.font
                        color: Appearance.colors.colSubtext
                    }
                }

                MaterialSymbol {
                    id: sendButton

                    anchors {
                        right: parent.right
                        rightMargin: 10
                        verticalCenter: parent.verticalCenter
                    }
                    text: input.sending ? "hourglass_top" : "send"
                    iconSize: 18
                    fill: 1
                    color: input.text.trim() ? Appearance.colors.colPrimary : Appearance.colors.colSubtext

                    MouseArea {
                        anchors.fill: parent
                        anchors.margins: -6
                        cursorShape: Qt.PointingHandCursor
                        onClicked: input.send()
                    }
                }
            }
        }

        MouseArea {
            id: rowMouse

            // Only covers the header row so the reply field stays clickable.
            anchors {
                left: parent.left
                right: parent.right
                top: parent.top
            }
            height: 50
            hoverEnabled: true
            acceptedButtons: Qt.LeftButton | Qt.MiddleButton | Qt.RightButton
            cursorShape: Qt.PointingHandCursor
            onClicked: event => {
                if (event.button === Qt.LeftButton) {
                    root.replyJid = entry.replying ? "" : entry.chat.jid;
                } else if (event.button === Qt.MiddleButton) {
                    // Same as "e" in the inbox: clear it (marks read too).
                    HermesBarService.markDone(entry.chat.jid);
                } else {
                    HermesBarService.openChat(entry.chat.jid);
                    root.close();
                }
            }
            onDoubleClicked: {
                HermesBarService.openChat(entry.chat.jid);
                root.close();
            }
        }
    }
}
