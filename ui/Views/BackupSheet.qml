import QtQuick
import QtQuick.Controls
import QtQuick.Dialogs
import QtQuick.Layouts
import Quickshell
import qs.Services
import qs.Components
import "../Services/Format.js" as F

// Encrypted backup of the Hermes database (and optionally media), protected by a passphrase.
Popup {
    id: root
    parent: Overlay.overlay
    anchors.centerIn: parent
    modal: true
    focus: true
    width: Math.min(500, parent ? parent.width - 48 : 500)
    padding: 22
    closePolicy: running ? Popup.NoAutoClose : Popup.CloseOnEscape | Popup.CloseOnPressOutside

    property bool running: false
    property bool media: false
    property real mediaBytes: 0
    readonly property string home: Quickshell.env("HOME")
    readonly property var info: Hermes.dataInfo.backup
    readonly property bool valid: pass1.text.length >= 8 && pass1.text === pass2.text

    function tilde(p) { return p && p.startsWith(home) ? "~" + p.slice(home.length) : p; }

    onOpened: {
        pass1.text = "";
        pass2.text = "";
        Hermes.refreshData();
        Hermes.call("storage.stats", {}, res => { if (res) root.mediaBytes = res.mediaBytes; });
        pass1.input.forceActiveFocus();
    }

    function run() {
        if (!valid || running) return;
        running = true;
        Hermes.call("backup.create", { passphrase: pass1.text, media: media }, (res, err) => {
            running = false;
            pass1.text = "";
            pass2.text = "";
            if (err) {
                Hermes.toast("Backup failed: " + err, true);
                return;
            }
            Hermes.toast("Backup saved: " + tilde(res.path) + " (" + F.size(res.size) + ")", false);
            Hermes.refreshData();
            root.close();
        });
    }

    Overlay.modal: Rectangle { color: Theme.alpha(Theme.scrim, 0.45) }
    background: Rectangle {
        radius: Theme.radiusXl
        color: Theme.surfaceContainerHigh
    }

    contentItem: ColumnLayout {
        spacing: 12

        Text {
            text: "Back up Hermes"
            color: Theme.fgSurface
            font.family: Theme.font
            font.pixelSize: 22
        }
        Text {
            Layout.fillWidth: true
            wrapMode: Text.WordWrap
            text: "Saves your messages, notes, snippets, settings and this computer's WhatsApp link into one file encrypted with age. "
                + "Anyone with the file and passphrase could read your chats, so pick a strong one. There's no way to recover a lost passphrase."
            color: Theme.fgSurfaceVariant
            font.family: Theme.font
            font.pixelSize: 13
        }
        Field {
            id: pass1
            Layout.fillWidth: true
            icon: "key"
            placeholder: "Passphrase (8+ characters)"
            input.echoMode: TextInput.Password
            onAccepted: pass2.input.forceActiveFocus()
        }
        Field {
            id: pass2
            Layout.fillWidth: true
            icon: "key"
            placeholder: "Same passphrase again"
            input.echoMode: TextInput.Password
            onAccepted: root.run()
        }
        Text {
            visible: pass2.text !== "" && pass1.text !== pass2.text
            text: "Passphrases don't match"
            color: Theme.error
            font.family: Theme.font
            font.pixelSize: 12
        }
        RowLayout {
            Layout.fillWidth: true
            Column {
                Layout.fillWidth: true
                spacing: 2
                Text { text: "Include downloaded media"; color: Theme.fgSurface; font.family: Theme.font; font.pixelSize: 14 }
                Text { text: root.mediaBytes > 0 ? F.size(root.mediaBytes) + " of photos, voice notes and files" : "Nothing downloaded yet"; color: Theme.fgSurfaceVariant; font.family: Theme.font; font.pixelSize: 12 }
            }
            Toggle { checked: root.media; onToggled: root.media = !root.media }
        }
        RowLayout {
            Layout.fillWidth: true
            Column {
                Layout.fillWidth: true
                spacing: 2
                Text { text: "Save to"; color: Theme.fgSurface; font.family: Theme.font; font.pixelSize: 14 }
                Text {
                    width: parent.width
                    elide: Text.ElideMiddle
                    text: root.tilde(root.info.dir) + " · keeps the last 5"
                    color: Theme.fgSurfaceVariant
                    font.family: Theme.monoFont
                    font.pixelSize: 12
                }
            }
            TextButton { text: "Change…"; onClicked: folderDialog.open() }
        }
        Text {
            Layout.fillWidth: true
            wrapMode: Text.WordWrap
            text: root.info.last ? "Last backup " + (F.age(root.info.last) === "now" ? "just now" : F.age(root.info.last) + " ago") + ". Restore with: hermes backup extract <file> <folder>" : "No backups yet"
            color: Theme.fgSurfaceVariant
            font.family: Theme.font
            font.pixelSize: 12
        }
        RowLayout {
            Layout.alignment: Qt.AlignRight
            spacing: 8
            BusyIndicatorDots { visible: root.running }
            TextButton { text: "Cancel"; enabled: !root.running; onClicked: root.close() }
            TextButton {
                text: root.running ? "Backing up…" : "Back up"
                filled: true
                enabled: root.valid && !root.running
                onClicked: root.run()
            }
        }
    }

    FolderDialog {
        id: folderDialog
        title: "Save backups in…"
        currentFolder: "file://" + (root.info.dir || root.home)
        onAccepted: {
            const dir = decodeURIComponent(selectedFolder.toString().replace("file://", ""));
            Hermes.act("data.setDirs", { backupDir: dir }, "Backups will go to " + root.tilde(dir), () => Hermes.refreshData());
        }
    }
}
