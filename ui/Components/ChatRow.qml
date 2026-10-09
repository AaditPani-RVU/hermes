import QtQuick
import qs.Services
import "../Services/Format.js" as F

// One chat in the list.
Item {
    id: row
    required property int index
    required property string jid
    required property string name
    required property bool isGroup
    required property real lastTs
    required property string lastPreview
    required property string lastSender
    required property bool lastFromMe
    required property int lastStatus
    required property int unread
    required property bool markedUnread
    required property real pinnedTs
    required property real mutedUntil
    required property string avatarPath
    required property string draft

    readonly property bool selected: Hermes.currentChat === jid
    readonly property bool muted: mutedUntil * 1000 > Date.now()
    readonly property var typingInfo: Hermes.typing[jid]
    readonly property bool hasUnread: unread > 0 || markedUnread
    property bool shown: true
    signal menuRequested(var item, real x, real y)

    width: ListView.view ? ListView.view.width : 320
    height: shown ? 76 : 0
    visible: shown

    Rectangle {
        anchors.fill: parent
        anchors.leftMargin: 8
        anchors.rightMargin: 8
        radius: Theme.radiusLg
        color: row.selected ? Theme.secondaryContainer : Theme.fgSurface
        opacity: row.selected ? 1 : mouse.pressed ? 0.1 : mouse.containsMouse ? 0.05 : 0
        Behavior on opacity { NumberAnimation { duration: Theme.durFast } }
    }

    Avatar {
        id: avatar
        anchors.left: parent.left
        anchors.leftMargin: 20
        anchors.verticalCenter: parent.verticalCenter
        size: 50
        jid: row.jid
        name: row.name
        path: row.avatarPath
        group: row.isGroup
        online: !!(Hermes.presence[row.jid] && Hermes.presence[row.jid].online)
    }

    Column {
        anchors.left: avatar.right
        anchors.leftMargin: 14
        anchors.right: parent.right
        anchors.rightMargin: 22
        anchors.verticalCenter: parent.verticalCenter
        spacing: 4

        Item {
            width: parent.width
            height: nameText.implicitHeight
            Text {
                id: nameText
                anchors.left: parent.left
                anchors.right: timeText.left
                anchors.rightMargin: 8
                text: row.name
                elide: Text.ElideRight
                color: row.selected ? Theme.fgSecondaryContainer : Theme.fgSurface
                font.family: Theme.font
                font.pixelSize: 16
                font.weight: row.hasUnread ? Font.DemiBold : Font.Medium
            }
            Text {
                id: timeText
                anchors.right: parent.right
                anchors.baseline: nameText.baseline
                text: F.listTime(row.lastTs)
                color: row.hasUnread && !row.muted ? Theme.primary : Theme.fgSurfaceVariant
                font.family: Theme.font
                font.pixelSize: 12
                font.weight: row.hasUnread ? Font.DemiBold : Font.Normal
            }
        }
        Item {
            width: parent.width
            height: 22
            Row {
                id: previewRow
                anchors.left: parent.left
                anchors.right: badges.left
                anchors.rightMargin: 6
                anchors.verticalCenter: parent.verticalCenter
                spacing: 3
                Ticks {
                    visible: row.lastFromMe && !row.typingInfo && row.draft === ""
                    status: row.lastStatus
                    anchors.verticalCenter: parent.verticalCenter
                }
                Text {
                    width: previewRow.width - (row.lastFromMe ? 20 : 0)
                    anchors.verticalCenter: parent.verticalCenter
                    elide: Text.ElideRight
                    maximumLineCount: 1
                    textFormat: Text.StyledText
                    font.family: Theme.font
                    font.pixelSize: 14
                    color: row.typingInfo ? Theme.primary : Theme.fgSurfaceVariant
                    text: {
                        if (row.typingInfo) {
                            const names = Object.values(row.typingInfo.names);
                            const verb = row.typingInfo.recording ? "recording audio…" : "typing…";
                            return row.isGroup ? names[0].split(" ")[0] + " is " + verb : verb;
                        }
                        if (row.draft !== "")
                            return "<font color='" + Theme.error + "'>Draft:</font> " + F.escapeHtml(row.draft);
                        const p = F.escapeHtml(row.lastPreview);
                        if (row.isGroup && row.lastSender && !row.lastFromMe)
                            return row.lastSender + ": " + p; // already shortened by the daemon
                        return p;
                    }
                }
            }
            Row {
                id: badges
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                spacing: 4
                Icon {
                    visible: row.muted
                    name: "notifications_off"
                    size: 17
                    anchors.verticalCenter: parent.verticalCenter
                }
                Icon {
                    visible: row.pinnedTs > 0
                    name: "keep"
                    size: 17
                    filled: true
                    anchors.verticalCenter: parent.verticalCenter
                }
                Rectangle {
                    visible: row.hasUnread
                    anchors.verticalCenter: parent.verticalCenter
                    height: 20
                    width: Math.max(20, countText.implicitWidth + 12)
                    radius: 10
                    color: row.muted ? Theme.outline : Theme.primary
                    Text {
                        id: countText
                        anchors.centerIn: parent
                        text: row.unread > 0 ? (row.unread > 999 ? "999+" : row.unread) : ""
                        color: row.muted ? Theme.surface : Theme.fgPrimary
                        font.family: Theme.font
                        font.pixelSize: 11
                        font.weight: Font.Bold
                    }
                }
            }
        }
    }

    MouseArea {
        id: mouse
        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        cursorShape: Qt.PointingHandCursor
        onClicked: e => {
            if (e.button === Qt.RightButton)
                row.menuRequested(row, e.x, e.y);
            else
                Hermes.openChat(row.jid);
        }
    }
}
