import QtQuick
import "../theme"

// Thin scroll indicator for a vertical Flickable. It lives inside the Flickable
// and is offset by contentX/contentY, so it stays pinned to the viewport while
// the content moves. Non-interactive: it reports, it does not drag.
//
// Usage inside a Flickable:  ScrollRail { flickable: <flickable id> }
Rectangle {
    id: root

    required property Flickable flickable

    readonly property real maxY: Math.max(0, root.flickable.contentHeight - root.flickable.height)
    readonly property real track: Math.max(0, root.flickable.height - 8)

    visible: root.maxY > 2
    z: 100
    width: 5
    height: Math.max(30, Math.min(root.track,
        root.flickable.height * root.flickable.height / Math.max(1, root.flickable.contentHeight)))
    x: root.flickable.contentX + root.flickable.width - root.width - 4
    y: root.flickable.contentY + 4 + root.track * (root.flickable.contentY / Math.max(1, root.maxY))
    radius: root.width / 2
    color: Colors.alpha(Colors.surfaceText,
        root.flickable.moving || root.flickable.dragging ? 0.45 : 0.22)
    Behavior on color { ColorAnimation { duration: 120 } }
}
