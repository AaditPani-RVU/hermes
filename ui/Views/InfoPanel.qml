import QtQuick
import QtQuick.Controls
import qs.Services
import qs.Components

// Slide-in chat details panel.
Rectangle {
    id: panel
    color: Theme.surfaceContainerLow
    signal closeRequested
    property var group: null
    readonly property var info: Hermes.currentInfo

    function reload() {
        group = null;
        if (info && info.isGroup && visible)
            Hermes.call("chats.groupInfo", { chat: info.jid }, (res, err) => {
                if (!err && res && Hermes.currentChat === res.jid)
                    panel.group = res;
            });
    }
    onVisibleChanged: if (visible) reload()
    Connections {
        target: Hermes
        function onCurrentChatChanged() { panel.reload(); }
    }

    Rectangle {
        width: 1
        height: parent.height
        color: Theme.alpha(Theme.outlineVariant, 0.4)
    }

    Flickable {
        anchors.fill: parent
        anchors.leftMargin: 1
        contentHeight: col.implicitHeight + 32
        clip: true
        ScrollBar.vertical: ScrollBar {}

        Column {
            id: col
            width: parent.width
            spacing: 14
            topPadding: 12

            Item {
                width: parent.width
                height: 36
                IconButton { anchors.left: parent.left; anchors.leftMargin: 8; icon: "close"; onClicked: panel.closeRequested() }
            }
            Avatar {
                anchors.horizontalCenter: parent.horizontalCenter
                size: 120
                jid: panel.info ? panel.info.jid : ""
                name: panel.info ? panel.info.name : ""
                path: panel.info ? panel.info.avatarPath : ""
                group: panel.info ? panel.info.isGroup : false
            }
            Text {
                width: parent.width - 32
                anchors.horizontalCenter: parent.horizontalCenter
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.Wrap
                text: panel.info ? panel.info.name : ""
                color: Theme.fgSurface
                font.family: Theme.font
                font.pixelSize: 22
                font.weight: Font.DemiBold
            }
            Text {
                width: parent.width - 32
                anchors.horizontalCenter: parent.horizontalCenter
                horizontalAlignment: Text.AlignHCenter
                color: Theme.fgSurfaceVariant
                font.family: Theme.font
                font.pixelSize: 14
                text: {
                    if (!panel.info) return "";
                    if (panel.info.isGroup)
                        return panel.group ? (panel.group.isCommunity ? "Community · " : "Group · ") + panel.group.participants.length + " members" : "Loading…";
                    return "+" + panel.info.jid.split("@")[0];
                }
            }

            // Quick actions
            Row {
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: 10
                Repeater {
                    model: panel.info ? [
                        { icon: panel.info.mutedUntil * 1000 > Date.now() ? "notifications_off" : "notifications", label: panel.info.mutedUntil * 1000 > Date.now() ? "Unmute" : "Mute",
                          run: () => Hermes.act("chats.mute", { chat: panel.info.jid, value: !(panel.info.mutedUntil * 1000 > Date.now()), hours: 8 }) },
                        { icon: "keep", label: panel.info.pinnedTs > 0 ? "Unpin" : "Pin",
                          run: () => Hermes.act("chats.pin", { chat: panel.info.jid, value: !(panel.info.pinnedTs > 0) }) },
                        { icon: panel.info.archived ? "unarchive" : "archive", label: panel.info.archived ? "Unarchive" : "Archive",
                          run: () => Hermes.act("chats.archive", { chat: panel.info.jid, value: !panel.info.archived }) },
                        { icon: "star", label: Hermes.focusState.vips.indexOf(panel.info.jid) >= 0 ? "VIP ✓" : "VIP",
                          run: () => {
                              const v = Hermes.focusState.vips.slice();
                              const i = v.indexOf(panel.info.jid);
                              if (i >= 0) v.splice(i, 1); else v.push(panel.info.jid);
                              Hermes.act("focus.set", { until: Hermes.focusState.until, vips: v });
                          } }
                    ] : []
                    Column {
                        required property var modelData
                        spacing: 4
                        IconButton {
                            anchors.horizontalCenter: parent.horizontalCenter
                            size: 48
                            icon: modelData.icon
                            container: Theme.surfaceContainerHigh
                            onClicked: modelData.run()
                        }
                        Text {
                            anchors.horizontalCenter: parent.horizontalCenter
                            text: modelData.label
                            color: Theme.fgSurfaceVariant
                            font.family: Theme.font
                            font.pixelSize: 12
                        }
                    }
                }
            }

            // Group description
            Rectangle {
                visible: !!(panel.group && panel.group.topic)
                width: parent.width - 32
                anchors.horizontalCenter: parent.horizontalCenter
                height: visible ? topic.implicitHeight + 24 : 0
                radius: Theme.radiusMd
                color: Theme.surfaceContainer
                Text {
                    id: topic
                    x: 12; y: 12
                    width: parent.width - 24
                    wrapMode: Text.Wrap
                    text: panel.group ? panel.group.topic : ""
                    color: Theme.fgSurface
                    font.family: Theme.font
                    font.pixelSize: 14
                }
            }

            // Members
            Text {
                visible: !!panel.group
                x: 20
                text: "Members"
                color: Theme.primary
                font.family: Theme.font
                font.pixelSize: 14
                font.weight: Font.DemiBold
            }
            Repeater {
                model: panel.group ? panel.group.participants : []
                Item {
                    required property var modelData
                    width: col.width
                    height: 52
                    Avatar {
                        id: pa
                        x: 20
                        anchors.verticalCenter: parent.verticalCenter
                        size: 38
                        jid: modelData.jid
                        name: modelData.name
                    }
                    Text {
                        anchors.left: pa.right
                        anchors.leftMargin: 12
                        anchors.right: badge.left
                        anchors.rightMargin: 8
                        anchors.verticalCenter: parent.verticalCenter
                        elide: Text.ElideRight
                        text: modelData.name
                        color: Theme.fgSurface
                        font.family: Theme.font
                        font.pixelSize: 14
                    }
                    Rectangle {
                        id: badge
                        visible: modelData.isAdmin
                        anchors.right: parent.right
                        anchors.rightMargin: 20
                        anchors.verticalCenter: parent.verticalCenter
                        width: visible ? at.implicitWidth + 14 : 0
                        height: 22
                        radius: 6
                        color: Theme.secondaryContainer
                        Text { id: at; anchors.centerIn: parent; text: "Admin"; color: Theme.fgSecondaryContainer; font.family: Theme.font; font.pixelSize: 11 }
                    }
                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        enabled: modelData.jid !== Hermes.status.meJid
                        onClicked: Hermes.openChat(modelData.jid)
                    }
                }
            }
        }
    }
}
