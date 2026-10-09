import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.Services
import qs.Components

// Manage snippets: text you insert by typing ;name in the composer.
Popup {
    id: root
    parent: Overlay.overlay
    anchors.centerIn: parent
    modal: true
    focus: true
    width: Math.min(560, parent ? parent.width - 48 : 560)
    height: Math.min(620, parent ? parent.height - 48 : 620)
    padding: 22
    closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside

    property string editing: "" // trigger being edited, "" for a new one

    function edit(sn) {
        editing = sn ? sn.trigger : "";
        nameField.text = sn ? sn.trigger : "";
        body.text = sn ? sn.text : "";
        (sn ? body : nameField.input).forceActiveFocus();
    }
    function save() {
        const name = nameField.text.trim().replace(/^;+/, "");
        if (!name || !body.text.trim())
            return;
        Hermes.act("snippets.set", { trigger: name, text: body.text }, "Saved ;" + name.toLowerCase(), (res, err) => {
            if (err)
                return;
            if (editing && editing !== name.toLowerCase())
                Hermes.call("snippets.set", { trigger: editing, text: "" }); // renamed
            edit(null);
        });
    }

    onOpened: edit(null)

    Overlay.modal: Rectangle { color: Theme.alpha(Theme.scrim, 0.45) }
    background: Rectangle {
        radius: Theme.radiusXl
        color: Theme.surfaceContainerHigh
    }

    contentItem: ColumnLayout {
        spacing: 14

        RowLayout {
            Layout.fillWidth: true
            Text {
                Layout.fillWidth: true
                text: "Snippets"
                color: Theme.fgSurface
                font.family: Theme.font
                font.pixelSize: 22
            }
            IconButton { icon: "close"; onClicked: root.close() }
        }
        Text {
            Layout.fillWidth: true
            wrapMode: Text.WordWrap
            textFormat: Text.StyledText
            text: "Type <font face='" + Theme.monoFont + "' color='" + Theme.primary + "'>;name</font> in a message to insert one. "
                + "Placeholders: <font face='" + Theme.monoFont + "'>{first}</font> (their first name), "
                + "<font face='" + Theme.monoFont + "'>{date}</font>, <font face='" + Theme.monoFont + "'>{time}</font>. Nothing is sent until you press Enter."
            color: Theme.fgSurfaceVariant
            font.family: Theme.font
            font.pixelSize: 13
        }

        // Existing snippets
        ListView {
            Layout.fillWidth: true
            Layout.fillHeight: true
            Layout.minimumHeight: 80
            clip: true
            spacing: 2
            model: Hermes.snippets
            ScrollBar.vertical: ScrollBar {}
            delegate: Rectangle {
                required property var modelData
                width: ListView.view.width
                height: 52
                radius: Theme.radiusSm
                color: root.editing === modelData.trigger ? Theme.secondaryContainer : rowHover.hovered ? Theme.alpha(Theme.fgSurface, 0.05) : "transparent"
                HoverHandler { id: rowHover }
                Text {
                    id: t
                    x: 12
                    width: 110
                    anchors.verticalCenter: parent.verticalCenter
                    text: ";" + modelData.trigger
                    elide: Text.ElideRight
                    color: Theme.primary
                    font.family: Theme.monoFont
                    font.pixelSize: 13
                }
                Text {
                    anchors.left: t.right
                    anchors.leftMargin: 8
                    anchors.right: del.left
                    anchors.rightMargin: 8
                    anchors.verticalCenter: parent.verticalCenter
                    text: modelData.text.replace(/\n/g, " ⏎ ")
                    elide: Text.ElideRight
                    color: Theme.fgSurface
                    font.family: Theme.font
                    font.pixelSize: 13
                }
                IconButton {
                    id: del
                    anchors.right: parent.right
                    anchors.rightMargin: 4
                    anchors.verticalCenter: parent.verticalCenter
                    size: 32
                    iconSize: 18
                    icon: "delete"
                    tip: "Delete"
                    onClicked: Hermes.act("snippets.set", { trigger: modelData.trigger, text: "" }, "Deleted ;" + modelData.trigger)
                }
                MouseArea {
                    anchors.fill: parent
                    anchors.rightMargin: 44
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.edit(modelData)
                }
            }
            Text {
                anchors.centerIn: parent
                visible: Hermes.snippets.length === 0
                text: "No snippets yet. Try ;addr for your address."
                color: Theme.fgSurfaceVariant
                font.family: Theme.font
                font.pixelSize: 13
            }
        }

        Rectangle { Layout.fillWidth: true; height: 1; color: Theme.alpha(Theme.outlineVariant, 0.6) }

        // Add / edit
        Text {
            text: root.editing ? "Edit ;" + root.editing : "New snippet"
            color: Theme.fgSurface
            font.family: Theme.font
            font.pixelSize: 15
            font.weight: Font.DemiBold
        }
        Field {
            id: nameField
            Layout.fillWidth: true
            icon: "tag"
            placeholder: "Name, one word (e.g. addr)"
            onAccepted: body.forceActiveFocus()
        }
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: Math.max(72, Math.min(160, body.contentHeight + 24))
            radius: Theme.radiusMd
            color: Theme.surfaceContainerHighest
            border.width: body.activeFocus ? 1 : 0
            border.color: Theme.primary
            ScrollView {
                anchors.fill: parent
                anchors.margins: 4
                TextArea {
                    id: body
                    background: null
                    wrapMode: TextArea.Wrap
                    placeholderText: "Text to insert. Hi {first}! …"
                    placeholderTextColor: Theme.fgSurfaceVariant
                    color: Theme.fgSurface
                    selectionColor: Theme.primary
                    selectedTextColor: Theme.fgPrimary
                    font.family: Theme.font
                    font.pixelSize: 14
                    Keys.onPressed: e => {
                        if ((e.key === Qt.Key_Return || e.key === Qt.Key_Enter) && (e.modifiers & Qt.ControlModifier)) {
                            root.save();
                            e.accepted = true;
                        }
                    }
                }
            }
        }
        RowLayout {
            Layout.alignment: Qt.AlignRight
            spacing: 8
            TextButton {
                visible: root.editing !== ""
                text: "Cancel edit"
                onClicked: root.edit(null)
            }
            TextButton {
                text: root.editing ? "Save (Ctrl+Enter)" : "Add (Ctrl+Enter)"
                filled: true
                enabled: nameField.text.trim() !== "" && body.text.trim() !== ""
                onClicked: root.save()
            }
        }
    }
}
