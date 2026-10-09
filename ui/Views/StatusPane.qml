import QtQuick
import QtQuick.Controls
import qs.Services
import qs.Components
import "../Services/Format.js" as F

// Status (stories) from the last 24 hours, grouped by person.
Rectangle {
    id: pane
    color: Theme.surfaceContainerLow
    signal viewRequested(int authorIndex, bool mine)
    signal postText
    signal postMedia

    readonly property var feed: Hermes.statusFeed

    Column {
        id: header
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.topMargin: 18
        anchors.leftMargin: 22
        anchors.rightMargin: 12
        spacing: 2
        Item {
            width: parent.width
            height: 36
            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: "Status"
                color: Theme.fgSurface
                font.family: Theme.font
                font.pixelSize: 28
                font.weight: Font.DemiBold
            }
            Row {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                IconButton { icon: "edit"; tip: "Text status"; onClicked: pane.postText() }
                IconButton { icon: "photo_camera"; tip: "Photo or video status"; onClicked: pane.postMedia() }
            }
        }
        Text {
            text: pane.feed.authors.length === 0 ? "Nothing in the last 24 hours"
                : Hermes.statusUnseen > 0 ? Hermes.statusUnseen + " new · " + pane.feed.authors.length + " people"
                : pane.feed.authors.length + " people · all seen"
            color: Theme.fgSurfaceVariant
            font.family: Theme.font
            font.pixelSize: 13
        }
    }

    ListView {
        id: list
        anchors.top: header.bottom
        anchors.topMargin: 10
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: footer.top
        clip: true
        model: pane.feed.authors
        ScrollBar.vertical: ScrollBar {}

        header: Column {
            width: list.width
            // My status
            Item {
                width: parent.width
                height: 72
                StatusRing {
                    id: myRing
                    x: 20
                    anchors.verticalCenter: parent.verticalCenter
                    size: 50
                    total: pane.feed.mine ? pane.feed.mine.items.length : 1
                    unseen: 0
                    jid: Hermes.status.meJid || ""
                    name: Hermes.status.meName || "Me"
                    opacity: pane.feed.mine ? 1 : 0.7
                }
                Rectangle {
                    visible: !pane.feed.mine
                    x: myRing.x + 34; y: myRing.y + 34
                    width: 20; height: 20; radius: 10
                    color: Theme.primary
                    border.width: 2
                    border.color: Theme.surfaceContainerLow
                    Icon { anchors.centerIn: parent; name: "add"; size: 14; color: Theme.fgPrimary }
                }
                Column {
                    anchors.left: myRing.right
                    anchors.leftMargin: 14
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 2
                    Text { text: "My status"; color: Theme.fgSurface; font.family: Theme.font; font.pixelSize: 15; font.weight: Font.DemiBold }
                    Text {
                        text: pane.feed.mine ? pane.feed.mine.items.length + " update" + (pane.feed.mine.items.length > 1 ? "s" : "") + " · " + F.age(pane.feed.mine.lastTs) + " ago"
                            : "Share a text, photo or video for 24 hours"
                        color: Theme.fgSurfaceVariant; font.family: Theme.font; font.pixelSize: 13
                    }
                }
                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: pane.feed.mine ? pane.viewRequested(-1, true) : pane.postText()
                }
            }
            Text {
                visible: pane.feed.authors.length > 0
                leftPadding: 22
                topPadding: 8
                bottomPadding: 6
                text: "RECENT"
                color: Theme.fgSurfaceVariant
                font.family: Theme.font
                font.pixelSize: 12
                font.weight: Font.Bold
                font.letterSpacing: 1.2
            }
        }

        delegate: Item {
            id: row
            required property var modelData
            required property int index
            width: ListView.view.width
            height: 68
            Rectangle {
                anchors.fill: parent
                anchors.leftMargin: 8
                anchors.rightMargin: 8
                radius: Theme.radiusMd
                color: ma.containsMouse ? Theme.alpha(Theme.fgSurface, 0.05) : "transparent"
            }
            StatusRing {
                id: ring
                x: 20
                anchors.verticalCenter: parent.verticalCenter
                size: 50
                total: row.modelData.items.length
                unseen: row.modelData.unseen
                jid: row.modelData.sender
                name: row.modelData.name
                path: row.modelData.avatarPath || ""
            }
            Column {
                anchors.left: ring.right
                anchors.leftMargin: 14
                anchors.right: parent.right
                anchors.rightMargin: 16
                anchors.verticalCenter: parent.verticalCenter
                spacing: 2
                Text {
                    width: parent.width
                    elide: Text.ElideRight
                    text: row.modelData.name
                    color: Theme.fgSurface
                    font.family: Theme.font
                    font.pixelSize: 15
                    font.weight: row.modelData.unseen > 0 ? Font.DemiBold : Font.Medium
                }
                Text {
                    text: F.age(row.modelData.lastTs) + " ago" + (row.modelData.items.length > 1 ? " · " + row.modelData.items.length + " updates" : "")
                    color: Theme.fgSurfaceVariant
                    font.family: Theme.font
                    font.pixelSize: 13
                }
            }
            MouseArea {
                id: ma
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: pane.viewRequested(row.index, false)
            }
        }
    }

    // Privacy toggle
    Rectangle {
        id: footer
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        height: 52
        color: Theme.surfaceContainer
        Text {
            anchors.left: parent.left
            anchors.leftMargin: 22
            anchors.right: sw.left
            anchors.verticalCenter: parent.verticalCenter
            wrapMode: Text.WordWrap
            text: pane.feed.receipts ? "People see that you viewed their status" : "Private viewing: nobody sees that you looked"
            color: Theme.fgSurfaceVariant
            font.family: Theme.font
            font.pixelSize: 12
        }
        Switch {
            id: sw
            anchors.right: parent.right
            anchors.rightMargin: 12
            anchors.verticalCenter: parent.verticalCenter
            checked: pane.feed.receipts
            onToggled: Hermes.call("status.setReceipts", { enabled: checked }, () => Hermes.refreshStatus())
        }
    }
}
