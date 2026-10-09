import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.Services
import qs.Components

// Catch-up summary of a chat, written by the local LLM and streamed in as it's generated.
Popup {
    id: root
    parent: Overlay.overlay
    anchors.centerIn: parent
    modal: true
    focus: true
    width: Math.min(620, parent ? parent.width - 48 : 620)
    height: Math.min(640, parent ? parent.height - 48 : 640)
    padding: 22
    closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside

    property string chat: ""
    property string chatName: ""
    property int unread: 0
    property string scope: "unread" // unread | recent
    property int count: 150
    property string token: ""
    property string text: ""
    property bool running: false
    property string error: ""
    property real started: 0
    property real took: 0

    function openFor(jid, name, unreadCount) {
        chat = jid;
        chatName = name;
        unread = unreadCount || 0;
        scope = unread > 0 ? "unread" : "recent";
        count = 150;
        open();
        run();
    }

    function run() {
        token = Math.random().toString(36).slice(2);
        text = "";
        error = "";
        running = true;
        started = Date.now();
        const t = token;
        Hermes.call("chats.summarize", { chat: chat, scope: scope, n: count, token: t }, (res, err) => {
            if (t !== root.token) return; // superseded
            root.running = false;
            root.took = (Date.now() - root.started) / 1000;
            if (err) root.error = err;
            else root.text = res;
        });
    }

    Connections {
        target: Hermes
        function onSummaryUpdate(token, text, done) {
            if (token === root.token && text)
                root.text = text;
        }
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
        opacity: enabled ? 1 : 0.4
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

    contentItem: ColumnLayout {
        spacing: 12

        RowLayout {
            Layout.fillWidth: true
            Icon { name: "summarize"; size: 24; color: Theme.primary }
            Text {
                Layout.fillWidth: true
                text: "Catch up on " + root.chatName
                elide: Text.ElideRight
                color: Theme.fgSurface
                font.family: Theme.font
                font.pixelSize: 22
            }
            IconButton { icon: "close"; onClicked: root.close() }
        }

        Flow {
            Layout.fillWidth: true
            spacing: 6
            Chip {
                visible: root.unread > 0
                text: "Unread · " + root.unread
                selected: root.scope === "unread"
                enabled: !root.running
                onClicked: { root.scope = "unread"; root.run(); }
            }
            Repeater {
                model: [50, 150, 400]
                Chip {
                    required property int modelData
                    text: "Last " + modelData
                    selected: root.scope === "recent" && root.count === modelData
                    enabled: !root.running
                    onClicked: { root.scope = "recent"; root.count = modelData; root.run(); }
                }
            }
        }

        Rectangle {
            Layout.fillWidth: true
            Layout.fillHeight: true
            radius: Theme.radiusMd
            color: Theme.surfaceContainer
            Flickable {
                id: flick
                anchors.fill: parent
                anchors.margins: 16
                contentHeight: out.implicitHeight
                clip: true
                ScrollBar.vertical: ScrollBar {}
                TextEdit {
                    id: out
                    width: flick.width
                    readOnly: true
                    selectByMouse: true
                    wrapMode: TextEdit.Wrap
                    textFormat: TextEdit.MarkdownText
                    text: root.error ? "" : root.text
                    color: Theme.fgSurface
                    selectionColor: Theme.primary
                    selectedTextColor: Theme.fgPrimary
                    font.family: Theme.font
                    font.pixelSize: 14
                }
            }
            Column {
                anchors.centerIn: parent
                visible: root.running && root.text === ""
                spacing: 12
                BusyIndicatorDots { anchors.horizontalCenter: parent.horizontalCenter }
                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: "Reading the chat on this computer…"
                    color: Theme.fgSurfaceVariant
                    font.family: Theme.font
                    font.pixelSize: 13
                }
            }
            Text {
                anchors.centerIn: parent
                width: parent.width - 48
                visible: root.error !== ""
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.Wrap
                text: root.error
                color: Theme.error
                font.family: Theme.font
                font.pixelSize: 14
            }
        }

        RowLayout {
            Layout.fillWidth: true
            Text {
                Layout.fillWidth: true
                elide: Text.ElideRight
                text: "Made locally with " + (Hermes.intel.llm.model || "a local model") + " · nothing left this computer"
                    + (!root.running && root.took > 0 && !root.error ? " · " + root.took.toFixed(1) + " s" : "")
                    + " · it can get things wrong"
                color: Theme.fgSurfaceVariant
                font.family: Theme.font
                font.pixelSize: 11
            }
            TextButton {
                text: "Copy"
                icon: "content_copy"
                enabled: !root.running && root.text !== ""
                onClicked: { out.selectAll(); out.copy(); out.deselect(); Hermes.toast("Summary copied", false); }
            }
        }
    }
}
