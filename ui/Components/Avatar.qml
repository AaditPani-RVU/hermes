import QtQuick
import QtQuick.Effects
import qs.Services
import "../Services/Format.js" as F

// Round avatar: profile picture when available, otherwise tinted initials.
Item {
    id: root
    property string jid: ""
    property string name: ""
    property string path: ""
    property bool group: false
    property real size: 48
    property bool online: false
    readonly property string resolved: path !== "" ? path : (jid ? Hermes.avatarFor(jid) : "")

    implicitWidth: size
    implicitHeight: size

    Rectangle {
        anchors.fill: parent
        radius: width / 2
        color: Theme.mix(Theme.surfaceContainerHighest, Theme.nameColor(root.jid || root.name), 0.28)
        visible: img.status !== Image.Ready

        Text {
            anchors.centerIn: parent
            text: root.group ? "group" : F.initials(root.name)
            color: Theme.nameColor(root.jid || root.name)
            font.family: root.group ? Theme.iconFont : Theme.font
            font.pixelSize: root.size * (root.group ? 0.5 : 0.38)
            font.weight: Font.DemiBold
        }
    }
    Image {
        id: img
        anchors.fill: parent
        source: F.fileUrl(root.resolved)
        sourceSize: Qt.size(root.size * 2, root.size * 2)
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        visible: false
    }
    Rectangle {
        id: mask
        anchors.fill: parent
        radius: width / 2
        layer.enabled: true
        visible: false
    }
    MultiEffect {
        anchors.fill: parent
        source: img
        visible: img.status === Image.Ready
        maskEnabled: true
        maskSource: mask
        maskThresholdMin: 0.5
        maskSpreadAtMin: 1.0
    }
    Rectangle {
        visible: root.online
        width: root.size * 0.26
        height: width
        radius: width / 2
        color: "#3ddc84"
        border.width: 2
        border.color: Theme.surface
        anchors.right: parent.right
        anchors.bottom: parent.bottom
    }
}
