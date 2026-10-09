import QtQuick
import qs.Services

// Row inside a PopupMenu.
Item {
    id: root
    property string icon: ""
    property string text: ""
    property bool danger: false
    signal triggered

    width: parent ? parent.width : 220
    height: 42

    Rectangle {
        anchors.fill: parent
        anchors.leftMargin: 4
        anchors.rightMargin: 4
        radius: 10
        color: root.danger ? Theme.error : Theme.fgSurface
        opacity: mouse.pressed ? 0.14 : mouse.containsMouse ? 0.08 : 0
    }
    Row {
        anchors.verticalCenter: parent.verticalCenter
        anchors.left: parent.left
        anchors.leftMargin: 16
        spacing: 14
        Icon {
            name: root.icon
            size: 20
            color: root.danger ? Theme.error : Theme.fgSurfaceVariant
        }
        Text {
            anchors.verticalCenter: parent.verticalCenter
            text: root.text
            color: root.danger ? Theme.error : Theme.fgSurface
            font.family: Theme.font
            font.pixelSize: 14
        }
    }
    MouseArea {
        id: mouse
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: root.triggered()
    }
}
