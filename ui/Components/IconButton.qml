import QtQuick
import qs.Services

// Circular M3 icon button with state layer and optional tooltip-ish label.
Item {
    id: root
    property string icon: ""
    property real size: 40
    property real iconSize: 22
    property bool filled: false
    property bool toggled: false
    property bool enabledState: true
    property color tint: Theme.fgSurfaceVariant
    property color container: "transparent"
    property string tip: ""
    signal clicked
    signal rightClicked

    implicitWidth: size
    implicitHeight: size
    opacity: enabledState ? 1 : 0.38

    Rectangle {
        anchors.fill: parent
        radius: height / 2
        color: root.toggled ? Theme.secondaryContainer : root.container
        Behavior on color { ColorAnimation { duration: Theme.durFast } }
    }
    Rectangle {
        anchors.fill: parent
        radius: height / 2
        color: root.toggled ? Theme.fgSecondaryContainer : root.tint
        opacity: mouse.pressed ? 0.16 : mouse.containsMouse ? 0.08 : 0
        Behavior on opacity { NumberAnimation { duration: Theme.durFast } }
    }
    Icon {
        anchors.centerIn: parent
        name: root.icon
        size: root.iconSize
        filled: root.filled || root.toggled
        color: root.toggled ? Theme.fgSecondaryContainer : root.tint
        scale: mouse.pressed ? 0.88 : 1
        Behavior on scale { NumberAnimation { duration: Theme.durFast; easing.type: Easing.OutBack } }
    }
    MouseArea {
        id: mouse
        anchors.fill: parent
        hoverEnabled: true
        enabled: root.enabledState
        cursorShape: Qt.PointingHandCursor
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        onClicked: e => e.button === Qt.RightButton ? root.rightClicked() : root.clicked()
    }
    Tip {
        text: root.tip
        shown: root.tip !== "" && mouse.containsMouse && !mouse.pressed
    }
}
