import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.Services
import qs.Components
import "../Services/Format.js" as F

// Disk usage per chat, and a cleanup that deletes downloaded media (messages stay).
Popup {
    id: root
    parent: Overlay.overlay
    anchors.centerIn: parent
    modal: true
    focus: true
    width: Math.min(600, parent ? parent.width - 48 : 600)
    height: Math.min(720, parent ? parent.height - 48 : 720)
    padding: 22
    closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside

    property var stats: null
    property string chat: "" // cleanup scope; "" = all chats
    property string chatName: ""
    property int olderThan: 90
    property real minBytes: 0
    property var preview: ({ files: 0, bytes: 0 })
    property bool busy: false

    readonly property var ages: [{ days: 30, label: "30 days" }, { days: 90, label: "3 months" }, { days: 365, label: "1 year" }, { days: 0, label: "Any age" }]
    readonly property var sizes: [{ bytes: 0, label: "Any size" }, { bytes: 1 << 20, label: "1 MB+" }, { bytes: 10 << 20, label: "10 MB+" }]

    function reload() {
        Hermes.call("storage.stats", {}, (res, err) => {
            if (err) Hermes.toast(err, true);
            else root.stats = res;
        });
        updatePreview();
    }
    function params(dry) {
        return { chat: chat, olderThan: olderThan, minBytes: minBytes, dryRun: dry };
    }
    function updatePreview() {
        Hermes.call("storage.clean", params(true), res => { if (res) root.preview = res; });
    }
    onChatChanged: updatePreview()
    onOlderThanChanged: updatePreview()
    onMinBytesChanged: updatePreview()
    onOpened: { chat = ""; chatName = ""; reload(); }

    function clean() {
        busy = true;
        Hermes.call("storage.clean", params(false), (res, err) => {
            busy = false;
            confirmRow.visible = false;
            if (err) Hermes.toast(err, true);
            else Hermes.toast("Freed " + (F.size(res.bytes) || "0 B") + " (" + res.files + " files)", false);
            reload();
        });
    }

    Overlay.modal: Rectangle { color: Theme.alpha(Theme.scrim, 0.45) }
    background: Rectangle {
        radius: Theme.radiusXl
        color: Theme.surfaceContainerHigh
    }

    component Chip: Rectangle {
        id: chip
        property string text: ""
        property bool selected: false
        signal clicked
        implicitHeight: 32
        implicitWidth: ct.implicitWidth + 24
        radius: Theme.radiusSm
        color: selected ? Theme.secondaryContainer : cm.containsMouse ? Theme.alpha(Theme.fgSurface, 0.06) : "transparent"
        border.width: selected ? 0 : 1
        border.color: Theme.outlineVariant
        Text {
            id: ct
            anchors.centerIn: parent
            text: chip.text
            color: chip.selected ? Theme.fgSecondaryContainer : Theme.fgSurfaceVariant
            font.family: Theme.font
            font.pixelSize: 13
        }
        MouseArea { id: cm; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: chip.clicked() }
    }
    component Stat: Column {
        property string value: ""
        property string label: ""
        spacing: 2
        Text { text: parent.value || "0 B"; color: Theme.fgSurface; font.family: Theme.font; font.pixelSize: 20; font.weight: Font.DemiBold }
        Text { text: parent.label; color: Theme.fgSurfaceVariant; font.family: Theme.font; font.pixelSize: 12 }
    }

    contentItem: ColumnLayout {
        spacing: 12

        RowLayout {
            Layout.fillWidth: true
            Text {
                Layout.fillWidth: true
                text: "Storage"
                color: Theme.fgSurface
                font.family: Theme.font
                font.pixelSize: 22
            }
            IconButton { icon: "close"; onClicked: root.close() }
        }

        Row {
            Layout.fillWidth: true
            spacing: 28
            Stat { value: root.stats ? F.size(root.stats.mediaBytes) : "…"; label: "Media · " + (root.stats ? root.stats.mediaFiles : 0) + " files" }
            Stat { value: root.stats ? F.size(root.stats.dbBytes) : "…"; label: "Database · " + (root.stats ? root.stats.messages.toLocaleString(Qt.locale(), "f", 0) : 0) + " messages" }
            Stat { value: root.stats ? F.size(root.stats.cacheBytes) : "…"; label: "Cache" }
        }

        Text {
            text: "BY CHAT · click one to clean only that chat"
            color: Theme.fgSurfaceVariant
            font.family: Theme.font
            font.pixelSize: 12
            font.weight: Font.DemiBold
        }
        ListView {
            id: list
            Layout.fillWidth: true
            Layout.fillHeight: true
            Layout.minimumHeight: 120
            clip: true
            spacing: 2
            model: root.stats ? root.stats.chats.slice(0, 60) : []
            ScrollBar.vertical: ScrollBar {}
            readonly property real maxBytes: root.stats && root.stats.chats.length ? Math.max(1, root.stats.chats[0].mediaBytes) : 1
            delegate: Rectangle {
                required property var modelData
                width: ListView.view.width
                height: 46
                radius: Theme.radiusSm
                color: root.chat === modelData.jid ? Theme.secondaryContainer : sh.hovered ? Theme.alpha(Theme.fgSurface, 0.05) : "transparent"
                HoverHandler { id: sh }
                Text {
                    id: cn
                    x: 12
                    y: 6
                    width: parent.width * 0.45
                    elide: Text.ElideRight
                    text: modelData.name
                    color: Theme.fgSurface
                    font.family: Theme.font
                    font.pixelSize: 14
                }
                Text {
                    anchors.left: cn.left
                    anchors.top: cn.bottom
                    text: modelData.messages + " messages · " + modelData.mediaFiles + " files"
                    color: Theme.fgSurfaceVariant
                    font.family: Theme.font
                    font.pixelSize: 11
                }
                Rectangle {
                    id: track
                    anchors.left: cn.right
                    anchors.leftMargin: 12
                    anchors.right: sz.left
                    anchors.rightMargin: 12
                    anchors.verticalCenter: parent.verticalCenter
                    height: 6
                    radius: 3
                    color: Theme.alpha(Theme.outlineVariant, 0.5)
                    Rectangle {
                        width: Math.max(modelData.mediaBytes > 0 ? 3 : 0, parent.width * modelData.mediaBytes / list.maxBytes)
                        height: parent.height
                        radius: 3
                        color: Theme.primary
                    }
                }
                Text {
                    id: sz
                    anchors.right: parent.right
                    anchors.rightMargin: 12
                    anchors.verticalCenter: parent.verticalCenter
                    width: 64
                    horizontalAlignment: Text.AlignRight
                    text: F.size(modelData.mediaBytes) || "—"
                    color: Theme.fgSurface
                    font.family: Theme.monoFont
                    font.pixelSize: 12
                }
                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                        if (root.chat === modelData.jid) { root.chat = ""; root.chatName = ""; }
                        else { root.chat = modelData.jid; root.chatName = modelData.name; }
                    }
                }
            }
        }

        Rectangle { Layout.fillWidth: true; height: 1; color: Theme.alpha(Theme.outlineVariant, 0.6) }

        Text {
            text: "Free up space" + (root.chat ? " in " + root.chatName : "")
            color: Theme.fgSurface
            font.family: Theme.font
            font.pixelSize: 15
            font.weight: Font.DemiBold
        }
        Flow {
            Layout.fillWidth: true
            spacing: 6
            Repeater {
                model: root.ages
                Chip {
                    required property var modelData
                    text: modelData.days ? "Older than " + modelData.label : modelData.label
                    selected: root.olderThan === modelData.days
                    onClicked: root.olderThan = modelData.days
                }
            }
        }
        Flow {
            Layout.fillWidth: true
            spacing: 6
            Repeater {
                model: root.sizes
                Chip {
                    required property var modelData
                    text: modelData.label
                    selected: root.minBytes === modelData.bytes
                    onClicked: root.minBytes = modelData.bytes
                }
            }
        }
        Text {
            Layout.fillWidth: true
            wrapMode: Text.WordWrap
            text: (root.preview.files ? "Deletes " + root.preview.files + " downloaded files (" + F.size(root.preview.bytes) + "). " : "Nothing matches. ")
                + "Messages stay and media can be downloaded again while WhatsApp still has it. Starred messages are kept."
            color: Theme.fgSurfaceVariant
            font.family: Theme.font
            font.pixelSize: 12
        }
        RowLayout {
            id: confirmRow
            visible: false
            Layout.alignment: Qt.AlignRight
            spacing: 8
            Text { text: "Delete " + F.size(root.preview.bytes) + "?"; color: Theme.error; font.family: Theme.font; font.pixelSize: 13 }
            TextButton { text: "Keep"; onClicked: confirmRow.visible = false }
            TextButton { text: root.busy ? "Deleting…" : "Delete"; filled: true; enabled: !root.busy; onClicked: root.clean() }
        }
        TextButton {
            visible: !confirmRow.visible
            Layout.alignment: Qt.AlignRight
            icon: "delete_sweep"
            text: "Free up " + (F.size(root.preview.bytes) || "space")
            tonal: true
            enabled: root.preview.files > 0
            onClicked: confirmRow.visible = true
        }
    }
}
