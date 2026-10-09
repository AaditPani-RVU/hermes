import QtQuick
import QtQuick.Controls
import QtQuick.Dialogs
import QtQuick.Layouts
import qs.Services
import qs.Components
import "../Services/Format.js" as F

// Post a status: coloured text, or a photo/video with a caption. Goes to everyone your
// WhatsApp status privacy allows, for 24 hours; there's a clear "Post" step, nothing is automatic.
Popup {
    id: root
    parent: Overlay.overlay
    anchors.centerIn: parent
    modal: true
    focus: true
    width: 440
    padding: 20
    closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside

    property string mode: "text" // text | media
    property string path: ""
    property int colorIndex: 0
    readonly property var colors: ["#1F6F8B", "#5B3E96", "#B23A48", "#2E7D32", "#C77700", "#37474F", "#00838F", "#AD1457"]
    property bool posting: false

    function openText() {
        mode = "text";
        path = "";
        textInput.text = "";
        posting = false;
        open();
        textInput.forceActiveFocus();
    }
    function openMedia() {
        mode = "media";
        posting = false;
        fileDialog.open();
    }
    function post() {
        if (posting)
            return;
        posting = true;
        if (mode === "text") {
            const argb = parseInt("FF" + colors[colorIndex].slice(1), 16);
            Hermes.act("status.postText", { text: textInput.text, bg: argb }, "Posted to your status", (r, err) => { posting = false; if (!err) { root.close(); Hermes.refreshStatus(); } });
        } else {
            Hermes.act("status.postFile", { path: path, caption: caption.text }, "Posted to your status", (r, err) => { posting = false; if (!err) { root.close(); Hermes.refreshStatus(); } });
        }
    }

    Overlay.modal: Rectangle { color: Theme.alpha(Theme.scrim, 0.5) }
    background: Rectangle { radius: Theme.radiusXl; color: Theme.surfaceContainerHigh }

    contentItem: ColumnLayout {
        spacing: 14

        Text {
            text: root.mode === "text" ? "Text status" : "Photo or video status"
            color: Theme.fgSurface
            font.family: Theme.font
            font.pixelSize: 20
        }

        // Preview
        Rectangle {
            Layout.alignment: Qt.AlignHCenter
            Layout.preferredWidth: 240
            Layout.preferredHeight: 426
            radius: Theme.radiusLg
            clip: true
            color: root.mode === "text" ? root.colors[root.colorIndex] : "#000000"
            Behavior on color { ColorAnimation { duration: Theme.durMed } }

            TextArea {
                id: textInput
                visible: root.mode === "text"
                anchors.centerIn: parent
                width: parent.width - 28
                background: null
                wrapMode: TextArea.Wrap
                horizontalAlignment: TextArea.AlignHCenter
                placeholderText: "Type a status"
                placeholderTextColor: Theme.alpha("#ffffff", 0.6)
                color: "#ffffff"
                font.family: Theme.font
                font.pixelSize: text.length < 60 ? 22 : text.length < 160 ? 17 : 14
                font.weight: Font.Medium
                Keys.onPressed: e => {
                    if ((e.key === Qt.Key_Return || e.key === Qt.Key_Enter) && (e.modifiers & Qt.ControlModifier)) {
                        root.post();
                        e.accepted = true;
                    }
                }
            }
            Image {
                visible: root.mode === "media"
                anchors.fill: parent
                fillMode: Image.PreserveAspectFit
                source: root.mode === "media" && /\.(jpe?g|png|webp|gif|heic)$/i.test(root.path) ? F.fileUrl(root.path) : ""
            }
            Column {
                visible: root.mode === "media" && !/\.(jpe?g|png|webp|gif|heic)$/i.test(root.path)
                anchors.centerIn: parent
                spacing: 8
                Icon { anchors.horizontalCenter: parent.horizontalCenter; name: "movie"; size: 48; color: "#fff" }
                Text { text: root.path.split("/").pop(); color: "#fff"; font.family: Theme.font; font.pixelSize: 13; width: 200; elide: Text.ElideMiddle; horizontalAlignment: Text.AlignHCenter }
            }
        }

        // Colour swatches
        Row {
            visible: root.mode === "text"
            Layout.alignment: Qt.AlignHCenter
            spacing: 8
            Repeater {
                model: root.colors
                Rectangle {
                    required property string modelData
                    required property int index
                    width: 26; height: 26; radius: 13
                    color: modelData
                    border.width: root.colorIndex === index ? 3 : 0
                    border.color: Theme.fgSurface
                    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.colorIndex = index }
                }
            }
        }

        Field {
            id: caption
            visible: root.mode === "media"
            Layout.fillWidth: true
            icon: "short_text"
            placeholder: "Add a caption (optional)"
            onAccepted: root.post()
        }

        Text {
            Layout.fillWidth: true
            wrapMode: Text.WordWrap
            text: "Visible for 24 hours to the contacts your WhatsApp status privacy allows."
            color: Theme.fgSurfaceVariant
            font.family: Theme.font
            font.pixelSize: 12
        }

        RowLayout {
            Layout.alignment: Qt.AlignRight
            spacing: 8
            TextButton { text: "Cancel"; onClicked: root.close() }
            TextButton {
                text: root.posting ? "Posting…" : "Post"
                icon: "send"
                filled: true
                enabled: !root.posting && (root.mode === "text" ? textInput.text.trim() !== "" : root.path !== "")
                onClicked: root.post()
            }
        }
    }

    FileDialog {
        id: fileDialog
        title: "Choose a photo or video for your status"
        nameFilters: ["Images & videos (*.jpg *.jpeg *.png *.webp *.gif *.heic *.mp4 *.mov *.mkv *.webm)"]
        onAccepted: {
            root.path = decodeURIComponent(selectedFile.toString().replace("file://", ""));
            caption.text = "";
            root.open();
        }
    }
}
