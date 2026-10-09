import QtQuick
import qs.Services
import qs.Components

// Narrow left rail: sections, focus mode, connection state.
Rectangle {
    id: rail
    color: Theme.surfaceContainer
    width: 72
    property string section: "inbox"

    Column {
        anchors.top: parent.top
        anchors.topMargin: 16
        anchors.horizontalCenter: parent.horizontalCenter
        spacing: 6

        // Logo mark
        Rectangle {
            width: 44; height: 44; radius: 14
            anchors.horizontalCenter: parent.horizontalCenter
            color: Theme.primary
            Icon { anchors.centerIn: parent; name: "bolt"; filled: true; size: 26; color: Theme.fgPrimary }
        }
        Item { width: 1; height: 14 }

        Repeater {
            model: [
                { key: "inbox", icon: "inbox", label: "Inbox", badge: Hermes.needsYou },
                { key: "chats", icon: "forum", label: "All", badge: 0 },
                { key: "status", icon: "motion_photos_on", label: "Status", badge: Hermes.statusUnseen },
                { key: "channels", icon: "campaign", label: "Channels", badge: 0 },
                { key: "search", icon: "manage_search", label: "Search", badge: 0 },
                { key: "scheduled", icon: "schedule_send", label: "Later", badge: Hermes.scheduled.length },
                { key: "starred", icon: "star", label: "Starred", badge: 0 }
            ]
            Item {
                required property var modelData
                width: 64
                height: 60
                readonly property bool on: rail.section === modelData.key
                Rectangle {
                    id: pill
                    anchors.horizontalCenter: parent.horizontalCenter
                    y: 4
                    width: on ? 56 : 32
                    height: 32
                    radius: 16
                    color: on ? Theme.secondaryContainer : "transparent"
                    Behavior on width { NumberAnimation { duration: Theme.durMed; easing.type: Easing.OutCubic } }
                    Icon {
                        anchors.centerIn: parent
                        name: modelData.icon
                        filled: on
                        color: on ? Theme.fgSecondaryContainer : Theme.fgSurfaceVariant
                    }
                    Rectangle {
                        visible: modelData.badge > 0
                        anchors.right: parent.right
                        anchors.top: parent.top
                        anchors.rightMargin: on ? 4 : -6
                        anchors.topMargin: -4
                        height: 18
                        width: Math.max(18, bt.implicitWidth + 10)
                        radius: 9
                        color: Theme.error
                        Text { id: bt; anchors.centerIn: parent; text: modelData.badge > 99 ? "99+" : modelData.badge; color: Theme.fgError; font.family: Theme.font; font.pixelSize: 10; font.weight: Font.Bold }
                    }
                }
                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    anchors.top: pill.bottom
                    anchors.topMargin: 4
                    text: modelData.label
                    color: on ? Theme.fgSurface : Theme.fgSurfaceVariant
                    font.family: Theme.font
                    font.pixelSize: 12
                    font.weight: on ? Font.DemiBold : Font.Medium
                }
                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: rail.section = modelData.key
                }
            }
        }
    }

    Column {
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 16
        anchors.horizontalCenter: parent.horizontalCenter
        spacing: 10

        IconButton {
            anchors.horizontalCenter: parent.horizontalCenter
            icon: "settings"
            filled: rail.section === "settings"
            toggled: rail.section === "settings"
            tip: "Settings"
            onClicked: rail.section = "settings"
        }
        IconButton {
            anchors.horizontalCenter: parent.horizontalCenter
            icon: Hermes.focusState.active ? "do_not_disturb_on" : "do_not_disturb_off"
            toggled: Hermes.focusState.active
            tip: Hermes.focusState.active ? "Focus mode on — only VIPs notify" : "Focus mode"
            onClicked: Hermes.act("focus.set", { until: Hermes.focusState.active ? 0 : -1 }, Hermes.focusState.active ? "Focus mode off" : "Focus mode on — only VIP chats will notify you")
        }
        // Connection dot
        Rectangle {
            anchors.horizontalCenter: parent.horizontalCenter
            width: 10; height: 10; radius: 5
            color: !Hermes.daemonUp ? Theme.error : Hermes.status.state === "connected" ? "#3ddc84" : "#f4b400"
            HoverHandler { id: dotHover }
            Tip {
                above: true
                shown: dotHover.hovered
                text: !Hermes.daemonUp ? "Daemon not running" : "WhatsApp: " + Hermes.status.state + (Hermes.status.syncing ? " (syncing)" : "") + " · v" + Hermes.status.waVersion
            }
        }
    }
}
