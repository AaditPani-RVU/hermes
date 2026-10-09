import QtQuick
import qs.Services

// Delivery status: clock, ✓, ✓✓, blue ✓✓, failed.
Icon {
    property int status: 1
    property color base: Theme.fgSurfaceVariant
    size: 16
    name: status < 0 ? "error" : status === 0 ? "schedule" : status === 1 ? "check" : "done_all"
    color: status < 0 ? Theme.error : status >= 3 ? "#53bdeb" : base
}
