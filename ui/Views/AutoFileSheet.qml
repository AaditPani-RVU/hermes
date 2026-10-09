import QtQuick
import QtQuick.Controls
import QtQuick.Dialogs
import QtQuick.Layouts
import Quickshell
import qs.Services
import qs.Components

// Auto-filing rules: copy incoming attachments that match into a folder (Hermes keeps its own copy).
Popup {
    id: root
    parent: Overlay.overlay
    anchors.centerIn: parent
    modal: true
    focus: true
    width: Math.min(580, parent ? parent.width - 48 : 580)
    height: Math.min(680, parent ? parent.height - 48 : 680)
    padding: 22
    closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside

    // Chat the new rule applies to; "" = any chat.
    property string chat: ""
    property string chatName: ""
    property string kind: ""
    property string folder: ""

    readonly property var kinds: [
        { key: "", label: "Any" }, { key: "document", label: "Documents" }, { key: "image", label: "Photos" },
        { key: "video", label: "Videos" }, { key: "audio", label: "Audio" }
    ]
    readonly property string home: Quickshell.env("HOME")

    function openFor(jid, name) {
        chat = jid || "";
        chatName = name || "";
        kind = "";
        ext.text = "";
        match.text = "";
        chatSearch.text = "";
        folder = chatName ? home + "/Documents/" + chatName.replace(/[\/\\:*?"<>|]/g, "_") : "";
        Hermes.refreshData();
        open();
    }

    function tilde(p) { return p.startsWith(home) ? "~" + p.slice(home.length) : p; }

    function describe(r) {
        let what = r.kind ? kinds.find(k => k.key === r.kind).label : "Any media";
        if (r.ext) what += " (." + r.ext.split(",").join(", .") + ")";
        if (r.match) what += " matching “" + r.match + "”";
        return what + " from " + (r.chat ? r.chatName || r.chat.split("@")[0] : "any chat");
    }

    function save(rules, okText) {
        Hermes.act("autofile.set", { rules: rules }, okText, (res, err) => { if (!err) Hermes.refreshData(); });
    }

    function add() {
        const rules = (Hermes.dataInfo.rules || []).slice();
        rules.push({ chat: chat, chatName: chatName, kind: kind, ext: ext.text.trim(), match: match.text.trim(), dir: folder });
        save(rules, "Rule added: new matches go to " + tilde(folder));
    }

    // Chats matching the search box, for picking which chat a rule is for.
    readonly property var suggestions: {
        const q = chatSearch.text.trim().toLowerCase();
        if (!q) return [];
        const out = [];
        for (let i = 0; i < Hermes.chats.count && out.length < 5; i++) {
            const c = Hermes.chats.get(i);
            if ((c.name || "").toLowerCase().includes(q))
                out.push({ jid: c.jid, name: c.name });
        }
        return out;
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
    component Label2: Text {
        color: Theme.fgSurfaceVariant
        font.family: Theme.font
        font.pixelSize: 12
        font.weight: Font.DemiBold
    }

    contentItem: ColumnLayout {
        spacing: 12

        RowLayout {
            Layout.fillWidth: true
            Text {
                Layout.fillWidth: true
                text: "Auto-file media"
                color: Theme.fgSurface
                font.family: Theme.font
                font.pixelSize: 22
            }
            IconButton { icon: "close"; onClicked: root.close() }
        }
        Text {
            Layout.fillWidth: true
            wrapMode: Text.WordWrap
            text: "Incoming attachments that match a rule are downloaded and copied into its folder. The first matching rule wins; Hermes keeps its own copy."
            color: Theme.fgSurfaceVariant
            font.family: Theme.font
            font.pixelSize: 13
        }

        ListView {
            id: list
            Layout.fillWidth: true
            Layout.fillHeight: true
            Layout.minimumHeight: 64
            clip: true
            spacing: 2
            model: Hermes.dataInfo.rules || []
            ScrollBar.vertical: ScrollBar {}
            delegate: Rectangle {
                required property var modelData
                required property int index
                width: ListView.view.width
                height: 54
                radius: Theme.radiusSm
                color: rh.hovered ? Theme.alpha(Theme.fgSurface, 0.05) : "transparent"
                HoverHandler { id: rh }
                Icon { id: ri; x: 10; anchors.verticalCenter: parent.verticalCenter; name: "drive_file_move"; size: 20; color: Theme.primary }
                Column {
                    anchors.left: ri.right
                    anchors.leftMargin: 12
                    anchors.right: rdel.left
                    anchors.rightMargin: 8
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 2
                    Text { width: parent.width; elide: Text.ElideRight; text: root.describe(modelData); color: Theme.fgSurface; font.family: Theme.font; font.pixelSize: 14 }
                    Text { width: parent.width; elide: Text.ElideMiddle; text: "→ " + root.tilde(modelData.dir); color: Theme.fgSurfaceVariant; font.family: Theme.monoFont; font.pixelSize: 12 }
                }
                IconButton {
                    id: rdel
                    anchors.right: parent.right
                    anchors.rightMargin: 4
                    anchors.verticalCenter: parent.verticalCenter
                    size: 32
                    iconSize: 18
                    icon: "delete"
                    tip: "Remove rule"
                    onClicked: {
                        const rules = Hermes.dataInfo.rules.slice();
                        rules.splice(index, 1);
                        root.save(rules, "Rule removed");
                    }
                }
            }
            Text {
                anchors.centerIn: parent
                visible: list.count === 0
                text: "No rules yet"
                color: Theme.fgSurfaceVariant
                font.family: Theme.font
                font.pixelSize: 13
            }
        }

        Rectangle { Layout.fillWidth: true; height: 1; color: Theme.alpha(Theme.outlineVariant, 0.6) }

        Text {
            text: "New rule"
            color: Theme.fgSurface
            font.family: Theme.font
            font.pixelSize: 15
            font.weight: Font.DemiBold
        }

        Label2 { text: "FROM" }
        Flow {
            Layout.fillWidth: true
            spacing: 6
            Chip { text: "Any chat"; selected: root.chat === ""; onClicked: { root.chat = ""; root.chatName = ""; } }
            Chip { visible: root.chat !== ""; text: root.chatName; selected: true }
            Repeater {
                model: root.suggestions
                Chip {
                    required property var modelData
                    text: modelData.name
                    onClicked: {
                        root.chat = modelData.jid;
                        root.chatName = modelData.name;
                        chatSearch.text = "";
                        if (!root.folder)
                            root.folder = root.home + "/Documents/" + modelData.name.replace(/[\/\\:*?"<>|]/g, "_");
                    }
                }
            }
        }
        Field {
            id: chatSearch
            Layout.fillWidth: true
            icon: "search"
            placeholder: "Find a chat…"
        }

        Label2 { text: "WHAT" }
        Flow {
            Layout.fillWidth: true
            spacing: 6
            Repeater {
                model: root.kinds
                Chip {
                    required property var modelData
                    text: modelData.label
                    selected: root.kind === modelData.key
                    onClicked: root.kind = modelData.key
                }
            }
        }
        RowLayout {
            Layout.fillWidth: true
            spacing: 8
            Field { id: ext; Layout.fillWidth: true; icon: "description"; placeholder: "Extensions, e.g. pdf, docx" }
            Field { id: match; Layout.fillWidth: true; icon: "match_word"; placeholder: "Name contains (optional)" }
        }

        Label2 { text: "TO" }
        RowLayout {
            Layout.fillWidth: true
            spacing: 8
            Text {
                Layout.fillWidth: true
                elide: Text.ElideMiddle
                text: root.folder ? root.tilde(root.folder) : "No folder chosen"
                color: root.folder ? Theme.fgSurface : Theme.fgSurfaceVariant
                font.family: Theme.monoFont
                font.pixelSize: 13
            }
            TextButton { text: "Choose…"; icon: "folder"; onClicked: folderDialog.open() }
        }

        TextButton {
            Layout.alignment: Qt.AlignRight
            text: "Add rule"
            filled: true
            enabled: root.folder !== ""
            onClicked: root.add()
        }
    }

    FolderDialog {
        id: folderDialog
        title: "Auto-file into…"
        currentFolder: root.folder ? "file://" + root.folder : "file://" + root.home
        onAccepted: root.folder = decodeURIComponent(selectedFolder.toString().replace("file://", ""))
    }
}
