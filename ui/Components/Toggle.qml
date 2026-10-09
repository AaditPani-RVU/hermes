import QtQuick
import qs.Services

// Material 3 switch: track + thumb, with a check icon when on.
Item {
    id: root
    property bool checked: false
    signal toggled

    implicitWidth: 52
    implicitHeight: 32

    Rectangle {
        anchors.fill: parent
        radius: height / 2
        color: root.checked ? Theme.primary : Theme.surfaceContainerHighest
        border.width: root.checked ? 0 : 2
        border.color: Theme.outline
        Behavior on color { ColorAnimation { duration: Theme.durFast } }
    }
    Rectangle {
        readonly property real d: root.checked ? 24 : 16
        width: d
        height: d
        radius: d / 2
        anchors.verticalCenter: parent.verticalCenter
        x: root.checked ? root.width - d - 4 : 8
        color: root.checked ? Theme.fgPrimary : Theme.outline
        Behavior on x { NumberAnimation { duration: Theme.durMed; easing.type: Easing.OutCubic } }
        Behavior on width { NumberAnimation { duration: Theme.durFast } }
        Icon {
            anchors.centerIn: parent
            visible: root.checked
            name: "check"
            size: 16
            color: Theme.primary
        }
    }
    MouseArea {
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        onClicked: {
            root.checked = !root.checked;
            root.toggled();
        }
    }
}
