import QtQuick
import QtQuick.Controls
import qs.Services
import "../Services/Format.js" as F

// "Snooze until…" dialog. Number keys pick a preset; Esc cancels.
Popup {
    id: root
    parent: Overlay.overlay
    anchors.centerIn: parent
    modal: true
    focus: true
    width: 340
    padding: 10
    closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside

    property string chat: ""
    property string chatName: ""
    property string msgId: "" // set for "remind me about this message"
    property var options: []
    property int current: 0

    function openFor(jid, name, msg) {
        chat = jid;
        chatName = name || "";
        msgId = msg || "";
        options = F.snoozeOptions();
        current = 0;
        open();
    }
    onOpened: contentItem.forceActiveFocus()

    function pick(i) {
        if (i < 0 || i >= options.length)
            return;
        Hermes.snooze(chat, options[i].ts, msgId);
        close();
    }

    Overlay.modal: Rectangle {
        color: Theme.alpha(Theme.scrim, 0.35)
    }
    background: Rectangle {
        radius: Theme.radiusLg
        color: Theme.surfaceContainerHigh
        border.width: 1
        border.color: Theme.alpha(Theme.outlineVariant, 0.5)
    }
    enter: Transition {
        NumberAnimation { property: "opacity"; from: 0; to: 1; duration: Theme.durFast }
        NumberAnimation { property: "scale"; from: 0.94; to: 1; duration: Theme.durMed; easing.type: Easing.OutCubic }
    }
    exit: Transition {
        NumberAnimation { property: "opacity"; to: 0; duration: 100 }
    }

    contentItem: Column {
        spacing: 2
        focus: true
        Keys.onPressed: e => {
            if (e.key >= Qt.Key_1 && e.key <= Qt.Key_9) {
                root.pick(e.key - Qt.Key_1);
            } else if (e.key === Qt.Key_Down || e.key === Qt.Key_J) {
                root.current = Math.min(root.options.length - 1, root.current + 1);
            } else if (e.key === Qt.Key_Up || e.key === Qt.Key_K) {
                root.current = Math.max(0, root.current - 1);
            } else if (e.key === Qt.Key_Return || e.key === Qt.Key_Enter) {
                root.pick(root.current);
            } else {
                return;
            }
            e.accepted = true;
        }

        Item {
            width: parent.width
            height: 46
            Text {
                anchors.left: parent.left
                anchors.leftMargin: 12
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                elide: Text.ElideRight
                textFormat: Text.StyledText
                text: (root.msgId ? "Remind me about this message" : "Snooze")
                    + (root.chatName ? "  <font color='" + Theme.fgSurfaceVariant + "'>" + F.escapeHtml(root.chatName) + "</font>" : "")
                color: Theme.fgSurface
                font.family: Theme.font
                font.pixelSize: 16
                font.weight: Font.DemiBold
            }
        }

        Repeater {
            model: root.options
            Rectangle {
                required property var modelData
                required property int index
                width: parent.width
                height: 44
                radius: Theme.radiusSm + 2
                color: root.current === index ? Theme.secondaryContainer : om.containsMouse ? Theme.alpha(Theme.fgSurface, 0.06) : "transparent"
                Text {
                    anchors.left: parent.left
                    anchors.leftMargin: 14
                    anchors.verticalCenter: parent.verticalCenter
                    text: index + 1
                    color: Theme.primary
                    font.family: Theme.monoFont
                    font.pixelSize: 12
                }
                Text {
                    anchors.left: parent.left
                    anchors.leftMargin: 40
                    anchors.verticalCenter: parent.verticalCenter
                    text: modelData.label
                    color: root.current === index ? Theme.fgSecondaryContainer : Theme.fgSurface
                    font.family: Theme.font
                    font.pixelSize: 14
                }
                Text {
                    anchors.right: parent.right
                    anchors.rightMargin: 14
                    anchors.verticalCenter: parent.verticalCenter
                    text: F.whenLabel(modelData.ts)
                    color: Theme.fgSurfaceVariant
                    font.family: Theme.monoFont
                    font.pixelSize: 12
                }
                MouseArea {
                    id: om
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onEntered: root.current = index
                    onClicked: root.pick(index)
                }
            }
        }
    }
}
