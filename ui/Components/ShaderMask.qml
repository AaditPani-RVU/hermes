import QtQuick
import QtQuick.Effects

// Rounded-corner (and optionally blurred) rendering of an image item.
MultiEffect {
    property Item mask
    property bool blurred: false
    maskEnabled: true
    maskSource: mask
    maskThresholdMin: 0.5
    maskSpreadAtMin: 1.0
    blurEnabled: blurred
    blurMax: 32
    blur: blurred ? 0.6 : 0
}
