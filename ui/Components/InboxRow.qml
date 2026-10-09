import QtQuick
import qs.Services
import "../Services/Format.js" as F

// One row of the triage inbox: either a section header or a chat.
Item {
    id: row
    required property int index
    required property string kind
    required property string jid
    required property string name
    required property string bucket
    required property int count
    required property string icon
    required property bool isGroup
    required property real lastTs
    required property string lastPreview
    required property string lastSender
    required property bool lastFromMe
    required property int lastStatus
    required property int unread
    required property bool markedUnread
    required property real mutedUntil
    required property string avatarPath
    required property string draft
    required property real snoozeUntil
    required property string snoozeNote
    required property string note

    property bool cursor: false // keyboard selection
    readonly property bool header: kind === "header"
    readonly property bool selected: !header && Hermes.currentChat === jid
    readonly property bool quiet: bucket === "fyi" || bucket === "waiting" || bucket === "snoozed"
    readonly property var typingInfo: header ? undefined : Hermes.typing[jid]
    readonly property color accent: bucket === "reply" ? Theme.primary : bucket === "mention" ? Theme.tertiary : Theme.outline
    signal activated
    signal menuRequested(var item, real x, real y)
    signal doneClicked
    signal snoozeClicked(var item)

    width: ListView.view ? ListView.view.width : 340
    height: header ? (index === 0 ? 40 : 52) : 64

    // ---- section header ----
    Item {
        visible: row.header
        anchors.fill: parent
        Row {
            anchors.left: parent.left
            anchors.leftMargin: 22
            anchors.bottom: parent.bottom
            anchors.bottomMargin: 8
            spacing: 8
            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: row.name.toUpperCase()
                color: row.bucket === "reply" ? Theme.primary : row.bucket === "mention" ? Theme.tertiary : Theme.fgSurfaceVariant
                font.family: Theme.font
                font.pixelSize: 12
                font.weight: Font.Bold
                font.letterSpacing: 1.2
            }
            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: row.count
                color: Theme.fgSurfaceVariant
                font.family: Theme.monoFont
                font.pixelSize: 12
            }
        }
        Icon {
            anchors.right: parent.right
            anchors.rightMargin: 20
            anchors.bottom: parent.bottom
            anchors.bottomMargin: 6
            name: Hermes.collapsed[row.bucket] ? "expand_more" : "expand_less"
            size: 18
            color: Theme.fgSurfaceVariant
            opacity: headerMouse.containsMouse || row.cursor ? 1 : 0.4
        }
        Rectangle {
            visible: row.cursor
            anchors.left: parent.left
            anchors.leftMargin: 10
            anchors.verticalCenter: parent.verticalCenter
            anchors.verticalCenterOffset: 6
            width: 4; height: 14; radius: 2
            color: Theme.primary
        }
        MouseArea {
            id: headerMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: Hermes.toggleSection(row.bucket)
        }
    }

    // ---- chat ----
    Item {
        visible: !row.header
        anchors.fill: parent
        HoverHandler { id: hover }

        Rectangle {
            anchors.fill: parent
            anchors.leftMargin: 8
            anchors.rightMargin: 8
            anchors.topMargin: 2
            anchors.bottomMargin: 2
            radius: Theme.radiusMd
            color: row.selected ? Theme.secondaryContainer : hover.hovered ? Theme.alpha(Theme.fgSurface, 0.05) : "transparent"
            border.width: row.cursor && !row.selected ? 1.5 : 0
            border.color: Theme.alpha(Theme.primary, 0.7)
            Behavior on color { ColorAnimation { duration: Theme.durFast } }
        }

        // Urgency stripe
        Rectangle {
            visible: !row.quiet
            anchors.left: parent.left
            anchors.leftMargin: 8
            anchors.verticalCenter: parent.verticalCenter
            width: 3
            height: 28
            radius: 1.5
            color: row.accent
        }

        Avatar {
            id: avatar
            anchors.left: parent.left
            anchors.leftMargin: 22
            anchors.verticalCenter: parent.verticalCenter
            size: 38
            jid: row.header ? "" : row.jid
            name: row.name
            path: row.avatarPath
            group: row.isGroup
            opacity: row.quiet && !row.selected ? 0.75 : 1
            online: !row.header && !!(Hermes.presence[row.jid] && Hermes.presence[row.jid].online)
        }

        Column {
            anchors.left: avatar.right
            anchors.leftMargin: 12
            anchors.right: trailing.left
            anchors.rightMargin: 10
            anchors.verticalCenter: parent.verticalCenter
            spacing: 2
            Row {
                width: parent.width
                spacing: 6
                Text {
                    width: Math.min(implicitWidth, parent.width - (atIcon.visible ? 22 : 0) - (row.note !== "" ? 20 : 0))
                    text: row.name
                    elide: Text.ElideRight
                    color: row.selected ? Theme.fgSecondaryContainer : Theme.fgSurface
                    font.family: Theme.font
                    font.pixelSize: 15
                    font.weight: row.quiet ? Font.Medium : Font.DemiBold
                }
                Icon {
                    visible: row.note !== ""
                    anchors.verticalCenter: parent.verticalCenter
                    name: "sticky_note_2"
                    filled: true
                    size: 14
                    color: Theme.fgSurfaceVariant
                    HoverHandler { id: noteHover }
                    Tip { shown: noteHover.hovered; text: row.note.length > 80 ? row.note.slice(0, 80) + "…" : row.note }
                }
                Icon {
                    id: atIcon
                    visible: row.bucket === "mention"
                    anchors.verticalCenter: parent.verticalCenter
                    name: "alternate_email"
                    size: 15
                    color: Theme.tertiary
                }
            }
            Text {
                width: parent.width
                elide: Text.ElideRight
                maximumLineCount: 1
                textFormat: Text.StyledText
                font.family: Theme.font
                font.pixelSize: 13
                color: row.typingInfo ? Theme.primary : Theme.fgSurfaceVariant
                text: {
                    if (row.header)
                        return "";
                    if (row.typingInfo)
                        return row.typingInfo.recording ? "recording audio…" : "typing…";
                    if (row.snoozeNote !== "")
                        return "<font color='" + Theme.tertiary + "'>⏰</font> " + F.escapeHtml(row.snoozeNote);
                    if (row.draft !== "")
                        return "<font color='" + Theme.error + "'>Draft:</font> " + F.escapeHtml(row.draft);
                    const p = F.escapeHtml(row.lastPreview);
                    if (row.lastFromMe)
                        return "You: " + p;
                    if (row.isGroup && row.lastSender)
                        return "<b>" + F.escapeHtml(row.lastSender) + "</b> " + p;
                    return p;
                }
            }
        }

        // Right side: age (or wake time), swapped for actions on hover
        Item {
            id: trailing
            anchors.right: parent.right
            anchors.rightMargin: 16
            anchors.verticalCenter: parent.verticalCenter
            width: actions.visible ? actions.width : meta.width
            height: 36

            Column {
                id: meta
                visible: !actions.visible
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                spacing: 3
                Text {
                    anchors.right: parent.right
                    text: row.bucket === "snoozed" ? "⏰ " + F.whenLabel(row.snoozeUntil) : F.age(row.lastTs)
                    color: row.bucket === "reply" && Date.now() / 1000 - row.lastTs > 86400 ? Theme.error : Theme.fgSurfaceVariant
                    font.family: Theme.monoFont
                    font.pixelSize: 11
                }
                Rectangle {
                    anchors.right: parent.right
                    visible: row.unread > 0 && row.bucket !== "snoozed"
                    height: 16
                    width: Math.max(16, uc.implicitWidth + 8)
                    radius: 8
                    color: row.quiet ? Theme.surfaceContainerHighest : Theme.primary
                    Text {
                        id: uc
                        anchors.centerIn: parent
                        text: row.unread > 99 ? "99+" : row.unread
                        color: row.quiet ? Theme.fgSurfaceVariant : Theme.fgPrimary
                        font.family: Theme.font
                        font.pixelSize: 10
                        font.weight: Font.Bold
                    }
                }
            }
            Row {
                id: actions
                visible: hover.hovered || row.cursor
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                spacing: 0
                IconButton {
                    size: 32
                    iconSize: 18
                    icon: row.bucket === "snoozed" ? "alarm_off" : "snooze"
                    tip: row.bucket === "snoozed" ? "Unsnooze" : "Snooze (s)"
                    onClicked: row.snoozeClicked(this)
                }
                IconButton {
                    size: 32
                    iconSize: 18
                    icon: "check"
                    tip: "Done (e)"
                    onClicked: row.doneClicked()
                }
            }
        }

        MouseArea {
            id: mouse
            anchors.fill: parent
            anchors.rightMargin: actions.visible ? actions.width + 16 : 0
            hoverEnabled: true
            acceptedButtons: Qt.LeftButton | Qt.RightButton
            cursorShape: Qt.PointingHandCursor
            onClicked: e => {
                if (e.button === Qt.RightButton)
                    row.menuRequested(row, e.x, e.y);
                else
                    row.activated();
            }
        }
    }
}
