import QtQuick
import qs.Services

// Avatar inside a segmented ring: one arc per status, unseen ones in the accent colour.
Item {
    id: root
    property int total: 1
    property int unseen: 0
    property real size: 52
    property string jid: ""
    property string name: ""
    property string path: ""
    property bool mine: false

    width: size
    height: size

    Canvas {
        id: ring
        anchors.fill: parent
        onPaint: {
            const ctx = getContext("2d");
            ctx.reset();
            const n = Math.max(1, Math.min(root.total, 24));
            const r = width / 2 - 2;
            const gap = n > 1 ? 0.18 : 0;
            ctx.lineWidth = 2.5;
            ctx.lineCap = "round";
            for (let i = 0; i < n; i++) {
                const a0 = -Math.PI / 2 + (i / n) * 2 * Math.PI + gap / 2;
                const a1 = -Math.PI / 2 + ((i + 1) / n) * 2 * Math.PI - gap / 2;
                // The newest statuses are the unseen ones, so they sit at the end of the ring.
                ctx.strokeStyle = i >= n - root.unseen ? Theme.primary : Theme.alpha(Theme.outline, 0.6);
                ctx.beginPath();
                ctx.arc(width / 2, height / 2, r, a0, a1);
                ctx.stroke();
            }
        }
        Connections {
            target: root
            function onTotalChanged() { ring.requestPaint(); }
            function onUnseenChanged() { ring.requestPaint(); }
        }
        Connections {
            target: Theme
            function onPrimaryChanged() { ring.requestPaint(); }
        }
    }
    Avatar {
        anchors.centerIn: parent
        size: root.size - 10
        jid: root.jid
        name: root.name
        path: root.path
    }
}
