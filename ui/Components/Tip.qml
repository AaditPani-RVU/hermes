import QtQuick
import qs.Services

// Lightweight tooltip that appears under its parent after a short hover.
Rectangle {
    id: tip
    property string text: ""
    property bool shown: false
    property bool above: false
    visible: opacity > 0
    opacity: shown && delay.done ? 1 : 0
    z: 1000
    width: label.implicitWidth + 16
    height: label.implicitHeight + 8
    radius: 6
    color: Theme.inverseSurface
    x: Math.round((parent.width - width) / 2)
    y: above ? -height - 6 : parent.height + 6
    Behavior on opacity { NumberAnimation { duration: Theme.durFast } }

    Timer {
        id: delay
        property bool done: false
        interval: 550
        running: tip.shown
        onRunningChanged: if (!running) done = false
        onTriggered: done = true
    }
    Text {
        id: label
        anchors.centerIn: parent
        text: tip.text
        color: Theme.inverseOnSurface
        font.family: Theme.font
        font.pixelSize: 12
    }
}
