import QtQuick
import QtQuick.Layouts
import qs.Common
import qs.Components
import qs.Widgets.common

// Bar pill: WhatsApp icon + how many chats need you (the inbox's Needs reply + Mentions).
// Left click: recent chats with quick reply. Middle click: focus mode.
// Right click: open the Hermes window.
Item {
    id: root

    property var screen: null
    property string edge: "top"
    property bool vertical: false

    readonly property int unread: HermesBarService.needsYou
    readonly property bool hasUnread: root.unread > 0 && !HermesBarService.focusActive
    readonly property string iconName: !HermesBarService.daemonUp ? "chat_error" : HermesBarService.focusActive
                                                                    ? "speaker_notes_off" : "chat"

    implicitWidth: vertical ? Sizes.barVisualThickness : content.implicitWidth + 20
    implicitHeight: vertical ? content.implicitHeight + 16 : Sizes.barPillThickness

    TopBarPillBackground {
        anchors.fill: parent
    }

    Rectangle {
        // Highlight while there is something unread.
        anchors.fill: parent
        anchors.margins: 3
        radius: height / 2
        color: Appearance.colors.colPrimaryContainer
        opacity: root.hasUnread ? 1 : 0

        Behavior on opacity {
            NumberAnimation {
                duration: Appearance.animation.expressiveFastEffects.duration
            }
        }
    }

    GridLayout {
        id: content

        anchors.centerIn: parent
        columns: root.vertical ? 1 : 2
        rowSpacing: 2
        columnSpacing: 6

        MaterialSymbol {
            Layout.alignment: Qt.AlignCenter
            text: root.iconName
            iconSize: 18
            fill: root.hasUnread || popup.visible ? 1 : 0
            color: root.hasUnread ? Appearance.colors.colOnPrimaryContainer : Appearance.colors.colOnLayer0
            opacity: HermesBarService.daemonUp ? 1 : 0.5
        }

        Text {
            Layout.alignment: Qt.AlignCenter
            visible: root.unread > 0
            text: root.unread > 99 ? "99+" : root.unread
            font.family: Fonts.numeric
            font.pixelSize: 12
            font.weight: Font.DemiBold
            color: root.hasUnread ? Appearance.colors.colOnPrimaryContainer : Appearance.colors.colSubtext
        }
    }

    MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.LeftButton | Qt.MiddleButton | Qt.RightButton
        cursorShape: Qt.PointingHandCursor
        onClicked: event => {
            if (event.button === Qt.MiddleButton)
                HermesBarService.toggleFocus();
            else if (event.button === Qt.RightButton)
                HermesBarService.openChat("");
            else if (popup.visible)
                popup.close();
            else
                popup.open();
        }
    }

    HermesPopup {
        id: popup

        anchorItem: root
        screen: root.screen
        edge: root.edge
    }
}
