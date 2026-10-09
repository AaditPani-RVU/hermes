import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import qs.Services
import qs.Components

// Slide-in chat details: quick actions, disappearing messages, and for groups the
// description, members and admin tools; block/leave at the bottom.
Rectangle {
    id: panel
    color: Theme.surfaceContainerLow
    signal closeRequested
    property var group: null
    property bool blocked: false
    readonly property var info: Hermes.currentInfo
    readonly property bool isGroup: !!info && info.isGroup
    readonly property bool admin: !!group && group.iAmAdmin
    readonly property bool canEditInfo: !!group && group.iAmMember && (admin || !group.locked)

    function reload() {
        group = null;
        blocked = false;
        if (!info || !visible)
            return;
        const jid = info.jid;
        if (info.isGroup)
            Hermes.call("chats.groupInfo", { chat: jid }, (res, err) => {
                if (!err && res && Hermes.currentChat === res.jid)
                    panel.group = res;
            });
        else
            Hermes.call("blocklist.get", {}, (res, err) => {
                if (!err && res && Hermes.currentChat === jid)
                    panel.blocked = res.some(b => b.jid === jid);
            });
    }
    // Run a group action, then refresh the member list.
    function groupAct(method, params, okText) {
        Hermes.act(method, Object.assign({ chat: panel.info.jid }, params), okText, (res, err) => {
            if (!err)
                reload();
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

    component SectionTitle: Text {
        x: 20
        color: Theme.primary
        font.family: Theme.font
        font.pixelSize: 13
        font.weight: Font.DemiBold
    }
    component SettingRow: Item {
        id: sr
        property string icon: ""
        property string label: ""
        property string value: ""
        property bool danger: false
        signal clicked(var item)
        width: parent ? parent.width : 320
        height: 50
        Rectangle {
            anchors.fill: parent
            anchors.leftMargin: 8
            anchors.rightMargin: 8
            radius: Theme.radiusSm
            color: srm.containsMouse ? Theme.alpha(sr.danger ? Theme.error : Theme.fgSurface, 0.06) : "transparent"
        }
        Icon {
            id: sri
            x: 20
            anchors.verticalCenter: parent.verticalCenter
            name: sr.icon
            size: 20
            color: sr.danger ? Theme.error : Theme.fgSurfaceVariant
        }
        Text {
            anchors.left: sri.right
            anchors.leftMargin: 14
            anchors.right: srv.left
            anchors.rightMargin: 8
            anchors.verticalCenter: parent.verticalCenter
            elide: Text.ElideRight
            text: sr.label
            color: sr.danger ? Theme.error : Theme.fgSurface
            font.family: Theme.font
            font.pixelSize: 14
        }
        Text {
            id: srv
            anchors.right: parent.right
            anchors.rightMargin: 20
            anchors.verticalCenter: parent.verticalCenter
            text: sr.value
            color: Theme.fgSurfaceVariant
            font.family: Theme.font
            font.pixelSize: 13
        }
        MouseArea {
            id: srm
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: sr.clicked(sr)
        }
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
            spacing: 12
            topPadding: 12

            Item {
                width: parent.width
                height: 36
                IconButton { anchors.left: parent.left; anchors.leftMargin: 8; icon: "close"; onClicked: panel.closeRequested() }
            }
            Avatar {
                anchors.horizontalCenter: parent.horizontalCenter
                size: 112
                jid: panel.info ? panel.info.jid : ""
                name: panel.info ? panel.info.name : ""
                path: panel.info ? panel.info.avatarPath : ""
                group: panel.isGroup
            }
            Row {
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: 4
                Text {
                    width: Math.min(implicitWidth, col.width - 80)
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.Wrap
                    text: panel.info ? panel.info.name : ""
                    color: Theme.fgSurface
                    font.family: Theme.font
                    font.pixelSize: 22
                    font.weight: Font.DemiBold
                }
                IconButton {
                    visible: panel.canEditInfo
                    anchors.verticalCenter: parent.verticalCenter
                    size: 30
                    iconSize: 16
                    icon: "edit"
                    tip: "Rename group"
                    onClicked: editSheet.edit("Group name", panel.info.name, false, t => panel.groupAct("groups.setName", { name: t }, "Renamed"))
                }
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
                    if (panel.isGroup)
                        return panel.group ? (panel.group.isCommunity ? "Community · " : "Group · ") + panel.group.participants.length + " members" + (panel.admin ? " · you're an admin" : "") : "Loading…";
                    return "+" + panel.info.jid.split("@")[0] + (panel.blocked ? " · blocked" : "");
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
                visible: panel.isGroup && !!panel.group && (panel.group.topic !== "" || panel.canEditInfo)
                width: parent.width - 32
                anchors.horizontalCenter: parent.horizontalCenter
                height: visible ? topic.implicitHeight + 24 : 0
                radius: Theme.radiusMd
                color: Theme.surfaceContainer
                Text {
                    id: topic
                    x: 12; y: 12
                    width: parent.width - (panel.canEditInfo ? 52 : 24)
                    wrapMode: Text.Wrap
                    text: panel.group ? (panel.group.topic || "Add a group description") : ""
                    color: panel.group && panel.group.topic ? Theme.fgSurface : Theme.fgSurfaceVariant
                    font.family: Theme.font
                    font.pixelSize: 14
                }
                IconButton {
                    visible: panel.canEditInfo
                    anchors.right: parent.right
                    anchors.rightMargin: 4
                    y: 4
                    size: 30
                    iconSize: 16
                    icon: "edit"
                    tip: "Edit description"
                    onClicked: editSheet.edit("Group description", panel.group.topic, true, t => panel.groupAct("groups.setTopic", { topic: t }, "Description updated"))
                }
            }

            // Chat settings
            SettingRow {
                icon: "timer"
                label: "Disappearing messages"
                value: !panel.info || !panel.info.ephemeral ? "Off" : panel.info.ephemeral >= 90 * 86400 ? "90 days" : panel.info.ephemeral >= 7 * 86400 ? "7 days" : "24 hours"
                onClicked: item => dmMenu.openAt(item, item.width - dmMenu.width - 16, item.height)
            }

            // Group admin
            Column {
                visible: panel.admin
                width: parent.width
                spacing: 0
                SectionTitle { text: "Group settings"; bottomPadding: 4 }
                SettingRow {
                    icon: "link"
                    label: "Copy invite link"
                    onClicked: Hermes.call("groups.inviteLink", { chat: panel.info.jid, reset: false }, (link, err) => {
                        if (err) { Hermes.toast(err, true); return; }
                        Quickshell.clipboardText = link;
                        Hermes.toast("Invite link copied", false);
                    })
                }
                SettingRow {
                    icon: "link_off"
                    label: "Reset invite link"
                    onClicked: confirm.ask("Reset the invite link?", "The current link stops working for everyone who has it.", "Reset",
                                           () => Hermes.call("groups.inviteLink", { chat: panel.info.jid, reset: true }, (link, err) => {
                                               if (err) { Hermes.toast(err, true); return; }
                                               Quickshell.clipboardText = link;
                                               Hermes.toast("New invite link copied", false);
                                           }))
                }
                Repeater {
                    model: panel.group ? [
                        { key: "announce", label: "Only admins can send messages", on: panel.group.announce },
                        { key: "locked", label: "Only admins can edit group info", on: panel.group.locked }
                    ] : []
                    Item {
                        required property var modelData
                        width: col.width
                        height: 50
                        Text {
                            anchors.left: parent.left
                            anchors.leftMargin: 20
                            anchors.right: sw.left
                            anchors.rightMargin: 8
                            anchors.verticalCenter: parent.verticalCenter
                            wrapMode: Text.WordWrap
                            text: modelData.label
                            color: Theme.fgSurface
                            font.family: Theme.font
                            font.pixelSize: 14
                        }
                        Toggle {
                            id: sw
                            anchors.right: parent.right
                            anchors.rightMargin: 20
                            anchors.verticalCenter: parent.verticalCenter
                            checked: modelData.on
                            onToggled: {
                                const p = {};
                                p[modelData.key] = checked;
                                panel.groupAct("groups.setFlags", p, "Group settings updated");
                            }
                        }
                    }
                }
            }

            // Members
            Item {
                visible: !!panel.group
                width: parent.width
                height: 34
                SectionTitle {
                    anchors.verticalCenter: parent.verticalCenter
                    text: "Members" + (panel.group ? " · " + panel.group.participants.length : "")
                }
                TextButton {
                    visible: panel.admin
                    anchors.right: parent.right
                    anchors.rightMargin: 12
                    anchors.verticalCenter: parent.verticalCenter
                    implicitHeight: 32
                    text: "Add"
                    icon: "person_add"
                    onClicked: addSheet.open()
                }
            }
            Repeater {
                model: panel.group ? panel.group.participants : []
                Item {
                    id: mrow
                    required property var modelData
                    width: col.width
                    height: 52
                    Rectangle {
                        anchors.fill: parent
                        anchors.leftMargin: 8
                        anchors.rightMargin: 8
                        radius: Theme.radiusSm
                        color: mma.containsMouse ? Theme.alpha(Theme.fgSurface, 0.05) : "transparent"
                    }
                    Avatar {
                        id: pa
                        x: 20
                        anchors.verticalCenter: parent.verticalCenter
                        size: 38
                        jid: ""
                        name: mrow.modelData.name
                    }
                    Text {
                        anchors.left: pa.right
                        anchors.leftMargin: 12
                        anchors.right: badge.left
                        anchors.rightMargin: 8
                        anchors.verticalCenter: parent.verticalCenter
                        elide: Text.ElideRight
                        text: mrow.modelData.isMe ? "You" : mrow.modelData.name
                        color: Theme.fgSurface
                        font.family: Theme.font
                        font.pixelSize: 14
                    }
                    Rectangle {
                        id: badge
                        visible: mrow.modelData.isAdmin
                        anchors.right: more.left
                        anchors.rightMargin: 4
                        anchors.verticalCenter: parent.verticalCenter
                        width: visible ? at.implicitWidth + 14 : 0
                        height: 22
                        radius: 6
                        color: Theme.secondaryContainer
                        Text { id: at; anchors.centerIn: parent; text: mrow.modelData.isSuper ? "Owner" : "Admin"; color: Theme.fgSecondaryContainer; font.family: Theme.font; font.pixelSize: 11 }
                    }
                    IconButton {
                        id: more
                        visible: panel.admin && !mrow.modelData.isMe
                        anchors.right: parent.right
                        anchors.rightMargin: 10
                        anchors.verticalCenter: parent.verticalCenter
                        width: visible ? 32 : 6
                        size: 32
                        iconSize: 18
                        icon: "more_vert"
                        onClicked: {
                            memberMenu.member = mrow.modelData;
                            memberMenu.openAt(more, 0, more.height);
                        }
                    }
                    MouseArea {
                        id: mma
                        anchors.fill: parent
                        anchors.rightMargin: more.visible ? 48 : 0
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        enabled: !mrow.modelData.isMe
                        onClicked: Hermes.openChat(mrow.modelData.jid)
                    }
                }
            }

            SettingRow {
                visible: !!panel.info
                icon: "notifications_paused"
                label: "Digest notifications"
                value: {
                    const m = panel.info ? (Hermes.intel.digest[panel.info.jid] || 0) : 0;
                    return m === 0 ? "Off: a notification per message" : "One roundup every " + (m >= 60 ? (m / 60) + " h" : m + " min") + " · mentions still ping";
                }
                onClicked: item => digestMenu.openAt(item, item.width - digestMenu.width - 16, item.height)
            }
            SettingRow {
                visible: !!panel.info
                icon: "description"
                label: "Export to Markdown"
                value: Hermes.dataInfo.exportDir ? Hermes.dataInfo.exportDir.replace(Quickshell.env("HOME"), "~") : ""
                onClicked: Hermes.exportChat(panel.info.jid, panel.info.name)
            }
            SettingRow {
                visible: !!panel.info
                icon: "drive_file_move"
                label: "Auto-file media"
                value: {
                    const n = panel.info ? Hermes.rulesFor(panel.info.jid).length : 0;
                    return n === 0 ? "Off" : n === 1 ? "1 rule" : n + " rules";
                }
                onClicked: Hermes.autoFileRequested(panel.info.jid, panel.info.name)
            }

            Rectangle { width: parent.width - 32; height: 1; anchors.horizontalCenter: parent.horizontalCenter; color: Theme.alpha(Theme.outlineVariant, 0.5) }

            SettingRow {
                visible: panel.isGroup && !!panel.group && panel.group.iAmMember
                icon: "logout"
                label: "Leave group"
                danger: true
                onClicked: confirm.ask("Leave " + panel.info.name + "?", "You'll stop getting its messages. An admin can add you back.", "Leave",
                                       () => panel.groupAct("groups.leave", {}, "You left the group"))
            }
            SettingRow {
                visible: !panel.isGroup && !!panel.info
                icon: panel.blocked ? "lock_open" : "block"
                label: panel.blocked ? "Unblock " + (panel.info ? panel.info.name : "") : "Block " + (panel.info ? panel.info.name : "")
                danger: !panel.blocked
                onClicked: {
                    const block = !panel.blocked;
                    const run = () => Hermes.act("blocklist.set", { chat: panel.info.jid, block: block }, block ? "Blocked" : "Unblocked", (r, err) => { if (!err) panel.reload(); });
                    if (block)
                        confirm.ask("Block " + panel.info.name + "?", "They won't be able to call you or send you messages. They aren't told.", "Block", run);
                    else
                        run();
                }
            }
        }
    }

    // ---- menus & dialogs ----

    PopupMenu {
        id: dmMenu
        width: 200
        Repeater {
            model: [{ s: 0, t: "Off" }, { s: 86400, t: "24 hours" }, { s: 7 * 86400, t: "7 days" }, { s: 90 * 86400, t: "90 days" }]
            MenuItemRow {
                required property var modelData
                icon: panel.info && (panel.info.ephemeral || 0) === modelData.s ? "radio_button_checked" : "radio_button_unchecked"
                text: modelData.t
                onTriggered: {
                    dmMenu.close();
                    Hermes.act("chats.setDisappearing", { chat: panel.info.jid, seconds: modelData.s },
                               modelData.s ? "New messages disappear after " + modelData.t : "Disappearing messages off");
                }
            }
        }
    }

    PopupMenu {
        id: digestMenu
        width: 220
        Repeater {
            model: [{ m: 0, t: "Off" }, { m: 30, t: "Every 30 minutes" }, { m: 60, t: "Every hour" }, { m: 180, t: "Every 3 hours" }]
            MenuItemRow {
                required property var modelData
                icon: panel.info && (Hermes.intel.digest[panel.info.jid] || 0) === modelData.m ? "radio_button_checked" : "radio_button_unchecked"
                text: modelData.t
                onTriggered: {
                    digestMenu.close();
                    Hermes.act("chats.setDigest", { chat: panel.info.jid, minutes: modelData.m },
                               modelData.m ? "Notifications from " + panel.info.name + " arrive as a roundup" : "Digest off", () => Hermes.refreshIntel());
                }
            }
        }
    }

    PopupMenu {
        id: memberMenu
        property var member: ({})
        MenuItemRow {
            icon: memberMenu.member.isAdmin ? "remove_moderator" : "add_moderator"
            text: memberMenu.member.isAdmin ? "Dismiss as admin" : "Make group admin"
            onTriggered: {
                memberMenu.close();
                panel.groupAct("groups.members", { members: [memberMenu.member.id], action: memberMenu.member.isAdmin ? "demote" : "promote" },
                               memberMenu.member.isAdmin ? "Dismissed as admin" : "Made admin");
            }
        }
        MenuItemRow {
            icon: "chat"
            text: "Message " + (memberMenu.member.name || "")
            onTriggered: { memberMenu.close(); Hermes.openChat(memberMenu.member.jid); }
        }
        MenuItemRow {
            icon: "person_remove"
            text: "Remove from group"
            danger: true
            onTriggered: {
                memberMenu.close();
                const m = memberMenu.member;
                confirm.ask("Remove " + m.name + "?", "They'll be removed from " + panel.info.name + ".", "Remove",
                            () => panel.groupAct("groups.members", { members: [m.id], action: "remove" }, "Removed " + m.name));
            }
        }
    }

    // Confirm dangerous actions
    Sheet {
        id: confirm
        property var run: null
        property string message: ""
        function ask(title, message, verb, fn) {
            confirm.title = title;
            confirm.message = message;
            confirm.acceptText = verb;
            confirm.run = fn;
            confirm.open();
        }
        onAccepted: if (run) run()
        Text {
            Layout.fillWidth: true
            wrapMode: Text.WordWrap
            text: confirm.message
            color: Theme.fgSurfaceVariant
            font.family: Theme.font
            font.pixelSize: 14
        }
    }

    // Edit name / description
    Sheet {
        id: editSheet
        property var save: null
        property bool multi: false
        acceptText: "Save"
        function edit(title, value, multi, fn) {
            editSheet.title = title;
            editSheet.multi = multi;
            editSheet.save = fn;
            editField.text = value || "";
            editArea.text = value || "";
            editSheet.open();
            (multi ? editArea : editField.input).forceActiveFocus();
        }
        onAccepted: if (save) save(multi ? editArea.text : editField.text)
        Field {
            id: editField
            visible: !editSheet.multi
            Layout.fillWidth: true
            icon: "edit"
            onAccepted: { editSheet.accepted(); editSheet.close(); }
        }
        Rectangle {
            visible: editSheet.multi
            Layout.fillWidth: true
            Layout.preferredHeight: 140
            radius: Theme.radiusMd
            color: Theme.surfaceContainerHighest
            ScrollView {
                anchors.fill: parent
                anchors.margins: 6
                TextArea {
                    id: editArea
                    background: null
                    wrapMode: TextArea.Wrap
                    color: Theme.fgSurface
                    font.family: Theme.font
                    font.pixelSize: 14
                    selectionColor: Theme.primary
                    selectedTextColor: Theme.fgPrimary
                }
            }
        }
    }

    // Add members: search contacts or type a number, collect, then add
    Sheet {
        id: addSheet
        title: "Add members"
        icon: "person_add"
        acceptText: picked.length ? "Add " + picked.length : "Add"
        acceptEnabled: picked.length > 0
        width: 460
        property var results: []
        property var picked: [] // [{jid, name}]
        function search() {
            Hermes.call("contacts.search", { query: addQ.text.trim() }, (res, err) => {
                addSheet.results = err ? [] : (res || []).filter(r => !r.jid.endsWith("@g.us"));
            });
        }
        function toggle(r) {
            const i = picked.findIndex(p => p.jid === r.jid);
            const next = picked.slice();
            if (i >= 0) next.splice(i, 1); else next.push(r);
            picked = next;
        }
        onOpened: { picked = []; addQ.text = ""; search(); addQ.input.forceActiveFocus(); }
        onAccepted: {
            const names = {};
            picked.forEach(p => names[p.jid] = p.name);
            Hermes.call("groups.members", { chat: panel.info.jid, members: picked.map(p => p.jid), action: "add" }, (res, err) => {
                if (err) { Hermes.toast(err, true); return; }
                const failed = Object.keys(res || {}).filter(k => res[k] !== "ok");
                Hermes.toast(failed.length ? failed.length + " not added: " + res[failed[0]] : "Added " + Object.keys(res || {}).length, failed.length > 0);
                panel.reload();
            });
        }
        Field {
            id: addQ
            Layout.fillWidth: true
            placeholder: "Name, or a number with country code"
            onTextChanged: addDebounce.restart()
            onAccepted: {
                const digits = addQ.text.replace(/[^0-9]/g, "");
                if (digits.length >= 8 && addSheet.results.length === 0) {
                    addSheet.toggle({ jid: digits + "@s.whatsapp.net", name: "+" + digits });
                    addQ.text = "";
                }
            }
        }
        Timer { id: addDebounce; interval: 200; onTriggered: addSheet.search() }
        Flow {
            Layout.fillWidth: true
            spacing: 6
            visible: addSheet.picked.length > 0
            Repeater {
                model: addSheet.picked
                Rectangle {
                    required property var modelData
                    height: 28
                    width: chipT.implicitWidth + 34
                    radius: 14
                    color: Theme.secondaryContainer
                    Text { id: chipT; x: 12; anchors.verticalCenter: parent.verticalCenter; text: modelData.name; color: Theme.fgSecondaryContainer; font.family: Theme.font; font.pixelSize: 12 }
                    Icon { anchors.right: parent.right; anchors.rightMargin: 8; anchors.verticalCenter: parent.verticalCenter; name: "close"; size: 14; color: Theme.fgSecondaryContainer }
                    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: addSheet.toggle(modelData) }
                }
            }
        }
        ListView {
            Layout.fillWidth: true
            Layout.preferredHeight: 260
            clip: true
            model: addSheet.results
            ScrollBar.vertical: ScrollBar {}
            delegate: Rectangle {
                required property var modelData
                readonly property bool on: addSheet.picked.some(p => p.jid === modelData.jid)
                readonly property bool member: !!panel.group && panel.group.participants.some(p => p.jid === modelData.jid)
                width: ListView.view.width
                height: 50
                radius: 12
                color: on ? Theme.secondaryContainer : am.containsMouse ? Theme.alpha(Theme.fgSurface, 0.06) : "transparent"
                opacity: member ? 0.5 : 1
                Row {
                    x: 8
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 12
                    Avatar { size: 34; jid: modelData.jid; name: modelData.name }
                    Column {
                        anchors.verticalCenter: parent.verticalCenter
                        Text { text: modelData.name; color: Theme.fgSurface; font.family: Theme.font; font.pixelSize: 14 }
                        Text { text: member ? "Already a member" : "+" + modelData.jid.split("@")[0]; color: Theme.fgSurfaceVariant; font.family: Theme.font; font.pixelSize: 12 }
                    }
                }
                Icon { anchors.right: parent.right; anchors.rightMargin: 12; anchors.verticalCenter: parent.verticalCenter; visible: on; name: "check_circle"; filled: true; color: Theme.primary }
                MouseArea { id: am; anchors.fill: parent; hoverEnabled: true; enabled: !member; cursorShape: Qt.PointingHandCursor; onClicked: addSheet.toggle(modelData) }
            }
        }
    }
}
