import QtQuick
import qs.Services

// Three bouncing dots.
Row {
    spacing: 6
    property color dotColor: Theme.primary
    Repeater {
        model: 3
        Rectangle {
            required property int index
            width: 10; height: 10; radius: 5
            color: parent.dotColor
            SequentialAnimation on y {
                loops: Animation.Infinite
                PauseAnimation { duration: index * 140 }
                NumberAnimation { from: 0; to: -8; duration: 280; easing.type: Easing.OutQuad }
                NumberAnimation { from: -8; to: 0; duration: 280; easing.type: Easing.InQuad }
                PauseAnimation { duration: (2 - index) * 140 + 200 }
            }
        }
    }
}
