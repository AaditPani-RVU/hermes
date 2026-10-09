import QtQuick
import QtQuick.Controls
import qs.Services
import qs.Components
import "../Services/Format.js" as F

// Pending scheduled messages.
Rectangle {
    id: pane
    color: Theme.surfaceContainerLow
    signal openChat(string chat)

    Text {
        id: title
        x: 22
        y: 14
        height: 44
        verticalAlignment: Text.AlignVCenter
        text: "Scheduled"
        color: Theme.fgSurface
        font.family: Theme.font
        font.pixelSize: 26
        font.weight: Font.DemiBold
    }
    Text {
        id: hint
        anchors.top: title.bottom
        x: 22
        width: parent.width - 44
        wrapMode: Text.Wrap
        text: "Write now, send later. In any chat press Ctrl+Enter or right-click the send button. Hermes must be running at the send time."
        color: Theme.fgSurfaceVariant
        font.family: Theme.font
        font.pixelSize: 13
    }
    ListView {
        anchors.top: hint.bottom
        anchors.topMargin: 14
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        clip: true
        spacing: 8
        model: Hermes.scheduled
        ScrollBar.vertical: ScrollBar {}
        delegate: Rectangle {
            required property var modelData
            x: 12
            width: ListView.view.width - 24
            height: c.implicitHeight + 24
            radius: Theme.radiusMd
            color: Theme.surfaceContainer
            Column {
                id: c
                x: 14; y: 12
                width: parent.width - 70
                spacing: 4
                Row {
                    spacing: 6
                    Icon { name: "schedule"; size: 16; color: Theme.primary }
                    Text {
                        text: F.dayLabel(modelData.sendAt) + ", " + F.clock(modelData.sendAt) + "  ·  " + (modelData.name || modelData.chat.split("@")[0])
                        color: Theme.primary
                        font.family: Theme.font
                        font.pixelSize: 13
                        font.weight: Font.DemiBold
                    }
                }
                Text {
                    width: parent.width
                    wrapMode: Text.Wrap
                    maximumLineCount: 4
                    elide: Text.ElideRight
                    text: modelData.text
                    color: Theme.fgSurface
                    font.family: Theme.font
                    font.pixelSize: 14
                }
            }
            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: pane.openChat(modelData.chat) }
            IconButton {
                anchors.right: parent.right
                anchors.rightMargin: 6
                anchors.verticalCenter: parent.verticalCenter
                icon: "cancel_schedule_send"
                tip: "Cancel"
                onClicked: Hermes.act("schedule.cancel", { id: modelData.id }, "Cancelled")
            }
        }
        Text {
            anchors.centerIn: parent
            visible: Hermes.scheduled.length === 0
            text: "Nothing scheduled"
            color: Theme.fgSurfaceVariant
            font.family: Theme.font
            font.pixelSize: 14
        }
    }
}
