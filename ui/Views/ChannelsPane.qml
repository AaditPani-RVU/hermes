import QtQuick
import QtQuick.Controls
import qs.Services
import qs.Components
import "../Services/Format.js" as F

// Channels you follow, plus following a new one by link.
Rectangle {
    id: pane
    color: Theme.surfaceContainerLow
    onVisibleChanged: if (visible) Hermes.refreshChannels()

    function count(n) {
        return n >= 1e6 ? (n / 1e6).toFixed(1).replace(/\.0$/, "") + "M" : n >= 1e3 ? (n / 1e3).toFixed(1).replace(/\.0$/, "") + "K" : "" + n;
    }

    Column {
        id: header
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.topMargin: 18
        spacing: 10
        Text {
            x: 22
            text: "Channels"
            color: Theme.fgSurface
            font.family: Theme.font
            font.pixelSize: 28
            font.weight: Font.DemiBold
        }
        Field {
            id: link
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.leftMargin: 16
            anchors.rightMargin: 16
            icon: "add_link"
            placeholder: "Follow a channel: paste its link"
            onAccepted: {
                const l = text.trim();
                if (!l) return;
                Hermes.act("channels.follow", { link: l }, "", (ch, err) => {
                    if (err) return;
                    link.text = "";
                    Hermes.toast("Following " + ch.name, false);
                    Hermes.refreshChannels();
                });
            }
        }
    }

    ListView {
        id: list
        anchors.top: header.bottom
        anchors.topMargin: 10
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        clip: true
        model: Hermes.channels
        ScrollBar.vertical: ScrollBar {}
        delegate: Item {
            id: row
            required property var modelData
            width: ListView.view.width
            height: 70
            readonly property bool selected: Hermes.currentChat === modelData.jid
            Rectangle {
                anchors.fill: parent
                anchors.leftMargin: 8
                anchors.rightMargin: 8
                radius: Theme.radiusMd
                color: row.selected ? Theme.secondaryContainer : ma.containsMouse ? Theme.alpha(Theme.fgSurface, 0.05) : "transparent"
            }
            Avatar {
                id: av
                x: 20
                anchors.verticalCenter: parent.verticalCenter
                size: 44
                name: row.modelData.name
                path: row.modelData.avatarPath || ""
            }
            Column {
                anchors.left: av.right
                anchors.leftMargin: 12
                anchors.right: parent.right
                anchors.rightMargin: 18
                anchors.verticalCenter: parent.verticalCenter
                spacing: 2
                Row {
                    spacing: 4
                    width: parent.width
                    Text {
                        width: Math.min(implicitWidth, parent.width - 60)
                        elide: Text.ElideRight
                        text: row.modelData.name
                        color: row.selected ? Theme.fgSecondaryContainer : Theme.fgSurface
                        font.family: Theme.font
                        font.pixelSize: 15
                        font.weight: Font.DemiBold
                    }
                    Icon { visible: row.modelData.verified; name: "verified"; filled: true; size: 15; color: Theme.primary; anchors.verticalCenter: parent.verticalCenter }
                    Icon { visible: row.modelData.muted; name: "notifications_off"; size: 14; anchors.verticalCenter: parent.verticalCenter }
                }
                Text {
                    width: parent.width
                    elide: Text.ElideRight
                    text: pane.count(row.modelData.subscribers) + " followers" + (row.modelData.lastPreview ? " · " + row.modelData.lastPreview : "")
                    color: Theme.fgSurfaceVariant
                    font.family: Theme.font
                    font.pixelSize: 13
                }
            }
            MouseArea {
                id: ma
                anchors.fill: parent
                hoverEnabled: true
                acceptedButtons: Qt.LeftButton | Qt.RightButton
                cursorShape: Qt.PointingHandCursor
                onClicked: e => {
                    if (e.button === Qt.RightButton) {
                        menu.ch = row.modelData;
                        menu.openAt(row, e.x, e.y);
                    } else
                        Hermes.openChannel(row.modelData.jid);
                }
            }
        }
        Text {
            anchors.centerIn: parent
            width: parent.width - 64
            visible: Hermes.channels.length === 0
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            text: "You don't follow any channels yet. Paste a channel link above to follow one."
            color: Theme.fgSurfaceVariant
            font.family: Theme.font
            font.pixelSize: 13
        }
    }

    PopupMenu {
        id: menu
        property var ch: ({})
        MenuItemRow {
            icon: "logout"
            text: "Unfollow " + (menu.ch.name || "")
            danger: true
            onTriggered: {
                menu.close();
                const ch = menu.ch;
                Hermes.act("channels.unfollow", { chat: ch.jid }, "Unfollowed " + ch.name, (r, err) => {
                    if (err) return;
                    if (Hermes.currentChat === ch.jid) Hermes.closeChat();
                    Hermes.refreshChannels();
                });
            }
        }
    }
}
