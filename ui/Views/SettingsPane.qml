import QtQuick
import QtQuick.Controls
import QtQuick.Dialogs
import QtQuick.Layouts
import Quickshell
import qs.Services
import qs.Components
import "../Services/Format.js" as F

// Account and app settings: profile, WhatsApp privacy, blocked contacts, Hermes options.
Rectangle {
    id: pane
    color: Theme.surfaceContainerLow

    property var settings: null
    property var blocked: []
    property var hermes: ({ transcribeInstalled: false, transcribe: true })
    property bool loading: false
    property var storage: null
    readonly property string home: Quickshell.env("HOME")
    function tilde(p) { return p && p.startsWith(home) ? "~" + p.slice(home.length) : (p || ""); }

    function reload() {
        loading = true;
        Hermes.call("settings.get", {}, (res, err) => {
            loading = false;
            if (err) Hermes.toast(err, true);
            else pane.settings = res;
        });
        Hermes.call("blocklist.get", {}, res => { if (res) pane.blocked = res; });
        Hermes.refreshData();
        Hermes.refreshIntel();
        Hermes.call("storage.stats", {}, res => { if (res) pane.storage = res; });
        Hermes.call("transcribe.get", {}, res => {
            if (res) pane.hermes = { transcribeInstalled: res.installed, transcribe: res.enabled, model: res.model || "" };
        });
    }
    onVisibleChanged: if (visible) reload()

    function setPrivacy(name, value) {
        Hermes.act("settings.setPrivacy", { name: name, value: value }, "Privacy updated", (r, err) => { if (!err) reload(); });
    }

    readonly property var labels: ({
        "all": "Everyone", "contacts": "My contacts", "contact_blacklist": "My contacts except…", "none": "Nobody",
        "match_last_seen": "Same as last seen", "known": "Known contacts only"
    })
    // Rows: key, title, allowed values (same as the phone)
    readonly property var privacyRows: [
        { key: "last", title: "Last seen", values: ["all", "contacts", "contact_blacklist", "none"] },
        { key: "online", title: "Who can see when I'm online", values: ["all", "match_last_seen"] },
        { key: "profile", title: "Profile photo", values: ["all", "contacts", "contact_blacklist", "none"] },
        { key: "status", title: "About", values: ["all", "contacts", "contact_blacklist", "none"] },
        { key: "groupadd", title: "Who can add me to groups", values: ["all", "contacts", "contact_blacklist", "none"] },
        { key: "calladd", title: "Calls from", values: ["all", "known"] },
        { key: "messages", title: "Who can message me", values: ["all", "contacts"] }
    ]

    component SectionTitle: Text {
        leftPadding: 22
        topPadding: 18
        bottomPadding: 6
        color: Theme.primary
        font.family: Theme.font
        font.pixelSize: 13
        font.weight: Font.DemiBold
    }
    component Row2: Item {
        id: r2
        property string title: ""
        property string value: ""
        property string icon: ""
        signal clicked(var item)
        width: parent ? parent.width : 360
        height: 56
        Rectangle {
            anchors.fill: parent
            anchors.leftMargin: 8
            anchors.rightMargin: 8
            radius: Theme.radiusSm
            color: r2m.containsMouse ? Theme.alpha(Theme.fgSurface, 0.05) : "transparent"
        }
        Icon {
            id: r2i
            visible: r2.icon !== ""
            x: 22
            anchors.verticalCenter: parent.verticalCenter
            name: r2.icon
            size: 20
            color: Theme.fgSurfaceVariant
        }
        Column {
            anchors.left: r2.icon !== "" ? r2i.right : parent.left
            anchors.leftMargin: r2.icon !== "" ? 14 : 22
            anchors.right: parent.right
            anchors.rightMargin: 22
            anchors.verticalCenter: parent.verticalCenter
            spacing: 2
            Text { width: parent.width; elide: Text.ElideRight; text: r2.title; color: Theme.fgSurface; font.family: Theme.font; font.pixelSize: 14 }
            Text { width: parent.width; elide: Text.ElideRight; visible: r2.value !== ""; text: r2.value; color: Theme.fgSurfaceVariant; font.family: Theme.font; font.pixelSize: 12 }
        }
        MouseArea { id: r2m; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: r2.clicked(r2) }
    }

    Text {
        id: title
        x: 22
        y: 18
        text: "Settings"
        color: Theme.fgSurface
        font.family: Theme.font
        font.pixelSize: 28
        font.weight: Font.DemiBold
    }

    Flickable {
        anchors.top: title.bottom
        anchors.topMargin: 6
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        contentHeight: col.implicitHeight + 24
        clip: true
        ScrollBar.vertical: ScrollBar {}

        Column {
            id: col
            width: parent.width

            // ---- Profile ----
            Item {
                width: parent.width
                height: 92
                Avatar {
                    id: me
                    x: 22
                    anchors.verticalCenter: parent.verticalCenter
                    size: 64
                    jid: Hermes.status.meJid || ""
                    name: pane.settings ? pane.settings.name : ""
                }
                Column {
                    anchors.left: me.right
                    anchors.leftMargin: 16
                    anchors.right: parent.right
                    anchors.rightMargin: 16
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 3
                    Text { text: pane.settings ? pane.settings.name : (pane.loading ? "Loading…" : ""); color: Theme.fgSurface; font.family: Theme.font; font.pixelSize: 18; font.weight: Font.DemiBold }
                    Text { width: parent.width; elide: Text.ElideRight; text: pane.settings ? (pane.settings.about || "No about") : ""; color: Theme.fgSurfaceVariant; font.family: Theme.font; font.pixelSize: 13 }
                    Text { text: pane.settings ? pane.settings.phone : ""; color: Theme.fgSurfaceVariant; font.family: Theme.monoFont; font.pixelSize: 12 }
                }
            }
            Row2 {
                icon: "badge"
                title: "Name"
                value: pane.settings ? pane.settings.name + " · shown to people who don't have you saved" : ""
                onClicked: edit.open2("Your name", pane.settings ? pane.settings.name : "", 25, t => Hermes.act("settings.setName", { name: t }, "Name updated", (r, e) => { if (!e) pane.reload(); }))
            }
            Row2 {
                icon: "info"
                title: "About"
                value: pane.settings ? (pane.settings.about || "Add a line about yourself") : ""
                onClicked: edit.open2("About", pane.settings ? pane.settings.about : "", 139, t => Hermes.act("settings.setAbout", { text: t }, "About updated", (r, e) => { if (!e) pane.reload(); }))
            }

            // ---- Privacy ----
            SectionTitle { text: "Privacy" }
            Repeater {
                model: pane.privacyRows
                Row2 {
                    required property var modelData
                    title: modelData.title
                    value: pane.settings ? (pane.labels[pane.settings.privacy[modelData.key]] || pane.settings.privacy[modelData.key] || "") : ""
                    onClicked: item => {
                        choice.row = modelData;
                        choice.openAt(item, item.width - choice.width - 16, item.height - 6);
                    }
                }
            }
            Item {
                width: parent.width
                height: 64
                Column {
                    anchors.left: parent.left
                    anchors.leftMargin: 22
                    anchors.right: rr.left
                    anchors.rightMargin: 12
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 2
                    Text { text: "Read receipts"; color: Theme.fgSurface; font.family: Theme.font; font.pixelSize: 14 }
                    Text { width: parent.width; wrapMode: Text.WordWrap; text: "If off, you won't send or receive blue ticks (groups always show them)."; color: Theme.fgSurfaceVariant; font.family: Theme.font; font.pixelSize: 12 }
                }
                Toggle {
                    id: rr
                    anchors.right: parent.right
                    anchors.rightMargin: 20
                    anchors.verticalCenter: parent.verticalCenter
                    checked: !!pane.settings && pane.settings.privacy.readreceipts !== "none"
                    onToggled: pane.setPrivacy("readreceipts", checked ? "all" : "none")
                }
            }

            // ---- Blocked ----
            SectionTitle { text: "Blocked contacts · " + pane.blocked.length }
            Repeater {
                model: pane.blocked
                Item {
                    required property var modelData
                    width: col.width
                    height: 50
                    Avatar { id: ba; x: 22; anchors.verticalCenter: parent.verticalCenter; size: 34; name: modelData.name }
                    Text {
                        anchors.left: ba.right
                        anchors.leftMargin: 12
                        anchors.right: ub.left
                        anchors.rightMargin: 8
                        anchors.verticalCenter: parent.verticalCenter
                        elide: Text.ElideRight
                        text: modelData.name
                        color: Theme.fgSurface
                        font.family: Theme.font
                        font.pixelSize: 14
                    }
                    TextButton {
                        id: ub
                        anchors.right: parent.right
                        anchors.rightMargin: 12
                        anchors.verticalCenter: parent.verticalCenter
                        implicitHeight: 32
                        text: "Unblock"
                        onClicked: Hermes.act("blocklist.set", { chat: modelData.jid, block: false }, "Unblocked " + modelData.name, (r, e) => { if (!e) pane.reload(); })
                    }
                }
            }
            Text {
                visible: pane.blocked.length === 0
                leftPadding: 22
                text: "Nobody blocked"
                color: Theme.fgSurfaceVariant
                font.family: Theme.font
                font.pixelSize: 13
            }

            // ---- Hermes ----
            SectionTitle { text: "Hermes" }
            Item {
                width: parent.width
                height: 64
                Column {
                    anchors.left: parent.left
                    anchors.leftMargin: 22
                    anchors.right: tt.left
                    anchors.rightMargin: 12
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 2
                    Text { text: "Transcribe voice notes"; color: Theme.fgSurface; font.family: Theme.font; font.pixelSize: 14 }
                    Text {
                        width: parent.width
                        wrapMode: Text.WordWrap
                        text: pane.hermes.transcribeInstalled ? "On this computer with whisper.cpp (" + (pane.hermes.model || "").replace(/^ggml-|\.bin$/g, "") + ")" : "Not set up: run hermes-whisper-setup"
                        color: Theme.fgSurfaceVariant
                        font.family: Theme.font
                        font.pixelSize: 12
                    }
                }
                Toggle {
                    id: tt
                    enabled: pane.hermes.transcribeInstalled
                    opacity: enabled ? 1 : 0.4
                    anchors.right: parent.right
                    anchors.rightMargin: 20
                    anchors.verticalCenter: parent.verticalCenter
                    checked: pane.hermes.transcribeInstalled && pane.hermes.transcribe
                    onToggled: Hermes.act("transcribe.set", { enabled: checked }, checked ? "Voice notes will be transcribed" : "Transcription off", () => pane.reload())
                }
            }
            Item {
                width: parent.width
                height: 64
                Column {
                    anchors.left: parent.left
                    anchors.leftMargin: 22
                    anchors.right: st.left
                    anchors.rightMargin: 12
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 2
                    Text { text: "Private status viewing"; color: Theme.fgSurface; font.family: Theme.font; font.pixelSize: 14 }
                    Text { width: parent.width; wrapMode: Text.WordWrap; text: "Don't tell people you viewed their status"; color: Theme.fgSurfaceVariant; font.family: Theme.font; font.pixelSize: 12 }
                }
                Toggle {
                    id: st
                    anchors.right: parent.right
                    anchors.rightMargin: 20
                    anchors.verticalCenter: parent.verticalCenter
                    checked: !Hermes.statusFeed.receipts
                    onToggled: Hermes.call("status.setReceipts", { enabled: !checked }, () => Hermes.refreshStatus())
                }
            }
            Row2 {
                icon: "text_snippet"
                title: "Snippets"
                value: Hermes.snippets.length + " saved · type ;name in a message"
                onClicked: Hermes.manageSnippetsRequested()
            }
            Row2 {
                icon: "system_update"
                title: "WhatsApp compatibility"
                value: Hermes.updateInfo ? "Web " + Hermes.updateInfo.waVersion + (Hermes.updateInfo.libraryOutdated ? " · update available: run hermes-update" : " · up to date") : "Web " + (Hermes.status.waVersion || "")
            }

            // ---- Intelligence ----
            SectionTitle { text: "Intelligence · runs on this computer" }
            Item {
                width: parent.width
                height: 64
                Column {
                    anchors.left: parent.left
                    anchors.leftMargin: 22
                    anchors.right: ocrT.left
                    anchors.rightMargin: 12
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 2
                    Text { text: "Search text in images"; color: Theme.fgSurface; font.family: Theme.font; font.pixelSize: 14 }
                    Text {
                        width: parent.width
                        wrapMode: Text.WordWrap
                        text: Hermes.intel.ocrInstalled ? "Screenshots, receipts and notices become searchable (RapidOCR)" : "Not set up: run hermes-ocr-setup"
                        color: Theme.fgSurfaceVariant
                        font.family: Theme.font
                        font.pixelSize: 12
                    }
                }
                Toggle {
                    id: ocrT
                    enabled: Hermes.intel.ocrInstalled
                    opacity: enabled ? 1 : 0.4
                    anchors.right: parent.right
                    anchors.rightMargin: 20
                    anchors.verticalCenter: parent.verticalCenter
                    checked: Hermes.intel.ocrInstalled && Hermes.intel.ocr
                    onToggled: Hermes.act("intel.set", { ocr: checked }, "", () => Hermes.refreshIntel())
                }
            }
            Item {
                width: parent.width
                height: 64
                Column {
                    anchors.left: parent.left
                    anchors.leftMargin: 22
                    anchors.right: llmT.left
                    anchors.rightMargin: 12
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 2
                    Text { text: "Translate & summarise"; color: Theme.fgSurface; font.family: Theme.font; font.pixelSize: 14 }
                    Text {
                        width: parent.width
                        wrapMode: Text.WordWrap
                        text: Hermes.intel.llm.available ? "Local model via Ollama; only runs when you ask" : (Hermes.intel.llm.error || "Needs Ollama")
                        color: Hermes.intel.llm.available ? Theme.fgSurfaceVariant : Theme.error
                        font.family: Theme.font
                        font.pixelSize: 12
                    }
                }
                Toggle {
                    id: llmT
                    enabled: Hermes.intel.llm.available
                    opacity: enabled ? 1 : 0.4
                    anchors.right: parent.right
                    anchors.rightMargin: 20
                    anchors.verticalCenter: parent.verticalCenter
                    checked: Hermes.intel.llm.available && Hermes.intel.llm.enabled
                    onToggled: Hermes.act("intel.set", { llm: checked }, "", () => Hermes.refreshIntel())
                }
            }
            Row2 {
                visible: Hermes.aiReady
                icon: "neurology"
                title: "Model"
                value: (Hermes.intel.llm.model || "") + (Hermes.intel.llm.chosen ? "" : " (automatic)") + " · " + Hermes.intel.llm.models.length + " installed"
                onClicked: item => modelMenu.openAt(item, item.width - modelMenu.width - 16, item.height - 6)
            }
            Row2 {
                visible: Hermes.aiReady
                icon: "translate"
                title: "Translate into"
                value: Hermes.intel.translateLang
                onClicked: edit.open2("Translate messages into", Hermes.intel.translateLang, 30, t => Hermes.act("intel.set", { translateLang: t }, "Translations will be in " + t, () => Hermes.refreshIntel()))
            }
            Item {
                visible: Hermes.aiReady
                width: parent.width
                height: visible ? 64 : 0
                Column {
                    anchors.left: parent.left
                    anchors.leftMargin: 22
                    anchors.right: dgT.left
                    anchors.rightMargin: 12
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 2
                    Text { text: "One-line gist in digests"; color: Theme.fgSurface; font.family: Theme.font; font.pixelSize: 14 }
                    Text {
                        width: parent.width
                        wrapMode: Text.WordWrap
                        text: "Digest roundups say what happened, not just who wrote. " + (Object.keys(Hermes.intel.digest).length === 1 ? "1 chat" : Object.keys(Hermes.intel.digest).length + " chats") + " in digest mode (set in chat info)"
                        color: Theme.fgSurfaceVariant
                        font.family: Theme.font
                        font.pixelSize: 12
                    }
                }
                Toggle {
                    id: dgT
                    anchors.right: parent.right
                    anchors.rightMargin: 20
                    anchors.verticalCenter: parent.verticalCenter
                    checked: Hermes.intel.digestAI
                    onToggled: Hermes.act("intel.set", { digestAI: checked }, "", () => Hermes.refreshIntel())
                }
            }

            // ---- Your data ----
            SectionTitle { text: "Your data" }
            Row2 {
                icon: "description"
                title: "Export folder"
                value: pane.tilde(Hermes.dataInfo.exportDir) + " · export a chat from its info panel or Ctrl+K"
                onClicked: exportFolder.open()
            }
            Row2 {
                icon: "drive_file_move"
                title: "Auto-file media"
                value: (Hermes.dataInfo.rules || []).length === 0 ? "Copy matching attachments into folders, e.g. PDFs from College → ~/Documents/College"
                    : (Hermes.dataInfo.rules.length === 1 ? "1 rule" : Hermes.dataInfo.rules.length + " rules")
                onClicked: Hermes.autoFileRequested("", "")
            }
            Row2 {
                icon: "backup"
                title: "Encrypted backup"
                value: Hermes.dataInfo.backup.last ? "Last backup " + new Date(Hermes.dataInfo.backup.last * 1000).toLocaleString(Qt.locale(), "d MMM, HH:mm") + " · " + pane.tilde(Hermes.dataInfo.backup.dir)
                    : "Never backed up · passphrase-protected, saved to " + pane.tilde(Hermes.dataInfo.backup.dir)
                onClicked: Hermes.backupRequested()
            }
            Row2 {
                icon: "hard_drive"
                title: "Storage"
                value: pane.storage ? "Media " + (F.size(pane.storage.mediaBytes) || "0 B") + " · database " + F.size(pane.storage.dbBytes) + " · free up space" : "See what takes space and free some up"
                onClicked: Hermes.storageRequested()
            }
        }
    }

    // Privacy choice menu
    PopupMenu {
        id: choice
        width: 240
        property var row: ({ key: "", values: [] })
        Repeater {
            model: choice.row.values
            MenuItemRow {
                required property string modelData
                icon: pane.settings && pane.settings.privacy[choice.row.key] === modelData ? "radio_button_checked" : "radio_button_unchecked"
                text: pane.labels[modelData] || modelData
                onTriggered: {
                    choice.close();
                    if (modelData === "contact_blacklist")
                        Hermes.toast("Pick the excluded contacts on your phone; Hermes keeps that list as is", false);
                    pane.setPrivacy(choice.row.key, modelData);
                }
            }
        }
    }

    PopupMenu {
        id: modelMenu
        width: 260
        MenuItemRow {
            icon: !Hermes.intel.llm.chosen ? "radio_button_checked" : "radio_button_unchecked"
            text: "Automatic (smallest good one)"
            onTriggered: { modelMenu.close(); Hermes.act("intel.set", { model: "" }, "", () => Hermes.refreshIntel()); }
        }
        Repeater {
            model: Hermes.intel.llm.models
            MenuItemRow {
                required property string modelData
                icon: Hermes.intel.llm.chosen === modelData ? "radio_button_checked" : "radio_button_unchecked"
                text: modelData
                onTriggered: { modelMenu.close(); Hermes.act("intel.set", { model: modelData }, "Using " + modelData, () => Hermes.refreshIntel()); }
            }
        }
    }

    // Edit name / about
    Sheet {
        id: edit
        acceptText: "Save"
        property var save: null
        property int limit: 25
        function open2(t, value, limit, fn) {
            edit.title = t;
            edit.limit = limit;
            edit.save = fn;
            field.text = value || "";
            edit.open();
            field.input.forceActiveFocus();
        }
        acceptEnabled: field.text.trim().length > 0 && field.text.length <= limit
        onAccepted: if (save) save(field.text.trim())
        Field {
            id: field
            Layout.fillWidth: true
            icon: "edit"
            onAccepted: if (edit.acceptEnabled) { edit.accepted(); edit.close(); }
        }
        Text {
            Layout.alignment: Qt.AlignRight
            text: field.text.length + " / " + edit.limit
            color: field.text.length > edit.limit ? Theme.error : Theme.fgSurfaceVariant
            font.family: Theme.monoFont
            font.pixelSize: 11
        }
    }

    FolderDialog {
        id: exportFolder
        title: "Export chats into…"
        currentFolder: "file://" + (Hermes.dataInfo.exportDir || pane.home)
        onAccepted: {
            const dir = decodeURIComponent(selectedFolder.toString().replace("file://", ""));
            Hermes.act("data.setDirs", { exportDir: dir }, "Chats will export to " + pane.tilde(dir), () => Hermes.refreshData());
        }
    }
}
