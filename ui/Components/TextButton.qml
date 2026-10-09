import QtQuick
import qs.Services

// M3 text / filled button.
Rectangle {
    id: root
    property string text: ""
    property string icon: ""
    property bool filled: false
    property bool tonal: false
    signal clicked

    implicitHeight: 40
    implicitWidth: row.implicitWidth + 32
    radius: 20
    opacity: enabled ? 1 : 0.38
    color: filled ? Theme.primary : tonal ? Theme.secondaryContainer : "transparent"
    readonly property color ink: filled ? Theme.fgPrimary : tonal ? Theme.fgSecondaryContainer : Theme.primary

    Rectangle {
        anchors.fill: parent
        radius: parent.radius
        color: root.ink
        opacity: mouse.pressed ? 0.14 : mouse.containsMouse ? 0.08 : 0
    }
    Row {
        id: row
        anchors.centerIn: parent
        spacing: 8
        Icon {
            visible: root.icon !== ""
            name: root.icon
            size: 18
            color: root.ink
            anchors.verticalCenter: parent.verticalCenter
        }
        Text {
            text: root.text
            color: root.ink
            font.family: Theme.font
            font.pixelSize: 14
            font.weight: Font.DemiBold
            anchors.verticalCenter: parent.verticalCenter
        }
    }
    MouseArea {
        id: mouse
        anchors.fill: parent
        hoverEnabled: true
        enabled: root.enabled
        cursorShape: Qt.PointingHandCursor
        onClicked: root.clicked()
    }
}
