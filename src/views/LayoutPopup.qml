pragma ComponentBehavior: Bound
import QtQuick
import "../theme"
import "../components"

// Dashboard layout editor — the sidebar LAYOUT button, or Settings ▸ INTERFACE
// ▸ LAYOUT ▸ OPEN. The body mirrors the dashboard's own two-column masonry: a
// proportional tile per card, its height the card's live pHeight scaled to fit
// the preview, so the map matches the real tab. Drag a tile onto another to
// reorder, toggle collapse and hide/show per tile, and cards that are hidden
// sit in a tray below so they can be brought back. Every edit calls straight
// back into the dashboard, which persists it to dashboard.json, so the tab
// behind the scrim updates as you work.
//
// Drag coordinates are preview-local: the tiles live in `preview`, so
// mapToItem covers the whole mapping — this is what the old on-dashboard
// gesture got wrong by reading a `globalPosition` that no Item has.
Item {
    id: root

    required property QtObject dashboard
    property bool opened: false
    signal closed

    readonly property var dash: root.dashboard
    readonly property var part: root.dash ? root.dash._partition() : ({ left: [], right: [] })

    readonly property int previewW: 820
    readonly property int previewH: 470
    readonly property int colGap: Metrics.lg
    readonly property int cardW: root.previewW + Metrics.panelMargin * 2
    readonly property int trayH: root.hiddenIds.length > 0 ? 44 : 0
    readonly property int cardH: 46 + root.previewH + root.trayH + 1 + 54

    function _colRaw(col) {
        var h = 0
        for (var i = 0; i < col.length; i++) h += root.dash.pHeight(col[i]) + root.colGap
        return h
    }
    readonly property real rawColH: Math.max(root._colRaw(root.part.left), root._colRaw(root.part.right))
    readonly property real tileScale: root.rawColH > root.previewH ? root.previewH / root.rawColH : 1
    // Collapsed cards are 34px, so the floor is the height their header band
    // needs — a collapsed tile stays clickable rather than becoming a sliver.
    function tileH(id) { return Math.max(34, Math.round(root.dash.pHeight(id) * root.tileScale)) }

    // Cards in `order` that are currently hidden. They keep their slot in
    // `order`, so hide → show restores their position.
    readonly property var hiddenIds: (function() {
        var out = []
        if (!root.dash) return out
        for (var i = 0; i < root.dash.order.length; i++)
            if (!root.dash.pVisible(root.dash.order[i])) out.push(root.dash.order[i])
        return out
    })()

    // ── Drag state ─────────────────────────────────────────────────────
    property string dragId: ""
    property string hoverId: ""
    property bool hoverBefore: false
    property real ghostX: 0
    property real ghostY: 0
    property real ghostW: 0
    property real ghostH: 0
    property real _grabDx: 0
    property real _grabDy: 0

    visible: root.opened
    onOpenedChanged: if (!root.opened) root.endDrag()

    function endDrag() { root.dragId = ""; root.hoverId = "" }
    function beginDrag(pid, px, py, tileX, tileY, w, h) {
        root.dragId = String(pid)
        root._grabDx = px - tileX
        root._grabDy = py - tileY
        root.ghostW = w
        root.ghostH = h
        root.ghostX = tileX
        root.ghostY = tileY
    }
    function moveDrag(px, py) {
        root.ghostX = px - root._grabDx
        root.ghostY = py - root._grabDy
        var t = root._dropTarget(px, py)
        root.hoverId = t ? t.id : ""
        root.hoverBefore = t ? py < t.y + t.h / 2 : false
    }
    function dropDrag() {
        if (root.hoverId !== "") root.dash.reorder(root.dragId, root.hoverId, root.hoverBefore)
        root.endDrag()
    }
    // Live tile geometry, straight off the laid-out delegates — the columns are
    // the only layout, so hit-testing cannot drift from what is drawn.
    function _rects() {
        var out = []
        var reps = [leftRep, rightRep]
        for (var c = 0; c < reps.length; c++) {
            for (var i = 0; i < reps[c].count; i++) {
                var it = reps[c].itemAt(i)
                if (!it) continue
                var p = it.mapToItem(preview, 0, 0)
                out.push({ id: String(it.pid), x: p.x, y: p.y, w: it.width, h: it.height })
            }
        }
        return out
    }
    function _dropTarget(x, y) {
        var rects = root._rects()
        for (var i = 0; i < rects.length; i++) {
            var r = rects[i]
            if (r.id === root.dragId) continue
            if (x >= r.x && x <= r.x + r.w && y >= r.y && y <= r.y + r.h) return r
        }
        return null
    }

    // ── Tile delegate ──────────────────────────────────────────────────
    Component {
        id: tileComp
        Rectangle {
            id: tile
            required property string modelData
            readonly property string pid: String(tile.modelData)

            width: parent ? parent.width : 0
            height: root.tileH(tile.pid)
            radius: 0
            color: Colors.surfaceContainerLow
            opacity: root.dragId === tile.pid ? 0.4 : 1
            border.width: Metrics.cardBorderWidth
            border.color: root.dragId === tile.pid || root.hoverId === tile.pid
                ? Colors.accent
                : (dragArea.containsMouse ? Colors.edgeStrong : Colors.edge)

            MouseArea {
                id: dragArea
                anchors.fill: parent
                acceptedButtons: Qt.LeftButton
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor

                property bool _moving: false
                property real _px: -1
                property real _py: -1

                onPressed: (e) => {
                    dragArea._px = e.x
                    dragArea._py = e.y
                    dragArea._moving = false
                }
                onPositionChanged: (e) => {
                    // onPositionChanged also fires on plain hover moves, so the
                    // press is what arms the gesture: without this guard the
                    // first hover move was already ~_px away from -1 and started
                    // a drag with no button held.
                    if (!dragArea.pressed) return
                    var p = dragArea.mapToItem(preview, e.x, e.y)
                    if (!dragArea._moving) {
                        if (Math.abs(e.x - dragArea._px) < 5 && Math.abs(e.y - dragArea._py) < 5) return
                        dragArea._moving = true
                        var tp = tile.mapToItem(preview, 0, 0)
                        root.beginDrag(tile.pid, p.x, p.y, tp.x, tp.y, tile.width, tile.height)
                    }
                    root.moveDrag(p.x, p.y)
                }
                onReleased: {
                    if (dragArea._moving) root.dropDrag()
                    dragArea._moving = false
                    dragArea._px = -1
                }
                onCanceled: {
                    if (dragArea._moving) root.endDrag()
                    dragArea._moving = false
                    dragArea._px = -1
                }
            }

            // Header band, same accent wash Panel's card header uses.
            Item {
                id: band
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                height: Math.min(34, tile.height)

                Rectangle {
                    anchors.fill: parent
                    color: Colors.alpha(Colors.accent, 0.12)
                    border.width: Metrics.borderWidth
                    border.color: Colors.alpha(Colors.accent, 0.40)
                }
                Text {
                    visible: root.dash.panelIcon(tile.pid) !== ""
                    anchors.left: parent.left
                    anchors.leftMargin: Metrics.md
                    anchors.verticalCenter: parent.verticalCenter
                    text: root.dash.panelIcon(tile.pid)
                    font.family: Type.family
                    font.pixelSize: Type.iconInline
                    color: Colors.textSecondary
                }
                Text {
                    anchors.left: parent.left
                    anchors.leftMargin: Metrics.md + 22
                    anchors.right: parent.right
                    anchors.rightMargin: 62
                    anchors.verticalCenter: parent.verticalCenter
                    text: root.dash.labelFor(tile.pid)
                    font.family: Type.family
                    font.pixelSize: Type.sizeCaption
                    font.bold: true
                    font.letterSpacing: 1.0
                    color: Colors.textPrimary
                    elide: Text.ElideRight
                }
                Row {
                    anchors.right: parent.right
                    anchors.rightMargin: Metrics.xs
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 2
                    Button {
                        width: 28
                        height: 24
                        text: root.dash.pCollapsed(tile.pid) ? Icons.next : Icons.expand
                        variant: "plain"
                        onPressed: root.dash.toggleCollapsed(tile.pid)
                    }
                    Button {
                        width: 28
                        height: 24
                        text: Icons.eye
                        variant: "plain"
                        onPressed: root.dash.toggleVisible(tile.pid)
                    }
                }
            }

            // Insertion line for the pending drop.
            Rectangle {
                anchors.left: parent.left
                anchors.right: parent.right
                height: 3
                color: Colors.accent
                z: 20
                visible: root.dragId !== "" && root.hoverId === tile.pid
                y: root.hoverBefore ? 2 : tile.height - 5
            }
        }
    }

    // ── Scrim ──────────────────────────────────────────────────────────
    Rectangle {
        anchors.fill: parent
        // Transparent: the dashboard behind stays legible while arranging.
        // The MouseArea still eats hover and the click-away.
        color: "transparent"
        MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.LeftButton
            hoverEnabled: true
            onClicked: root.closed()
        }
    }

    // ── Card ───────────────────────────────────────────────────────────
    Rectangle {
        anchors.centerIn: parent
        width: root.cardW
        height: root.cardH
        radius: 0
        color: Colors.surfaceContainerHigh
        border.width: Metrics.cardBorderWidth
        border.color: Colors.outline

        // Swallow input on the card's own chrome. A plain Rectangle is not a
        // mouse target, so without this a click on empty card space fell
        // through to the scrim's click-away below and closed the popup.
        MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.LeftButton
            hoverEnabled: true
        }

        Column {
            anchors.fill: parent
            spacing: 0

            Item {
                width: parent.width
                height: 46
                Text {
                    anchors.left: parent.left
                    anchors.leftMargin: Metrics.panelPadding
                    anchors.verticalCenter: parent.verticalCenter
                    text: Icons.grid + " DASHBOARD LAYOUT"
                    font.family: Type.family
                    font.pixelSize: Type.sizeCaption
                    font.bold: true
                    font.letterSpacing: 1.0
                    color: Colors.textTertiary
                }
                Button {
                    anchors.right: parent.right
                    anchors.rightMargin: Metrics.sm
                    anchors.verticalCenter: parent.verticalCenter
                    width: 44
                    height: 28
                    text: Icons.close
                    variant: "plain"
                    onPressed: root.closed()
                }
            }

            Item {
                id: preview
                width: root.previewW
                height: root.previewH
                anchors.horizontalCenter: parent.horizontalCenter
                clip: true

                Column {
                    id: leftCol
                    width: (preview.width - root.colGap) / 2
                    // The gap has to shrink with the tiles: `tileScale` is derived
                    // from a column height that includes colGap, so leaving the
                    // gap at full size overflows the preview by
                    // n × colGap × (1 − scale) and clips the last tile.
                    spacing: root.colGap * root.tileScale
                    Repeater {
                        id: leftRep
                        model: root.part.left
                        delegate: tileComp
                    }
                }
                Column {
                    id: rightCol
                    x: leftCol.width + root.colGap
                    width: leftCol.width
                    spacing: root.colGap * root.tileScale
                    Repeater {
                        id: rightRep
                        model: root.part.right
                        delegate: tileComp
                    }
                }

                Text {
                    anchors.centerIn: parent
                    visible: leftCol.height === 0 && rightCol.height === 0
                    text: "Every card is hidden"
                    font.family: Type.family
                    font.pixelSize: Type.sizeSmall
                    color: Colors.textTertiary
                }

                // Ghost follows the pointer while a drag is active.
                Rectangle {
                    visible: root.dragId !== ""
                    x: root.ghostX
                    y: root.ghostY
                    width: root.ghostW
                    height: root.ghostH
                    z: 50
                    radius: 0
                    color: Colors.surfaceContainerLow
                    opacity: 0.85
                    border.width: Metrics.cardBorderWidth
                    border.color: Colors.accent
                }
            }

            Item {
                visible: root.hiddenIds.length > 0
                width: parent.width
                height: root.trayH
                Row {
                    anchors.fill: parent
                    anchors.leftMargin: Metrics.panelMargin
                    anchors.rightMargin: Metrics.panelMargin
                    spacing: Metrics.sm
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: "HIDDEN"
                        font.family: Type.family
                        font.pixelSize: Type.sizeCaption
                        font.bold: true
                        font.letterSpacing: 1.0
                        color: Colors.textTertiary
                    }
                    Repeater {
                        model: root.hiddenIds
                        delegate: Row {
                            id: hrow
                            required property var modelData
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: Metrics.xs
                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                text: root.dash.labelFor(hrow.modelData)
                                font.family: Type.family
                                font.pixelSize: Type.sizeSmall
                                color: Colors.surfaceVariantText
                            }
                            Button {
                                width: 64
                                height: 26
                                text: "SHOW"
                                variant: "soft"
                                onPressed: root.dash.toggleVisible(hrow.modelData)
                            }
                        }
                    }
                }
            }

            Rectangle { width: parent.width; height: 1; color: Colors.separator }

            Item {
                width: parent.width
                height: 54
                Text {
                    anchors.left: parent.left
                    anchors.leftMargin: Metrics.panelPadding
                    anchors.verticalCenter: parent.verticalCenter
                    text: "DRAG A CARD TO REARRANGE"
                    font.family: Type.family
                    font.pixelSize: Type.sizeCaption
                    color: Colors.textMuted
                }
                Button {
                    anchors.right: parent.right
                    anchors.rightMargin: Metrics.panelMargin
                    anchors.verticalCenter: parent.verticalCenter
                    width: 120
                    height: 30
                    text: "DONE"
                    icon: Icons.check
                    variant: "primary"
                    onPressed: root.closed()
                }
            }
        }
    }
}
