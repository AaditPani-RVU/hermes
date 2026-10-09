import QtQuick
import qs.Services

// Material Symbols Rounded glyph by ligature name.
Text {
    property string name: ""
    property real size: 22
    property bool filled: false
    property real weight: 400

    text: name
    color: Theme.fgSurfaceVariant
    font.family: Theme.iconFont
    font.pixelSize: size
    font.variableAxes: ({ "FILL": filled ? 1 : 0, "wght": weight, "opsz": Math.max(20, Math.min(48, size)) })
    horizontalAlignment: Text.AlignHCenter
    verticalAlignment: Text.AlignVCenter
    renderType: Text.NativeRendering
}
