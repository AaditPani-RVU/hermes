import QtQuick
import QtQuick.Controls
import qs.Services

// Rounded M3 menu surface; put MenuItemRow children inside.
Popup {
    id: root
    default property alias items: col.data
    parent: Overlay.overlay
    padding: 6
    width: 240
    modal: false
    focus: true
    closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside

    background: Rectangle {
        radius: Theme.radiusMd
        color: Theme.surfaceContainer
        border.width: 1
        border.color: Theme.alpha(Theme.outlineVariant, 0.5)
    }
    enter: Transition {
        NumberAnimation { property: "opacity"; from: 0; to: 1; duration: Theme.durFast }
        NumberAnimation { property: "scale"; from: 0.92; to: 1; duration: Theme.durMed; easing.type: Easing.OutCubic }
    }
    exit: Transition {
        NumberAnimation { property: "opacity"; to: 0; duration: 100 }
    }
    contentItem: Column {
        id: col
        spacing: 0
    }

    // Open at a point in `item` coordinates, kept inside the window.
    function openAt(item, px, py) {
        const p = item.mapToItem(Overlay.overlay, px, py);
        const win = Overlay.overlay;
        x = Math.min(Math.max(8, p.x), win.width - width - 8);
        y = Math.min(Math.max(8, p.y), win.height - implicitHeight - 8);
        open();
    }
}
