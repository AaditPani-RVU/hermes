import QtQuick
import QtQuick.Controls
import qs.Services
import qs.Components
import "../Services/Format.js" as F

// Full-text search across every chat (or starred messages when starredMode).
Rectangle {
    id: pane
    color: Theme.surfaceContainerLow
    property bool starredMode: false
    property string scopeChat: ""
    property var results: []
    property bool busy: false
    signal openResult(string chat, string id)

    function run(q) {
        if (q !== undefined)
            field.text = q;
        const query = field.text.trim();
        if (!starredMode && query === "") {
            results = [];
            return;
        }
        busy = true;
        const method = starredMode ? "messages.starred" : "messages.search";
        Hermes.call(method, { query: query, chat: scopeChat, limit: 100 }, (res, err) => {
            busy = false;
            results = err ? [] : (res || []);
            if (err) Hermes.toast(err, true);
        });
    }
    function focusField() {
        field.input.forceActiveFocus();
        field.input.selectAll();
    }
    onStarredModeChanged: run()

    Column {
        id: head
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.topMargin: 14
        spacing: 12
        Text {
            x: 22
            height: 44
            verticalAlignment: Text.AlignVCenter
            text: pane.starredMode ? "Starred" : "Search"
            color: Theme.fgSurface
            font.family: Theme.font
            font.pixelSize: 26
            font.weight: Font.DemiBold
        }
        Field {
            id: field
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.leftMargin: 16
            anchors.rightMargin: 16
            placeholder: pane.starredMode ? "Filter starred messages" : "Search all messages"
            onTextChanged: debounce.restart()
            onAccepted: pane.run()
        }
        Rectangle {
            visible: pane.scopeChat !== ""
            x: 16
            height: 30
            width: scopeText.implicitWidth + 44
            radius: 10
            color: Theme.secondaryContainer
            Text { id: scopeText; x: 12; anchors.verticalCenter: parent.verticalCenter; text: "In: " + (Hermes.currentInfo ? Hermes.currentInfo.name : ""); color: Theme.fgSecondaryContainer; font.family: Theme.font; font.pixelSize: 13 }
            Icon { anchors.right: parent.right; anchors.rightMargin: 8; anchors.verticalCenter: parent.verticalCenter; name: "close"; size: 16; color: Theme.fgSecondaryContainer }
            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { pane.scopeChat = ""; pane.run(); } }
        }
    }
    Timer {
        id: debounce
        interval: 250
        onTriggered: pane.run()
    }

    ListView {
        anchors.top: head.bottom
        anchors.topMargin: 10
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        clip: true
        model: pane.results
        ScrollBar.vertical: ScrollBar {}
        delegate: Item {
            required property var modelData
            width: ListView.view.width
            height: col.implicitHeight + 20
            Rectangle {
                anchors.fill: parent
                anchors.leftMargin: 8
                anchors.rightMargin: 8
                radius: Theme.radiusMd
                color: Theme.fgSurface
                opacity: ma.containsMouse ? 0.06 : 0
            }
            Column {
                id: col
                x: 22
                y: 10
                width: parent.width - 44
                spacing: 3
                Item {
                    width: parent.width
                    height: chatName.implicitHeight
                    Text {
                        id: chatName
                        text: (modelData.chatName || modelData.chat.split("@")[0]) + (modelData.senderName && modelData.chatName !== modelData.senderName ? "  ·  " + modelData.senderName : "")
                        width: parent.width - 70
                        elide: Text.ElideRight
                        color: Theme.fgSurface
                        font.family: Theme.font
                        font.pixelSize: 14
                        font.weight: Font.DemiBold
                    }
                    Text {
                        anchors.right: parent.right
                        text: F.listTime(modelData.ts)
                        color: Theme.fgSurfaceVariant
                        font.family: Theme.font
                        font.pixelSize: 12
                    }
                }
                Text {
                    width: parent.width
                    wrapMode: Text.Wrap
                    maximumLineCount: 3
                    elide: Text.ElideRight
                    textFormat: Text.StyledText
                    text: F.escapeHtml(modelData.snippet || modelData.text || "").replace(/«/g, "<b><font color='" + Theme.primary + "'>").replace(/»/g, "</font></b>")
                    color: Theme.fgSurfaceVariant
                    font.family: Theme.font
                    font.pixelSize: 14
                }
            }
            MouseArea {
                id: ma
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: pane.openResult(modelData.chat, modelData.id)
            }
        }
        Text {
            anchors.centerIn: parent
            visible: pane.results.length === 0 && !pane.busy
            width: parent.width - 60
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.Wrap
            text: pane.starredMode ? "No starred messages.\nRight-click a message → Star." : field.text.trim() === "" ? "Search every message you've ever received — even text inside voice notes and images, once transcription is enabled." : "No results"
            color: Theme.fgSurfaceVariant
            font.family: Theme.font
            font.pixelSize: 14
        }
    }
}
