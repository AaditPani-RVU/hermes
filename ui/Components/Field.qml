import QtQuick
import QtQuick.Controls
import qs.Services

// Pill-shaped single-line text field with a leading icon.
Rectangle {
    id: root
    property alias text: input.text
    property alias input: input
    property string placeholder: ""
    property string icon: "search"
    signal accepted
    signal escaped

    implicitHeight: 42
    radius: height / 2
    color: input.activeFocus ? Theme.surfaceContainerHighest : Theme.surfaceContainerHigh
    Behavior on color { ColorAnimation { duration: Theme.durFast } }

    Icon {
        id: leading
        anchors.left: parent.left
        anchors.leftMargin: 14
        anchors.verticalCenter: parent.verticalCenter
        name: root.icon
        size: 20
    }
    TextField {
        id: input
        anchors.left: leading.right
        anchors.right: clear.left
        anchors.leftMargin: 8
        anchors.verticalCenter: parent.verticalCenter
        background: null
        color: Theme.fgSurface
        placeholderText: root.placeholder
        placeholderTextColor: Theme.fgSurfaceVariant
        selectionColor: Theme.primary
        selectedTextColor: Theme.fgPrimary
        font.family: Theme.font
        font.pixelSize: 15
        padding: 0
        onAccepted: root.accepted()
        Keys.onEscapePressed: root.escaped()
    }
    IconButton {
        id: clear
        anchors.right: parent.right
        anchors.rightMargin: 4
        anchors.verticalCenter: parent.verticalCenter
        icon: "close"
        size: 34
        iconSize: 18
        visible: input.text !== ""
        width: visible ? size : 0
        onClicked: input.text = ""
    }
}
