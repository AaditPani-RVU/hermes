import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.Services
import qs.Components

// Start a chat with a saved contact, a group, or any phone number.
Sheet {
    id: sheet
    title: "New chat"
    icon: "edit_square"
    acceptText: "Open"
    width: 460
    property var results: []
    property string selected: ""
    readonly property string digits: q.text.replace(/[^\d]/g, "")
    readonly property bool looksLikePhone: digits.length >= 8 && /^[+\d\s()-]+$/.test(q.text.trim())
    acceptEnabled: selected !== "" || looksLikePhone

    function search() {
        Hermes.call("contacts.search", { query: q.text.trim() }, (res, err) => {
            sheet.results = err ? [] : (res || []);
        });
    }
    onOpened: { q.text = ""; selected = ""; search(); q.input.forceActiveFocus(); }
    onAccepted: {
        if (selected) {
            Hermes.openChat(selected);
        } else {
            Hermes.call("contacts.resolvePhone", { phone: digits }, (jid, err) => {
                if (err) Hermes.toast(err, true); else Hermes.openChat(jid);
            });
        }
    }

    Field {
        id: q
        Layout.fillWidth: true
        placeholder: "Name or phone number with country code"
        onTextChanged: { sheet.selected = ""; debounce.restart(); }
        onAccepted: if (sheet.acceptEnabled) { sheet.accepted(); sheet.close(); }
    }
    Timer { id: debounce; interval: 200; onTriggered: sheet.search() }
    Text {
        visible: sheet.looksLikePhone
        text: "Press Open to message +" + sheet.digits
        color: Theme.primary
        font.family: Theme.font
        font.pixelSize: 13
    }
    ListView {
        Layout.fillWidth: true
        Layout.preferredHeight: 320
        clip: true
        model: sheet.results
        ScrollBar.vertical: ScrollBar {}
        delegate: Rectangle {
            required property var modelData
            width: ListView.view.width
            height: 54
            radius: 12
            color: sheet.selected === modelData.jid ? Theme.secondaryContainer : m.containsMouse ? Theme.alpha(Theme.fgSurface, 0.06) : "transparent"
            Row {
                x: 8
                anchors.verticalCenter: parent.verticalCenter
                spacing: 12
                Avatar { size: 38; jid: modelData.jid; name: modelData.name; group: modelData.jid.endsWith("@g.us") }
                Column {
                    anchors.verticalCenter: parent.verticalCenter
                    Text { text: modelData.name; color: Theme.fgSurface; font.family: Theme.font; font.pixelSize: 15 }
                    Text {
                        text: modelData.jid.endsWith("@g.us") ? "Group" : "+" + modelData.jid.split("@")[0] + (modelData.push && modelData.push !== modelData.name ? "  ·  ~" + modelData.push : "")
                        color: Theme.fgSurfaceVariant
                        font.family: Theme.font
                        font.pixelSize: 12
                    }
                }
            }
            MouseArea {
                id: m
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: sheet.selected = modelData.jid
                onDoubleClicked: { sheet.selected = modelData.jid; sheet.accepted(); sheet.close(); }
            }
        }
    }
}
