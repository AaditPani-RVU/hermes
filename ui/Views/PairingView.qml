import QtQuick
import qs.Services
import qs.Components

// First-run screen: link this computer as a WhatsApp companion device.
Rectangle {
    id: view
    color: Theme.surface
    property bool phoneMode: false
    property string pairCode: ""

    Row {
        anchors.centerIn: parent
        spacing: 64

        Column {
            width: 380
            spacing: 18
            anchors.verticalCenter: parent.verticalCenter
            Rectangle {
                width: 56; height: 56; radius: 18
                color: Theme.primary
                Icon { anchors.centerIn: parent; name: "bolt"; filled: true; size: 34; color: Theme.fgPrimary }
            }
            Text {
                text: "Link Hermes to WhatsApp"
                color: Theme.fgSurface
                font.family: Theme.font
                font.pixelSize: 30
                font.weight: Font.DemiBold
            }
            Repeater {
                model: view.phoneMode
                    ? ["Open WhatsApp on your phone", "Tap ⋮ / Settings → <b>Linked devices</b>", "Tap <b>Link a device</b> → <b>Link with phone number instead</b>", "Enter the code shown here"]
                    : ["Open WhatsApp on your phone", "Tap ⋮ / Settings → <b>Linked devices</b>", "Tap <b>Link a device</b>", "Point your phone at this screen"]
                Row {
                    required property string modelData
                    required property int index
                    spacing: 14
                    Rectangle {
                        width: 28; height: 28; radius: 14
                        color: Theme.secondaryContainer
                        Text { anchors.centerIn: parent; text: index + 1; color: Theme.fgSecondaryContainer; font.family: Theme.font; font.pixelSize: 13; font.weight: Font.Bold }
                    }
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        width: 320
                        wrapMode: Text.Wrap
                        text: modelData
                        textFormat: Text.StyledText
                        color: Theme.fgSurfaceVariant
                        font.family: Theme.font
                        font.pixelSize: 15
                    }
                }
            }
            Text {
                width: 360
                wrapMode: Text.Wrap
                text: "Hermes connects as a linked device, like WhatsApp Web. Your messages stay end-to-end encrypted and are stored only on this computer."
                color: Theme.outline
                font.family: Theme.font
                font.pixelSize: 12
            }
            TextButton {
                text: view.phoneMode ? "Use QR code instead" : "Link with phone number instead"
                icon: view.phoneMode ? "qr_code_2" : "dialpad"
                onClicked: { view.phoneMode = !view.phoneMode; view.pairCode = ""; }
            }
        }

        Rectangle {
            width: 320
            height: 320
            radius: Theme.radiusXl
            color: view.phoneMode ? Theme.surfaceContainerHigh : "#ffffff"
            anchors.verticalCenter: parent.verticalCenter

            Image {
                visible: !view.phoneMode && !!Hermes.status.qrPath
                anchors.fill: parent
                anchors.margins: 20
                source: Hermes.status.qrPath ? "file://" + Hermes.status.qrPath : ""
                smooth: false
                fillMode: Image.PreserveAspectFit
                cache: false
            }
            Column {
                visible: !view.phoneMode && !Hermes.status.qrPath
                anchors.centerIn: parent
                spacing: 12
                BusyIndicatorDots { anchors.horizontalCenter: parent.horizontalCenter }
                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: !Hermes.daemonUp ? "Starting Hermes daemon…" : Hermes.status.state === "connecting" ? "Linking…" : "Generating code…"
                    color: "#444"
                    font.family: Theme.font
                    font.pixelSize: 14
                }
            }
            Column {
                visible: view.phoneMode
                anchors.centerIn: parent
                width: parent.width - 48
                spacing: 14
                Field {
                    id: phone
                    width: parent.width
                    icon: "call"
                    placeholder: "+91 98765 43210"
                    visible: view.pairCode === ""
                    onAccepted: getCode.clicked()
                }
                TextButton {
                    id: getCode
                    visible: view.pairCode === ""
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: "Get code"
                    filled: true
                    enabled: phone.text.replace(/\D/g, "").length >= 8
                    onClicked: Hermes.call("auth.pairPhone", { phone: phone.text.replace(/\D/g, "") }, (res, err) => {
                        if (err) Hermes.toast(err, true); else view.pairCode = res;
                    })
                }
                Text {
                    visible: view.pairCode !== ""
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: view.pairCode.length === 8 ? view.pairCode.slice(0, 4) + "-" + view.pairCode.slice(4) : view.pairCode
                    color: Theme.fgSurface
                    font.family: Theme.monoFont
                    font.pixelSize: 36
                    font.letterSpacing: 4
                    font.weight: Font.Bold
                }
                Text {
                    visible: view.pairCode !== ""
                    width: parent.width
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.Wrap
                    text: "Enter this code on your phone"
                    color: Theme.fgSurfaceVariant
                    font.family: Theme.font
                    font.pixelSize: 14
                }
            }
        }
    }
}
