import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.Services

// Centered modal dialog surface with title and action buttons.
Popup {
    id: root
    parent: Overlay.overlay
    anchors.centerIn: parent
    modal: true
    focus: true
    width: 420
    padding: 24
    closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
    property string title: ""
    property string icon: ""
    property string acceptText: "OK"
    property bool acceptEnabled: true
    default property alias body: bodyCol.data
    signal accepted

    Overlay.modal: Rectangle {
        color: Theme.alpha(Theme.scrim, 0.45)
    }
    background: Rectangle {
        radius: Theme.radiusXl
        color: Theme.surfaceContainerHigh
    }
    enter: Transition {
        NumberAnimation { property: "opacity"; from: 0; to: 1; duration: Theme.durFast }
        NumberAnimation { property: "scale"; from: 0.9; to: 1; duration: Theme.durMed; easing.type: Easing.OutCubic }
    }
    exit: Transition {
        NumberAnimation { property: "opacity"; to: 0; duration: 120 }
    }

    contentItem: ColumnLayout {
        spacing: 16
        Icon {
            visible: root.icon !== ""
            Layout.alignment: Qt.AlignHCenter
            name: root.icon
            size: 28
            color: Theme.secondary
        }
        Text {
            Layout.fillWidth: true
            text: root.title
            horizontalAlignment: root.icon !== "" ? Text.AlignHCenter : Text.AlignLeft
            color: Theme.fgSurface
            font.family: Theme.font
            font.pixelSize: 22
        }
        ColumnLayout {
            id: bodyCol
            Layout.fillWidth: true
            spacing: 10
        }
        RowLayout {
            Layout.alignment: Qt.AlignRight
            spacing: 8
            TextButton {
                text: "Cancel"
                onClicked: root.close()
            }
            TextButton {
                text: root.acceptText
                filled: true
                enabled: root.acceptEnabled
                onClicked: {
                    root.accepted();
                    root.close();
                }
            }
        }
    }
}
