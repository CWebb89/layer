pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Io
import "../theme"
import "../components"
import "../config"

// Mainsail-style dashboard: a model-driven masonry grid of Panel cards.
// Every card lives in a single `order` (Status included, no pinning); they
// are spread across 2 columns by height balance. Reordering, show/hide and
// collapse all happen in the LayoutPopup (sidebar LAYOUT button), which
// writes back through `reorder`/`toggle*` and persists to
// ~/.local/state/layer/dashboard.json.
Item {
    id: root

    required property QtObject moonraker
    required property QtObject presetStore
    property var confirmDialog: null
    property var openView: null
    readonly property var ps: root.moonraker.active
    readonly property bool on: ps?.connected === true
    // PAUSE and CANCEL only mean something while a job is running; in STANDBY
    // they were live buttons that did nothing when pressed.
    readonly property bool jobActive: {
        var s = String(ps?.printState ?? "")
        return s === "printing" || s === "paused"
    }

    // ── STATUS card data: printer limits + recent uploads ─────────────
    property var limits: [
        { label: "VELOCITY", key: "maxVelocity", unit: "mm/s", f: 0 },
        { label: "SQUARE CORNER", key: "maxSquareCorner", unit: "mm/s", f: 1 },
        { label: "ACCELERATION", key: "maxAccel", unit: "mm/s²", f: 0 },
        { label: "MIN CRUISE RATIO", key: "cruiseRatio", unit: "%", f: 2 }
    ]
    property var allFiles: []
    property var limitOverride: ({})
    property var historyJobs: []
    readonly property var recentFiles: root.recent()
    function recent() {
        var list = []
        for (var i = 0; i < root.allFiles.length; i++)
            if (String(root.allFiles[i].path || "").endsWith(".gcode")) list.push(root.allFiles[i])
        list.sort(function(a, b) { return (Number(b.modified) || 0) - (Number(a.modified) || 0) })
        return list.slice(0, 5)
    }
    // Read through `historyJobs` rather than MoonrakerService's `data` object:
    // that one is mutated in place, so a binding on it never re-evaluates and
    // every finished file kept reading NOT PRINTED.
    function fileState(name) {
        var live = root.ps
        if (live && live.printFilename === name && root.jobActive) return String(live.printState)
        var jobs = root.historyJobs
        for (var i = 0; i < jobs.length; i++)
            if (jobs[i].filename === name) return String(jobs[i].status || "")
        return ""
    }
    readonly property string jobName: {
        var f = String(root.ps?.printFilename ?? "")
        var i = f.lastIndexOf("/")
        return i < 0 ? f : f.slice(i + 1)
    }
    function stateLabel(s) {
        if (!s) return "NOT PRINTED"
        if (s === "completed") return "COMPLETED"
        if (s === "paused") return "PAUSED"
        if (s === "printing" || s === "in_progress") return "PRINTING"
        if (s === "cancelled") return "CANCELLED"
        return "ERROR"
    }
    function fileStateColor(s) {
        if (s === "completed") return Colors.success
        if (s === "printing") return Colors.success
        if (s === "paused") return Colors.tempWarm
        if (s === "in_progress") return Colors.accent
        if (s === "cancelled" || s === "error") return Colors.error
        return Colors.outlineVariant
    }
    function limitVal(i) {
        var f = root.limits[i]
        if (!root.ps) return "—"
        var v = Number(root.ps?.[f.key] ?? 0)
        if (f.f === 2) return String(Math.round(v * 100))
        if (f.f === 1) return v.toFixed(1)
        return String(Math.round(v))
    }
    function limitDisplay(i) {
        return root.limitOverride[root.limits[i].key] ?? root.limitVal(i)
    }
    // The read-out is optimistic: it shows what you typed until the next poll
    // reports what Klipper actually accepted. It used to persist forever, so a
    // limit edited on one printer stayed on screen after switching to another,
    // and a rejected SET_VELOCITY_LIMIT still looked applied.
    function setLimitOverride(key, value) {
        var o = {}
        for (var k in root.limitOverride) o[k] = root.limitOverride[k]
        if (value === null) delete o[key]
        else o[key] = value
        root.limitOverride = o
        limitClear.restart()
    }
    Timer {
        id: limitClear
        interval: 2500
        repeat: false
        onTriggered: root.limitOverride = ({})
    }
    function applyLimit(i, v) {
        var f = root.limits[i]
        var t = String(v).trim().replace(",", ".")
        var n = Number(t)
        if (t === "" || !Number.isFinite(n) || n < 0) return
        if (f.key === "cruiseRatio") {
            root.setLimitOverride("cruiseRatio", String(Math.round(n * 100) / 100))
            root.moonraker.sendGcode("SET_VELOCITY_LIMIT MIN_CRUISE_RATIO=" + (n / 100).toFixed(3))
            return
        }
        var gp = f.key === "maxVelocity" ? "VELOCITY" : f.key === "maxSquareCorner" ? "SQUARE_CORNER_VELOCITY" : "ACCEL"
        root.setLimitOverride(f.key, String(Math.round(n)))
        root.moonraker.sendGcode("SET_VELOCITY_LIMIT " + gp + "=" + Math.round(n))
    }

    Connections {
        target: root.moonraker
        function onBucketChanged(bucket) {
            if (bucket === "files") root.allFiles = root.moonraker.data?.files?.entries ?? []
            else if (bucket === "history") root.historyJobs = root.moonraker.data?.history?.jobs ?? []
        }
        function onActivePrinterChanged() { root.limitOverride = ({}) }
    }

    // ── Panel registry + model ────────────────────────────────────────
    property var panelDefs: [
        { id: "status", label: "STATUS", icon: Icons.printer, h: 286 },
        { id: "temperature", label: "TEMPERATURE", icon: Icons.thermometer, h: 400 },
        // 372px of measured content + 40 bodyTop + 22 padding (the Column
        // reports its own implicitHeight — logged while sizing this), + 6 slack.
        { id: "toolhead", label: "TOOLHEAD", icon: Icons.move, h: 440 },
        { id: "misc", label: "MISC", icon: Icons.tune, h: 260 },
        { id: "extruder", label: "EXTRUDER", icon: Icons.spool, h: 500 },
        { id: "macros", label: "MACROS", icon: Icons.gcode, h: 160 },
        { id: "machine", label: "MACHINE", icon: Icons.chip, h: 210 },
        { id: "console", label: "CONSOLE", icon: Icons.terminal, h: 310 }
    ]
    property var panels: root._defaultPanels()
    property var order: root._defaultOrder()

    property var macros: []
    // The card's list: configured order from settings, hidden macros removed. The
    // settings tab still reads `macros` (all of them) so hidden ones can be
    // re-shown.
    readonly property var cardMacros: Settings.macrosVisible(root.macros)
    property var consoleLines: []
    property string pending: ""
    property bool consoleActive: false

    function _defaultPanels() {
        var out = []
        for (var i = 0; i < root.panelDefs.length; i++)
            out.push({ id: root.panelDefs[i].id, visible: true, collapsed: false })
        return out
    }
    function _defaultOrder() {
        var out = []
        for (var i = 0; i < root.panelDefs.length; i++)
            out.push(root.panelDefs[i].id)
        return out
    }
    // Balance the cards across two columns by running height. Status is not
    // special-cased: it is the first entry of `order`, so the balance puts it
    // first in the left column exactly as the old pinned path did.
    function _partition() {
        var left = [], right = [], lh = 0, rh = 0
        for (var i = 0; i < root.order.length; i++) {
            var id = root.order[i]
            if (!root.pVisible(id)) continue
            var h = root._balanceH(id)
            if (lh <= rh) { left.push(id); lh += h }
            else { right.push(id); rh += h }
        }
        return { left: left, right: right }
    }
    function _gridHeight() {
        var p = root._partition()
        var lh = 0, rh = 0
        for (var i = 0; i < p.left.length; i++) lh += root.pHeight(p.left[i]) + Metrics.lg
        for (var j = 0; j < p.right.length; j++) rh += root.pHeight(p.right[j]) + Metrics.lg
        return Math.max(lh, rh)
    }
    function _clonePanels() {
        return JSON.parse(JSON.stringify(root.panels))
    }
    function _findPanel(id) {
        for (var i = 0; i < root.panels.length; i++)
            if (root.panels[i].id === id) return root.panels[i]
        return null
    }
    function fullH(id) {
        for (var i = 0; i < root.panelDefs.length; i++)
            if (root.panelDefs[i].id === id) return root.panelDefs[i].h
        return 0
    }
    function labelFor(id) {
        for (var i = 0; i < root.panelDefs.length; i++)
            if (root.panelDefs[i].id === id) return root.panelDefs[i].label
        return id
    }
    function panelIcon(id) {
        for (var i = 0; i < root.panelDefs.length; i++)
            if (root.panelDefs[i].id === id) return root.panelDefs[i].icon
        return ""
    }
    function hasDef(id) {
        for (var i = 0; i < root.panelDefs.length; i++)
            if (root.panelDefs[i].id === id) return true
        return false
    }
    function pVisible(id) {
        var p = root._findPanel(id)
        return p ? p.visible : true
    }
    function pCollapsed(id) {
        var p = root._findPanel(id)
        return p ? p.collapsed : false
    }
    function pHeight(id) {
        var p = root._findPanel(id)
        if (p && p.collapsed) return 34
        if (id === "status") return root._statusHeight()
        if (id === "misc") return root._miscHeight()
        if (id === "extruder") return root._extruderHeight()
        if (id === "macros") return root._macrosHeight()
        if (id === "machine") return root._machineHeight()
        if (id === "toolhead") return root.fullH("toolhead")
            + (root.on && (root.moonraker.zOffsetChanged || root.moonraker.configSavePending)
                ? Metrics.controlHeight + Metrics.md : 0)
        if (id === "console") return root._consoleHeight()
        return root.fullH(id)
    }
    // Height of the print card inside the STATUS panel: 12px margins plus the
    // two inner rows (30px identity row, 43px read-out row) and their gap.
    // Measured, not guessed — an earlier 92px constant clipped the read-out
    // row by 13px. The card and the panel formula share this one number.
    readonly property int statusCardH: 24 + 30 + Metrics.md + 43

    function _statusHeight() {
        // File rows are laid out by the Column (a Repeater's delegates become
        // Column children), so they carry the column's 8px gap: pitch is 40+8,
        // not 40. The old `292 + n*26` ignored that gap and under-sized the
        // panel by 6px, which clipped the bottom row. Rows grew to 40px to hold
        // the 34px preview, so the pitch grew with them.
        var n = Math.min(root.recentFiles.length, 5)
        var rows = n > 0 ? n * 40 + (n - 1) * Metrics.md : 22
        return Metrics.panelPadding
            + 40                             // panel header + bodyTop gap
            + root.statusCardH
            + Metrics.md + 1 + Metrics.md + 19 + Metrics.md
            + rows
    }
    property real _demoFill: 0
    Timer {
        id: fillTimer
        interval: 60
        repeat: true
        running: root.moonraker.demo && root.on && root.visible
        onTriggered: {
            var next = root._demoFill + 0.004
            root._demoFill = next > 0.985 ? 0 : next
        }
    }
    readonly property real _progress: root.moonraker.demo
        ? root._demoFill
        : (!root.on || (root.ps?.printState !== "printing" && root.ps?.printState !== "paused")
            ? 0 : Math.max(0, Math.min(1, Number(root.ps?.printProgress || 0))))
    // The hardcoded 196 clipped the fourth limit row. Message row only exists
    // while a job is running, so it changes the height too.
    function _machineHeight() {
        var rows = root.limits.length
        var msg = root.jobActive && root.machineMessage() !== "" ? 24 : 0
        return 40 + (msg > 0 ? msg + Metrics.md : 0) + 1 + Metrics.md
            + rows * 26 + (rows - 1) * Metrics.md + Metrics.panelPadding
    }
    function machineMessage() {
        var d = String(root.ps?.displayMessage ?? "")
        var m = String(root.ps?.printMessage ?? "")
        return d !== "" ? d : m
    }
    function _miscHeight() {
        var n = root.on ? (root.ps?.fans ?? []).length : 0
        var rows = n > 0 ? n * 40 + (n - 1) * Metrics.md : 38
        return 40 + 22 + Metrics.md + rows + Metrics.panelPadding
    }
    function _extruderHeight() {
        return 448
    }
    // The chip has to fit the same Row Button builds: the label advances
    // `letterSpacing` (0.8px) on top of every glyph, and the icon prefix costs
    // iconInline + xs. Sizing off the raw font estimate alone (and capping at
    // 200) made the content wider than the chip, so the label spilled past the
    // border and pushed the icon out into the gutter.
    function _macroChipW(name) {
        var label = Math.ceil(String(name).length * (Type.sizeCaption * 0.62 + 0.8))
        var chrome = Metrics.controlPaddingX * 2 + Type.iconInline + Metrics.xs
        return Math.min(400, Math.max(88, label + chrome))
    }
    function _macrosHeight() {
        var n = root.cardMacros.length
        if (n === 0) return 110
        var contentW = (root.width - Metrics.panelMargin * 2 - Metrics.lg) / 2 - Metrics.panelPadding * 2
        var total = 0
        for (var i = 0; i < n; i++) total += root._macroChipW(root.cardMacros[i])
        var rows = Math.max(1, Math.ceil((total + (n - 1) * Metrics.sm) / contentW))
        return 72 + rows * 38
    }
    function _consoleHeight() {
        var p = root._partition()
        var own = p.left.indexOf("console") >= 0 ? p.left : p.right
        var other = own === p.left ? p.right : p.left
        var ownH = 0, otherH = 0
        for (var i = 0; i < own.length; i++)
            ownH += (own[i] === "console" ? root.consoleBaseH : root.pHeight(own[i])) + Metrics.lg
        for (var j = 0; j < other.length; j++)
            otherH += root.pHeight(other[j]) + Metrics.lg
        var avail = Math.max(otherH, scroll.height - Metrics.panelMargin)
        return root.consoleBaseH + Math.max(0, avail - ownH)
    }
    // Console is the last card in its column, so anything below it up to the
    // taller column / viewport bottom is dead space — it grows to fill that.
    // The fill never feeds the balance: _balanceH pins the console at
    // consoleBaseH while partitioning, so the columns cannot oscillate.
    // Console body: 40 (bodyTop) + 38 (input) + 8 + 1 (rule) + 8 + transcript
    // + 22 (bottom padding). The transcript is a Flickable filling the rest, and
    // a row costs 26px plus the Column's 8px gap = 34px.
    readonly property int consoleChromeH: 117
    readonly property int consoleBaseH: 109 + Math.max(1, Math.min(root.consoleLines.length, 5)) * 34
    function _balanceH(id) {
        if (id === "console") return root.pCollapsed("console") ? 34 : root.consoleBaseH
        return root.pHeight(id)
    }
    function toggleVisible(id) {
        var p = root._findPanel(id)
        if (!p) return
        p.visible = !p.visible
        root.panels = root._clonePanels()
        root._save()
    }
    function toggleCollapsed(id) {
        var p = root._findPanel(id)
        if (!p) return
        p.collapsed = !p.collapsed
        root.panels = root._clonePanels()
        root._save()
    }
    // Linear reorder of the shared cards. `before` places the dragged card
    // ahead of the target instead of after it. `order` is the dashboard's, so
    // the LayoutPopup drives this rather than mutating the array itself.
    function reorder(source, target, before) {
        var from = String(source), to = String(target)
        if (from === to) return
        var arr = JSON.parse(JSON.stringify(root.order))
        var si = arr.indexOf(from)
        if (si < 0) return
        arr.splice(si, 1)
        var ti = arr.indexOf(to)
        if (ti < 0) return
        arr.splice(before ? ti : ti + 1, 0, from)
        root.order = arr
        root._save()
    }

    // ── Persistence ───────────────────────────────────────────────────
    function _statePath() {
        return (Quickshell.env("HOME") || "~") + "/.local/state/layer/dashboard.json"
    }
    property var _saveProc: Process {
        command: ["true"]
        running: false
    }
    function _save() {
        var f = root._statePath()
        var dir = f.slice(0, f.lastIndexOf("/"))
        var json = JSON.stringify({ order: root.order, panels: root.panels })
        root._saveProc.command = ["bash", "-c",
            "mkdir -p '" + dir + "' && printf '%s' '" + json + "' > '" + f + "'"]
        root._saveProc.running = false
        root._saveProc.running = true
    }
    property var _loadProc: Process {
        command: []
        running: false
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    var t = String(text || "").trim()
                    if (!t) return
                    var d = JSON.parse(t)
                    if (!d) return
                    var out = []
                    var seen = ({})
                    var src = d.panels && Array.isArray(d.panels) ? d.panels : []
                    for (var i = 0; i < src.length; i++) {
                        var id = String(src[i].id || "")
                        if (!id || !root.hasDef(id)) continue
                        if (out.some(function(p) { return p.id === id })) continue
                        out.push({ id: id, visible: !!src[i].visible, collapsed: !!src[i].collapsed })
                        seen[id] = true
                    }
                    for (var j = 0; j < root.panelDefs.length; j++)
                        if (!seen[root.panelDefs[j].id])
                            out.push({ id: root.panelDefs[j].id, visible: true, collapsed: false })
                    var ord = []
                    if (d.order && Array.isArray(d.order)) {
                        for (var k = 0; k < d.order.length; k++) {
                            var oid = String(d.order[k] || "")
                            if (!oid || !root.hasDef(oid)) continue
                            if (ord.indexOf(oid) >= 0) continue
                            ord.push(oid)
                        }
                    }
                    if (ord.length === 0) {
                        ord = root._defaultOrder()
                    } else {
                        // A card missing from the saved order goes back to its
                        // natural slot (its panelDefs position), not the end,
                        // so a file saved before a card existed keeps it where
                        // the default order puts it.
                        for (var j = 0; j < root.panelDefs.length; j++) {
                            var oid2 = root.panelDefs[j].id
                            if (ord.indexOf(oid2) >= 0) continue
                            var at = 0
                            for (var m = 0; m < j; m++) {
                                var pos = ord.indexOf(root.panelDefs[m].id)
                                if (pos >= 0 && pos + 1 > at) at = pos + 1
                            }
                            ord.splice(at, 0, oid2)
                        }
                    }
                    root.panels = out
                    root.order = ord
                } catch (e) {
                    console.error("dashboard layout parse failed:", e)
                }
            }
        }
    }

    // ── Data hooks ────────────────────────────────────────────────────
    function refresh() {
        root.moonraker.refresh()
        root.moonraker.fetchMacros()
        root.moonraker.fetchGcodeStore(40)
    }
    function run(v) { root.moonraker.sendGcode(v) }
    function lineColor(type) {
        if (type === "command") return Colors.accent
        if (type === "error") return Colors.error
        return Colors.surfaceVariantText
    }
    // dashboard console input (click the prompt, type, Enter sends, Esc leaves)
    function handleKey(event) {
        if (event.key === Qt.Key_Escape) {
            root.pending = ""
            root.consoleActive = false
            event.accepted = true
        } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            root.consoleSend()
            event.accepted = true
        } else if (event.key === Qt.Key_Backspace) {
            root.pending = root.pending.slice(0, -1)
            event.accepted = true
        } else if (event.text && event.text.length === 1
                   && event.text.charCodeAt(0) >= 32 && event.text.charCodeAt(0) !== 127) {
            root.pending += event.text
            event.accepted = true
        }
    }
    function consoleSend() {
        var s = root.pending.trim()
        if (s !== "") { root.moonraker.sendGcode(s); root.moonraker.fetchGcodeStore(40) }
        root.pending = ""
        root.consoleActive = false
    }
    Connections {
        target: root.moonraker
        function onBucketChanged(bucket) {
            if (bucket === "macros") root.macros = root.moonraker.data?.macros ?? []
        }
        function onGcodeStoreFetched(ok, list) {
            if (ok) root.consoleLines = list
        }
    }
    Component.onCompleted: {
        root.moonraker.fetchMacros()
        root.moonraker.fetchGcodeStore(40)
        root.moonraker.fetchFiles("gcodes")
        root.moonraker.fetchHistory()
        root._loadProc.command = ["bash", "-c", "cat '" + root._statePath() + "' 2>/dev/null"]
        root._loadProc.running = false
        root._loadProc.running = true
    }

    // ── Shared panel delegate (all card content, switched on id) ───────
    property Component panelDelegate: Component {
        Panel {
            id: leg
            required property var modelData

            width: parent.width
            pid: String(leg.modelData)
            title: root.panelTitle(pid)
            icon: root.panelIcon(pid)
            visible: root.pVisible(pid)
            collapsed: root.pCollapsed(pid)
            collapsible: true
            height: root.pHeight(pid)
            onToggled: root.toggleCollapsed(pid)

            // STATUS
            Column {
                visible: parent.bodyVisible && pid === "status"
                anchors.left: parent.left
                anchors.leftMargin: Metrics.panelPadding
                anchors.right: parent.right
                anchors.rightMargin: Metrics.panelPadding
                anchors.top: parent.top
                anchors.topMargin: parent.bodyTop
                spacing: Metrics.md

                Rectangle {
                    width: parent.width
                    height: root.statusCardH
                    radius: 0
                    color: Colors.surfaceContainerLow
                    border.width: Metrics.cardBorderWidth
                    border.color: Colors.outlineVariant
                    clip: true

                    Rectangle {
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.bottom: parent.bottom
                        height: parent.height * root._progress
                        Behavior on height {
                            NumberAnimation { duration: 240; easing.type: Easing.Linear }
                        }
                        color: Colors.alpha(Colors.accent, 0.26)
                    }

                    Column {
                        anchors.fill: parent
                        anchors.leftMargin: 14
                        anchors.rightMargin: 14
                        anchors.topMargin: 12
                        anchors.bottomMargin: 12
                        spacing: 8
                        Item {
                            id: statusRow
                            width: parent.width
                            height: 28
                            Rectangle {
                                id: statusDot
                                width: 8
                                height: 8
                                radius: 4
                                anchors.left: parent.left
                                anchors.verticalCenter: parent.verticalCenter
                                color: root.on ? Colors.accent : Colors.outlineVariant
                            }
                            Text {
                                anchors.left: statusDot.right
                                anchors.leftMargin: Metrics.sm
                                anchors.right: statusRight.left
                                anchors.rightMargin: Metrics.md
                                anchors.verticalCenter: parent.verticalCenter
                                text: root.moonraker.activePrinter
                                font.family: Type.family
                                font.pixelSize: Type.sizeHeading
                                font.bold: true
                                color: Colors.textPrimary
                                elide: Text.ElideRight
                            }
                            Row {
                                id: statusRight
                                anchors.right: parent.right
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: Metrics.sm
                                Chip {
                                    visible: root.moonraker.demo
                                    text: "DEMO"
                                    pill: true
                                    filled: true
                                    color: Colors.tempWarm
                                    anchors.verticalCenter: parent.verticalCenter
                                }
                                Text {
                                    visible: root.jobActive && root.jobName !== ""
                                    width: Math.min(implicitWidth, statusRow.width * 0.5)
                                    horizontalAlignment: Text.AlignRight
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: root.jobName
                                    font.family: Type.family
                                    font.pixelSize: Type.sizeSmall
                                    color: Colors.textSecondary
                                    elide: Text.ElideMiddle
                                }
                            }
                        }
                        Row {
                            width: parent.width
                            spacing: Metrics.xl
                            Column {
                                width: (parent.width - Metrics.xl * 3) / 4
                                spacing: 2
                                Text {
                                    width: parent.width
                                    text: "STATE"
                                    font.family: Type.family
                                    font.pixelSize: Type.sizeCaption
                                    font.bold: true
                                    font.letterSpacing: 1.0
                                    color: Colors.textTertiary
                                    elide: Text.ElideRight
                                }
                                Text {
                                    width: parent.width
                                    text: (root.ps?.printState || "—").toString().toUpperCase()
                                    font.family: Type.family
                                    font.pixelSize: Type.sizeSmall
                                    font.bold: true
                                    color: Colors.textPrimary
                                    elide: Text.ElideRight
                                }
                            }
                            Column {
                                width: (parent.width - Metrics.xl * 3) / 4
                                spacing: 2
                                Text {
                                    width: parent.width
                                    text: "PROGRESS"
                                    font.family: Type.family
                                    font.pixelSize: Type.sizeCaption
                                    font.bold: true
                                    font.letterSpacing: 1.0
                                    color: Colors.textTertiary
                                    elide: Text.ElideRight
                                }
                                Text {
                                    width: parent.width
                                    text: root.fmt(root._progress * 100) + "%"
                                    font.family: Type.family
                                    font.pixelSize: Type.sizeSmall
                                    font.bold: true
                                    color: Colors.textPrimary
                                    elide: Text.ElideRight
                                }
                            }
                            Column {
                                width: (parent.width - Metrics.xl * 3) / 4
                                spacing: 2
                                Text {
                                    width: parent.width
                                    text: "ELAPSED"
                                    font.family: Type.family
                                    font.pixelSize: Type.sizeCaption
                                    font.bold: true
                                    font.letterSpacing: 1.0
                                    color: Colors.textTertiary
                                    elide: Text.ElideRight
                                }
                                Text {
                                    width: parent.width
                                    text: root.dur(root.moonraker.demo ? root._demoFill * 20600 : Number(root.ps?.printDuration || 0))
                                    font.family: Type.family
                                    font.pixelSize: Type.sizeSmall
                                    font.bold: true
                                    color: Colors.textPrimary
                                    elide: Text.ElideRight
                                }
                            }
                            Column {
                                width: (parent.width - Metrics.xl * 3) / 4
                                spacing: 2
                                Text {
                                    width: parent.width
                                    text: "LEFT"
                                    font.family: Type.family
                                    font.pixelSize: Type.sizeCaption
                                    font.bold: true
                                    font.letterSpacing: 1.0
                                    color: Colors.textTertiary
                                    elide: Text.ElideRight
                                }
                                Text {
                                    width: parent.width
                                    text: root.moonraker.demo ? root.dur((1 - root._demoFill) * 20600) : root.remaining()
                                    font.family: Type.family
                                    font.pixelSize: Type.sizeSmall
                                    font.bold: true
                                    color: Colors.textPrimary
                                    elide: Text.ElideRight
                                }
                            }
                        }
                    }
                }
                Rectangle { width: parent.width; height: 1; color: Colors.separator }
                Text {
                    width: parent.width
                    text: "G-CODE FILES"
                    font.family: Type.family
                    font.pixelSize: Type.sizeCaption
                    font.bold: true
                    font.letterSpacing: 1.0
                    color: Colors.textTertiary
                }
                Repeater {
                    width: parent.width
                    height: Math.min(root.recentFiles.length, 5) * 26
                    model: root.recentFiles
                    delegate: Item {
                        id: frow
                        required property var modelData
                        width: parent ? parent.width : 0
                        height: 40
                        Rectangle {
                            anchors.fill: parent
                            radius: Metrics.radiusSmall
                            color: rf.containsMouse ? Colors.hoverFill : "transparent"
                        }
                        Rectangle {
                            width: 34
                            height: 34
                            radius: Metrics.radiusSmall
                            color: Colors.surfaceContainerHighest
                            clip: true
                            anchors.left: parent.left
                            anchors.leftMargin: 3
                            anchors.verticalCenter: parent.verticalCenter
                            Image {
                                anchors.fill: parent
                                asynchronous: true
                                cache: true
                                fillMode: Image.PreserveAspectCrop
                                source: root.moonraker.thumbSource(frow.modelData)
                                visible: status === Image.Ready
                            }
                        }
                        Text {
                            anchors.left: parent.left
                            anchors.leftMargin: 3 + 34 + Metrics.md
                            anchors.verticalCenter: parent.verticalCenter
                            width: parent.width - (3 + 34 + Metrics.md) - 150
                            text: String(frow.modelData.path || "")
                            font.family: Type.family
                            font.pixelSize: Type.sizeSmall
                            color: Colors.textPrimary
                            elide: Text.ElideMiddle
                        }
                        Text {
                            anchors.right: parent.right
                            anchors.rightMargin: 8
                            anchors.verticalCenter: parent.verticalCenter
                            text: root.stateLabel(root.fileState(String(frow.modelData.path)))
                            font.family: Type.family
                            font.pixelSize: Type.sizeCaption
                            font.bold: true
                            color: root.fileStateColor(root.fileState(String(frow.modelData.path)))
                        }
                        MouseArea {
                            id: rf
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.on && root.askStartPrint(String(frow.modelData.path || ""))
                        }
                    }
                }
                Text {
                    width: parent.width
                    visible: root.recentFiles.length === 0
                    text: "no gcode files on the printer yet — slice and upload from Orca-Slicer"
                    font.family: Type.family
                    font.pixelSize: Type.sizeSmall
                    color: Colors.textTertiary
                }
            }

            // TEMPERATURE
            TempGraphCard {
                visible: parent.bodyVisible && pid === "temperature"
                anchors.left: parent.left
                anchors.leftMargin: Metrics.panelPadding
                anchors.right: parent.right
                anchors.rightMargin: Metrics.panelPadding
                anchors.top: parent.top
                anchors.topMargin: parent.bodyTop
                anchors.bottom: parent.bottom
                anchors.bottomMargin: Metrics.panelPadding
                store: root.ps?.tempStore?.series ?? []
            }

            // TOOLHEAD
            Column {
                visible: parent.bodyVisible && pid === "toolhead"
                anchors.left: parent.left
                anchors.leftMargin: Metrics.panelPadding
                anchors.right: parent.right
                anchors.rightMargin: Metrics.panelPadding
                anchors.top: parent.top
                anchors.topMargin: parent.bodyTop
                spacing: Metrics.md

                Row {
                    width: parent.width
                    height: 68
                    spacing: Metrics.md
                    Repeater {
                        model: [["X", "X", Settings.bedXYRate], ["Y", "Y", Settings.bedXYRate], ["Z", "Z", Settings.bedZRate]]
                        delegate: Column {
                            id: jogCol
                            required property var modelData
                            width: (parent ? parent.width - Metrics.md * 2 : 0) / 3
                            spacing: 2
                            Text {
                                width: parent.width
                                text: String(jogCol.modelData[0])
                                font.family: Type.family
                                font.pixelSize: Type.sizeTitle
                                font.bold: true
                                font.letterSpacing: 1.0
                                color: Colors.textSecondary
                                horizontalAlignment: Text.AlignHCenter
                            }
                            Row {
                                width: parent.width
                                height: 46
                                spacing: Metrics.sm
                                Button { width: 54; height: Metrics.controlHeight; variant: "plain"; text: "−";
                                         onPressed: root.jog(jogCol.modelData[1], -1, jogCol.modelData[2]) }
                                Text {
                                    width: parent.width - 54 - 54 - Metrics.sm * 2
                                    text: root.on ? root.fmt(Settings.lengthValue(root.axisPos(jogCol.modelData[0]))) : "—"
                                    font.family: Type.family
                                    font.pixelSize: Type.sizeLarge
                                    font.bold: true
                                    color: Colors.textSecondary
                                    horizontalAlignment: Text.AlignHCenter
                                }
                                Button { width: 54; height: Metrics.controlHeight; variant: "plain"; text: "+";
                                         onPressed: root.jog(jogCol.modelData[1], 1, jogCol.modelData[2]) }
                            }
                        }
                    }
                }
                Column {
                    anchors.horizontalCenter: parent.horizontalCenter
                    spacing: Metrics.sm
                    Text {
                        anchors.horizontalCenter: parent.horizontalCenter
                        text: "MOVE"
                        font.family: Type.family
                        font.pixelSize: Type.sizeSmall
                        font.bold: true
                        font.letterSpacing: 1.0
                        color: Colors.textSecondary
                    }
                    // Six chips at 56 plus five 6px gaps is 366px, well inside the
                    // 797px this card has at the shell's 1900px window.
                    Row {
                        anchors.horizontalCenter: parent.horizontalCenter
                        height: Metrics.controlHeight
                        spacing: Metrics.sm
                        Repeater {
                        model: Settings.toolheadSteps
                        delegate: Item {
                            required property var modelData
                            width: 56
                            height: Metrics.controlHeight
                            Rectangle {
                                anchors.fill: parent
                                radius: Metrics.radiusSmall
                                color: root.jogDist === modelData ? Colors.selectedFill
                                     : (mv.containsMouse ? Colors.hoverFill : "transparent")
                            }
                            Text {
                                anchors.centerIn: parent
                                text: String(modelData) + "mm"
                                font.family: Type.family
                                font.pixelSize: Type.sizeSmall
                                font.bold: true
                                color: root.jogDist === modelData ? Colors.accent : Colors.surfaceVariantText
                            }
                            MouseArea {
                                id: mv
                                anchors.fill: parent
                                acceptedButtons: Qt.LeftButton
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: root.jogDist = Number(modelData)
                            }
                        }
                    }
                }
                }
                // One row: 489px of the 797px this card has.
                Row {
                    anchors.horizontalCenter: parent.horizontalCenter
                    height: Metrics.controlHeight
                    spacing: Metrics.sm
                    Button { text: "HOME ALL"; icon: Icons.home; variant: "soft"; height: Metrics.controlHeight; onPressed: root.moonraker.moveHomeAll() }
                    Button { text: "HOME XY"; icon: Icons.home; variant: "soft"; height: Metrics.controlHeight; onPressed: root.moonraker.moveHomeXY() }
                    Button { text: "HOME Z"; icon: Icons.home; variant: "soft"; height: Metrics.controlHeight; onPressed: root.moonraker.moveHomeZ() }
                    Button { text: "MOTORS OFF"; icon: Icons.power; variant: "soft"; height: Metrics.controlHeight; onPressed: root.moonraker.motorsOff() }
                    Button { text: "QGL"; icon: Icons.target; variant: "soft"; height: Metrics.controlHeight; onPressed: root.moonraker.quadGantryLevel() }
                }
                // One row again, as the card reads at 1900px wide: eight 5-6
                // character buttons (644px) with the sizeLarge readout between the
                // negatives and the positives, eight 4px gaps — 772px of 797.
                Rectangle { width: parent.width; height: 1; color: Colors.separator }
                Column {
                    anchors.horizontalCenter: parent.horizontalCenter
                    spacing: Metrics.sm
                    Text {
                        anchors.horizontalCenter: parent.horizontalCenter
                        text: "Z-OFFSET"
                        font.family: Type.family
                        font.pixelSize: Type.sizeSmall
                        font.bold: true
                        font.letterSpacing: 1.0
                        color: Colors.textSecondary
                    }
                    Row {
                        anchors.horizontalCenter: parent.horizontalCenter
                        height: Metrics.controlHeight
                        spacing: Metrics.xs
                        Button { text: "−0.05";  variant: "plain"; onPressed: root.moonraker.zAdjust(-0.05) }
                        Button { text: "−0.025"; variant: "plain"; onPressed: root.moonraker.zAdjust(-0.025) }
                        Button { text: "−0.01";  variant: "plain"; onPressed: root.moonraker.zAdjust(-0.01) }
                        Button { text: "−0.005"; variant: "plain"; onPressed: root.moonraker.zAdjust(-0.005) }
                        Text {
                            width: 108
                            height: parent.height
                            text: root.on ? Settings.lengthText(root.ps?.zOffset ?? 0, Settings.lengthUnit === "in" ? 4 : 3) : "—"
                            font.family: Type.family
                            font.pixelSize: Type.sizeLarge
                            font.bold: true
                            color: Colors.textSecondary
                            horizontalAlignment: Text.AlignHCenter
                            verticalAlignment: Text.AlignVCenter
                        }
                        Button { text: "+0.005"; variant: "plain"; onPressed: root.moonraker.zAdjust(0.005) }
                        Button { text: "+0.01";  variant: "plain"; onPressed: root.moonraker.zAdjust(0.01) }
                        Button { text: "+0.025"; variant: "plain"; onPressed: root.moonraker.zAdjust(0.025) }
                        Button { text: "+0.05";  variant: "plain"; onPressed: root.moonraker.zAdjust(0.05) }
                    }
                }
                // Appears only while a babystep is pending (SAVE Z staged it and
                // Klipper wants a SAVE_CONFIG) or the offset has drifted from
                // the value the shell saw at connect (CLEAR returns to it).
                Row {
                    id: zActions
                    anchors.horizontalCenter: parent.horizontalCenter
                    height: Metrics.controlHeight
                    spacing: Metrics.sm
                    visible: root.on && (root.moonraker.configSavePending || root.moonraker.zOffsetChanged)
                    Button {
                        text: "SAVE CONFIG"
                        icon: Icons.save
                        variant: "soft"
                        height: Metrics.controlHeight
                        visible: root.on && root.moonraker.configSavePending
                        onPressed: root.askSaveConfig()
                    }
                    Button {
                        text: "CLEAR"
                        icon: Icons.clear
                        variant: "plain"
                        height: Metrics.controlHeight
                        visible: root.on && root.moonraker.zOffsetChanged
                        onPressed: root.moonraker.clearZOffset()
                    }
                }
                Row {
                    anchors.horizontalCenter: parent.horizontalCenter
                    height: Metrics.controlHeight
                    spacing: Metrics.sm
                    Button { text: "SAVE Z (ENDSTOP)"; icon: Icons.save; variant: "soft"; height: Metrics.controlHeight; onPressed: root.moonraker.zOffsetApply("endstop") }
                    Button { text: "SAVE Z (PROBE)"; icon: Icons.save; variant: "soft"; height: Metrics.controlHeight; onPressed: root.moonraker.zOffsetApply("probe") }
                }
                Rectangle { width: parent.width; height: 1; color: Colors.separator }
                Item {
                    id: speedRow
                    width: parent.width
                    height: Metrics.controlHeight
                    property real _drag: -1
                    readonly property real spd: speedRow._drag >= 0 ? speedRow._drag : Number(root.ps?.speedFactor ?? 1)
                    Text {
                        x: 6
                        width: 140
                        text: "SPEED"
                        font.family: Type.family
                        font.pixelSize: Type.sizeSmall
                        font.bold: true
                        font.letterSpacing: 1.0
                        color: Colors.textTertiary
                        anchors.verticalCenter: parent.verticalCenter
                    }
                    Item {
                        x: 150
                        anchors.verticalCenter: parent.verticalCenter
                        width: parent.width - 150 - 52
                        height: 22
                        Rectangle {
                            anchors.fill: parent
                            radius: 11
                            color: Colors.surfaceContainerHighest
                        }
                        Rectangle {
                            width: parent.width * speedRow.spd
                            height: parent.height
                            radius: 11
                            color: Colors.accent
                        }
                        Rectangle {
                            x: Math.max(0, Math.min(parent.width - 20, parent.width * speedRow.spd - 10))
                            anchors.verticalCenter: parent.verticalCenter
                            width: 20
                            height: 20
                            radius: 10
                            color: Colors.textPrimary
                        }
                        MouseArea {
                            id: sr
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onPressed: (e) => {
                                speedRow._drag = Math.max(0, Math.min(1.5, e.x / sr.width))
                                root.moonraker.setSpeedFactor(Math.round(speedRow._drag * 100))
                            }
                            onPositionChanged: (e) => {
                                if (sr.pressed) {
                                    speedRow._drag = Math.max(0, Math.min(1.5, e.x / sr.width))
                                    root.moonraker.setSpeedFactor(Math.round(speedRow._drag * 100))
                                }
                            }
                            onCanceled: speedRow._drag = -1
                        }
                    }
                    Text {
                        width: 48
                        text: Math.round(speedRow.spd * 100) + "%"
                        font.family: Type.family
                        font.pixelSize: Type.sizeSmall
                        font.bold: true
                        color: Colors.textPrimary
                        horizontalAlignment: Text.AlignRight
                        anchors.right: parent.right
                        anchors.rightMargin: 8
                        anchors.verticalCenter: parent.verticalCenter
                    }
                }
            }

            // MISC (fans)
            Column {
                visible: parent.bodyVisible && pid === "misc"
                anchors.left: parent.left
                anchors.leftMargin: Metrics.panelPadding
                anchors.right: parent.right
                anchors.rightMargin: Metrics.panelPadding
                anchors.top: parent.top
                anchors.topMargin: parent.bodyTop
                spacing: Metrics.md

                Text {
                    width: parent.width
                    text: "FANS"
                    font.family: Type.family
                    font.pixelSize: Type.sizeSmall
                    font.bold: true
                    font.letterSpacing: 1.0
                    color: Colors.textTertiary
                }
                Item {
                    visible: root.on && (root.ps?.fans ?? []).length === 0
                    width: parent.width
                    height: Metrics.controlHeight
                    Text {
                        anchors.centerIn: parent
                        width: parent.width
                        text: "no fan objects — configure fans in Klipper"
                        font.family: Type.family
                        font.pixelSize: Type.sizeSmall
                        color: Colors.textTertiary
                        horizontalAlignment: Text.AlignHCenter
                    }
                }
                Repeater {
                    width: parent.width
                    model: root.on ? (root.ps?.fans ?? []) : []
                    delegate: Item {
                        id: fanRow
                        required property var modelData
                        width: parent ? parent.width : 0
                        height: 40
                        property real _drag: -1
                        readonly property real spd: fanRow._drag >= 0 ? fanRow._drag : Number(fanRow.modelData.speed ?? 0)
                        Rectangle {
                            anchors.fill: parent
                            radius: Metrics.radiusSmall
                            color: fr.containsMouse ? Colors.hoverFill : "transparent"
                            Behavior on color { ColorAnimation { duration: 120 } }
                        }
                        Text {
                            x: 6
                            width: 190
                            text: fanRow.modelData.display
                            font.family: Type.family
                            font.pixelSize: Type.sizeSmall
                            font.bold: true
                            color: Colors.surfaceVariantText
                            anchors.verticalCenter: parent.verticalCenter
                            elide: Text.ElideRight
                        }
                        Item {
                            x: 200
                            anchors.verticalCenter: parent.verticalCenter
                            width: parent.width - 200 - 52
                            height: 22
                            Rectangle {
                                anchors.fill: parent
                                radius: 11
                                color: Colors.surfaceContainerHighest
                            }
                            Rectangle {
                                width: parent.width * fanRow.spd
                                height: parent.height
                                radius: 11
                                color: Colors.accent
                            }
                            Rectangle {
                                x: Math.max(0, Math.min(parent.width - 20, parent.width * fanRow.spd - 10))
                                anchors.verticalCenter: parent.verticalCenter
                                width: 20
                                height: 20
                                radius: 10
                                color: Colors.textPrimary
                            }
                            MouseArea {
                                id: fr
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onPressed: (e) => {
                                    fanRow._drag = Math.max(0, Math.min(1, e.x / fr.width))
                                    root.moonraker.setFanSpeed(fanRow.modelData.name, fanRow._drag)
                                }
                                onPositionChanged: (e) => {
                                    if (fr.pressed) {
                                        fanRow._drag = Math.max(0, Math.min(1, e.x / fr.width))
                                        root.moonraker.setFanSpeed(fanRow.modelData.name, fanRow._drag)
                                    }
                                }
                                onCanceled: fanRow._drag = -1
                            }
                        }
                        Text {
                            width: 48
                            text: Math.round(fanRow.spd * 100) + "%"
                            font.family: Type.family
                            font.pixelSize: Type.sizeSmall
                            font.bold: true
                            color: Colors.textPrimary
                            horizontalAlignment: Text.AlignRight
                            anchors.right: parent.right
                            anchors.rightMargin: 8
                            anchors.verticalCenter: parent.verticalCenter
                        }
                    }
                }
            }

            // EXTRUDER
            Column {
                visible: parent.bodyVisible && pid === "extruder"
                anchors.left: parent.left
                anchors.leftMargin: Metrics.panelPadding
                anchors.right: parent.right
                anchors.rightMargin: Metrics.panelPadding
                anchors.top: parent.top
                anchors.topMargin: parent.bodyTop
                spacing: Metrics.md

                Repeater {
                    width: parent.width
                    model: root.on ? [ { key: "extruder", label: "HOTEND", temp: root.ps.extruderTemp, target: root.ps.extruderTarget },
                                       { key: "heater_bed", label: "BED", temp: root.ps.bedTemp, target: root.ps.bedTarget } ]
                                   : [ { key: "extruder", label: "HOTEND", temp: 0, target: 0 },
                                       { key: "heater_bed", label: "BED", temp: 0, target: 0 } ]
                    delegate: Item {
                        id: hrow
                        required property var modelData
                        width: parent ? parent.width : 0
                        height: 58
                        property color tc: root.tempColor(modelData.temp, modelData.target)

                        Text {
                            anchors.left: parent.left
                            width: 96
                            text: (hrow.modelData.key === "heater_bed" ? Icons.bed : Icons.nozzle)
                                  + "  " + hrow.modelData.label
                            font.family: Type.family
                            font.pixelSize: Type.sizeSmall
                            font.bold: true
                            font.letterSpacing: 1.0
                            color: Colors.textTertiary
                        }
                        Row {
                            x: 100
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: 10
                            Text {
                                id: ctemp
                                text: Settings.tempText(hrow.modelData.temp)
                                font.family: Type.family
                                font.pixelSize: Type.sizeLarge
                                font.bold: true
                                color: hrow.tc
                                Behavior on color { ColorAnimation { duration: 300 } }
                            }
                            Text {
                                text: "→ " + Settings.tempText(hrow.modelData.target)
                                font.family: Type.family
                                font.pixelSize: Type.sizeSmall
                                color: Colors.textTertiary
                                anchors.baseline: ctemp.baseline
                            }
                        }
                        Rectangle {
                            anchors.right: parent.right
                            anchors.rightMargin: 8
                            anchors.verticalCenter: parent.verticalCenter
                            width: 96
                            height: 24
                            radius: 0
                            color: htemp.activeFocus ? Colors.accentDim : Colors.surfaceContainerHighest
                            border.width: htemp.activeFocus ? 1 : 0
                            border.color: Colors.accent
                            TextInput {
                                id: htemp
                                anchors.fill: parent
                                anchors.leftMargin: 8
                                anchors.rightMargin: 34
                                verticalAlignment: Text.AlignVCenter
                                // Seeded from the printer, not bound to it: a poll
                                // re-evaluating a binding would rewrite the field
                                // under the cursor mid-number.
                                readonly property string live: root.fmt(Settings.tempValue(hrow.modelData.target))
                                Component.onCompleted: text = live
                                onLiveChanged: if (!activeFocus) text = live
                                onActiveFocusChanged: {
                                    if (activeFocus) {
                                        TextFocus.acquire(this)
                                        selectAll()
                                    } else {
                                        TextFocus.release(this)
                                        text = live
                                    }
                                }
                                Keys.onEscapePressed: focus = false
                                font.family: Type.family
                                font.pixelSize: Type.sizeSmall
                                color: Colors.textPrimary
                                inputMethodHints: Qt.ImhFormattedNumbersOnly
                                property bool _committing: false
                                onEditingFinished: {
                                    if (_committing) return
                                    _committing = true
                                    var n = Settings.tempBack(text)
                                    if (text.trim() !== "" && Number.isFinite(n) && n >= 0)
                                        root.setHeaterTarget(hrow.modelData.key, n, 0)
                                    focus = false
                                    _committing = false
                                }
                            }
                            Text {
                                anchors.right: parent.right
                                anchors.rightMargin: 8
                                anchors.verticalCenter: parent.verticalCenter
                                text: Settings.tempSuffix()
                                font.family: Type.family
                                font.pixelSize: Type.sizeCaption
                                color: Colors.textTertiary
                            }
                        }
                    }
                }
                Rectangle { width: parent.width; height: 1; color: Colors.separator }
                Row {
                    width: parent.width
                    height: Metrics.controlHeight
                    spacing: Metrics.sm
                    Text {
                        width: 96
                        text: "FLOW"
                        font.family: Type.family
                        font.pixelSize: Type.sizeSmall
                        font.bold: true
                        font.letterSpacing: 1.0
                        color: Colors.textTertiary
                        anchors.verticalCenter: parent.verticalCenter
                    }
                    Item {
                        width: parent.width - 96 - 80
                        height: 24
                        anchors.verticalCenter: parent.verticalCenter
                        Rectangle {
                            anchors.fill: parent
                            radius: 12
                            color: Colors.surfaceContainerHighest
                        }
                        Rectangle {
                            width: parent.width * Math.min(1, (root.ps?.flowFactor ?? 1))
                            height: parent.height
                            radius: 12
                            color: Colors.accent
                        }
                        Rectangle {
                            x: Math.max(0, Math.min(parent.width - 20, parent.width * Math.min(1, (root.ps?.flowFactor ?? 1)) - 10))
                            anchors.verticalCenter: parent.verticalCenter
                            width: 20
                            height: 20
                            radius: 10
                            color: Colors.textPrimary
                        }
                        MouseArea {
                            id: flowDrag
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onPressed: (e) => root.moonraker.setFlowFactor(Math.round(100 * Math.max(0, Math.min(1.5, e.x / flowDrag.width))))
                            onPositionChanged: (e) => { if (flowDrag.pressed) root.moonraker.setFlowFactor(Math.round(100 * Math.max(0, Math.min(1.5, e.x / flowDrag.width)))) }
                        }
                    }
                    Text {
                        width: 80
                        text: root.on ? Math.round((root.ps?.flowFactor ?? 0) * 100) + "%" : "—"
                        font.family: Type.family
                        font.pixelSize: Type.sizeSmall
                        font.bold: true
                        color: Colors.textPrimary
                        horizontalAlignment: Text.AlignRight
                        anchors.verticalCenter: parent.verticalCenter
                    }
                }
                Row {
                    width: parent.width
                    height: Metrics.controlHeight
                    spacing: Metrics.sm
                    Text {
                        width: parent.width - 148 - Metrics.sm * 3
                        text: "PRESSURE ADVANCED"
                        font.family: Type.family
                        font.pixelSize: Type.sizeSmall
                        font.bold: true
                        font.letterSpacing: 0.4
                        color: Colors.textTertiary
                        elide: Text.ElideRight
                        anchors.verticalCenter: parent.verticalCenter
                    }
                    Button { text: "−"; variant: "plain"; width: 34; height: Metrics.controlHeight; onPressed: root.moonraker.setPressureAdvance(((root.ps?.pressureAdvance ?? 0) - 0.01).toFixed(3)) }
                    Text {
                        width: 80
                        text: root.on ? (root.ps?.pressureAdvance ?? 0).toFixed(3) : "—"
                        font.family: Type.family
                        font.pixelSize: Type.sizeTitle
                        font.bold: true
                        color: Colors.textPrimary
                        horizontalAlignment: Text.AlignHCenter
                        anchors.verticalCenter: parent.verticalCenter
                    }
                    Button { text: "+"; variant: "plain"; width: 34; height: Metrics.controlHeight; onPressed: root.moonraker.setPressureAdvance(((root.ps?.pressureAdvance ?? 0) + 0.01).toFixed(3)) }
                }
                Row {
                    width: parent.width
                    height: Metrics.controlHeight
                    spacing: Metrics.sm
                    Text {
                        width: parent.width - 148 - Metrics.sm * 3
                        text: "SMOOTH TIME"
                        font.family: Type.family
                        font.pixelSize: Type.sizeSmall
                        font.bold: true
                        font.letterSpacing: 1.0
                        color: Colors.textTertiary
                        elide: Text.ElideRight
                        anchors.verticalCenter: parent.verticalCenter
                    }
                    Button { text: "−"; variant: "plain"; width: 34; height: Metrics.controlHeight; onPressed: root.moonraker.setSmoothTime(Math.max(0, (root.ps?.smoothTime ?? 0) - 0.01).toFixed(2)) }
                    Text {
                        width: 80
                        text: root.on ? (root.ps?.smoothTime ?? 0).toFixed(2) + "s" : "—"
                        font.family: Type.family
                        font.pixelSize: Type.sizeTitle
                        font.bold: true
                        color: Colors.textPrimary
                        horizontalAlignment: Text.AlignHCenter
                        anchors.verticalCenter: parent.verticalCenter
                    }
                    Button { text: "+"; variant: "plain"; width: 34; height: Metrics.controlHeight; onPressed: root.moonraker.setSmoothTime(((root.ps?.smoothTime ?? 0) + 0.01).toFixed(2)) }
                }
                Rectangle { width: parent.width; height: 1; color: Colors.separator }
                Item {
                    width: parent.width
                    height: Metrics.controlHeight
                    Row {
                        visible: root.presetStore.presets.filter(function(p) { return p.visible }).length > 0
                        anchors.left: parent.left
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: Metrics.sm
                        Repeater {
                            model: root.presetStore.presets.filter(function(p) { return p.visible })
                            delegate: Button {
                                required property var modelData
                                height: Metrics.controlHeight
                                text: String(modelData.name)
                                variant: "soft"
                                active: root.on
                                onPressed: root.setPreset(modelData.name, modelData.ext, modelData.bed)
                            }
                        }
                    }
                    Text {
                        visible: root.presetStore.presets.filter(function(p) { return p.visible }).length === 0
                        anchors.left: parent.left
                        anchors.verticalCenter: parent.verticalCenter
                        width: parent.width - 242
                        text: "no presets enabled — show or add them in Settings"
                        font.family: Type.family
                        font.pixelSize: Type.sizeSmall
                        color: Colors.textTertiary
                    }
                    Item {
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        width: 242
                        height: parent.height
                        Row {
                            anchors.centerIn: parent
                            spacing: Metrics.sm
                            Button { text: "RETRACT"; variant: "soft"; height: Metrics.controlHeight; active: root.on; onPressed: root.extrudeRetract(-1) }
                            Button { text: "EXTRUDE"; variant: "primary"; height: Metrics.controlHeight; active: root.on; onPressed: root.extrudeRetract(1) }
                        }
                    }
                }
                Item {
                    width: parent.width
                    height: Metrics.controlHeight
                    Item {
                        anchors.right: parent.right
                        width: 242
                        height: parent.height
                        Row {
                            anchors.centerIn: parent
                            spacing: Metrics.sm
                            Repeater {
                                model: Settings.extruderSteps
                                delegate: Item {
                                    id: ex
                                    required property var modelData
                                    width: 52
                                    height: Metrics.controlHeight - 4
                                    Rectangle {
                                        anchors.fill: parent
                                        radius: Metrics.radiusSmall
                                        color: root.extAmount === ex.modelData ? Colors.selectedFill
                                             : (exma.containsMouse ? Colors.hoverFill : "transparent")
                                        border.width: root.extAmount === ex.modelData ? Metrics.borderWidth : 0
                                        border.color: Colors.alpha(Colors.accent, 0.5)
                                    }
                                    Text {
                                        anchors.centerIn: parent
                                        text: String(ex.modelData) + "mm"
                                        font.family: Type.family
                                        font.pixelSize: Type.sizeSmall
                                        font.bold: true
                                        color: root.extAmount === ex.modelData ? Colors.accent : Colors.surfaceVariantText
                                    }
                                    MouseArea {
                                        id: exma
                                        anchors.fill: parent
                                        acceptedButtons: Qt.LeftButton
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: root.extAmount = Number(ex.modelData)
                                    }
                                }
                            }
                        }
                    }
                }
            }

            // MACROS
            Column {
                visible: parent.bodyVisible && pid === "macros"
                anchors.left: parent.left
                anchors.leftMargin: Metrics.panelPadding
                anchors.right: parent.right
                anchors.rightMargin: Metrics.panelPadding
                anchors.top: parent.top
                anchors.topMargin: parent.bodyTop
                spacing: Metrics.md

                Item {
                    visible: root.cardMacros.length === 0
                    width: parent.width
                    height: Metrics.controlHeight
                    Text {
                        anchors.centerIn: parent
                        width: parent.width
                        text: root.macros.length === 0 ? "no gcode macros found"
                                                       : "every macro is hidden in settings"
                        font.family: Type.family
                        font.pixelSize: Type.sizeSmall
                        color: Colors.textTertiary
                        horizontalAlignment: Text.AlignHCenter
                        wrapMode: Text.Wrap
                    }
                }
                Flow {
                    width: parent.width
                    spacing: Metrics.sm
                    Repeater {
                        model: root.cardMacros
                        delegate: Button {
                            required property var modelData
                            width: root._macroChipW(String(modelData))
                            height: Metrics.controlHeight
                            text: String(modelData)
                            icon: Icons.gcode
                            variant: "plain"
                            onPressed: root.run(String(modelData))
                        }
                    }
                }
            }

            // MACHINE
            Column {
                visible: parent.bodyVisible && pid === "machine"
                anchors.left: parent.left
                anchors.leftMargin: Metrics.panelPadding
                anchors.right: parent.right
                anchors.rightMargin: Metrics.panelPadding
                anchors.top: parent.top
                anchors.topMargin: parent.bodyTop
                spacing: Metrics.md

                // Klipper keeps the last M117 on display_status after a job
                // ends, so an idle machine read "Preparing to Print..." for as
                // long as the shell was open.
                Text {
                    visible: root.jobActive && root.machineMessage() !== ""
                    width: parent.width
                    text: root.machineMessage()
                    font.family: Type.family
                    font.pixelSize: Type.sizeBody
                    font.bold: true
                    color: Colors.textPrimary
                    wrapMode: Text.Wrap
                    maximumLineCount: 2
                    elide: Text.ElideRight
                }
                Rectangle { width: parent.width; height: 1; color: Colors.separator }
                Repeater {
                    model: root.limits
                    delegate: Item {
                        required property var modelData
                        required property int index
                        width: parent ? parent.width : 0
                        height: 26
                        Text {
                            anchors.left: parent.left
                            anchors.verticalCenter: parent.verticalCenter
                            width: parent.width - 104
                            text: modelData.label
                            font.family: Type.family
                            font.pixelSize: Type.sizeSmall
                            font.bold: true
                            font.letterSpacing: 0.9
                            color: Colors.textTertiary
                            elide: Text.ElideRight
                        }
                        Rectangle {
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            width: 96
                            height: 24
                            radius: 0
                            color: lim.activeFocus ? Colors.accentDim : Colors.surfaceContainerHighest
                            border.width: lim.activeFocus ? 1 : 0
                            border.color: Colors.accent
                            TextInput {
                                id: lim
                                anchors.fill: parent
                                anchors.leftMargin: 8
                                anchors.rightMargin: 48
                                verticalAlignment: Text.AlignVCenter
                                readonly property string live: root.limitDisplay(index)
                                Component.onCompleted: text = live
                                onLiveChanged: if (!activeFocus) text = live
                                onActiveFocusChanged: {
                                    if (activeFocus) {
                                        TextFocus.acquire(this)
                                        selectAll()
                                    } else {
                                        TextFocus.release(this)
                                        text = live
                                    }
                                }
                                Keys.onEscapePressed: focus = false
                                font.family: Type.family
                                font.pixelSize: Type.sizeSmall
                                color: Colors.textPrimary
                                inputMethodHints: Qt.ImhFormattedNumbersOnly
                                property bool _committing: false
                                onEditingFinished: {
                                    if (_committing) return
                                    _committing = true
                                    root.applyLimit(index, text)
                                    focus = false
                                    _committing = false
                                }
                            }
                            Text {
                                anchors.right: parent.right
                                anchors.rightMargin: 6
                                anchors.verticalCenter: parent.verticalCenter
                                text: modelData.unit
                                font.family: Type.family
                                font.pixelSize: Type.sizeCaption
                                color: Colors.textTertiary
                            }
                        }
                    }
                }
            }

            // CONSOLE
            Column {
                visible: parent.bodyVisible && pid === "console"
                anchors.left: parent.left
                anchors.leftMargin: Metrics.panelPadding
                anchors.right: parent.right
                anchors.rightMargin: Metrics.panelPadding
                anchors.top: parent.top
                anchors.topMargin: parent.bodyTop
                spacing: Metrics.md

                Row {
                    width: parent.width
                    height: Metrics.controlHeight
                    spacing: Metrics.sm
                    Item {
                        width: parent.width - 88 - Metrics.sm
                        height: Metrics.controlHeight
                        Rectangle {
                            anchors.fill: parent
                            radius: 0
                            color: root.consoleActive ? Colors.accentDim : Colors.surfaceContainerHighest
                            border.width: root.consoleActive ? 1 : 0
                            border.color: Colors.accent
                        }
                        Text {
                            anchors.left: parent.left
                            anchors.leftMargin: 12
                            anchors.right: parent.right
                            anchors.rightMargin: 96
                            anchors.verticalCenter: parent.verticalCenter
                            text: "> " + root.pending + "▌"
                            font.family: Type.family
                            font.pixelSize: Type.sizeBody
                            font.bold: root.consoleActive
                            color: root.consoleActive ? Colors.textPrimary : Colors.outlineVariant
                            elide: Text.ElideRight
                        }
                        Text {
                            anchors.right: parent.right
                            anchors.rightMargin: 12
                            anchors.verticalCenter: parent.verticalCenter
                            text: root.consoleActive ? "enter sends" : "click + type"
                            font.family: Type.family
                            font.pixelSize: Type.sizeCaption
                            color: Colors.textTertiary
                        }
                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.IBeamCursor
                            onClicked: root.consoleActive = true
                        }
                    }
                    Button {
                        text: "SEND"
                        variant: "soft"
                        width: 88
                        height: Metrics.controlHeight
                        onPressed: root.consoleSend()
                    }
                }
                Rectangle { width: parent.width; height: 1; color: Colors.separator }
                Flickable {
                    id: consoleScroll
                    width: parent.width
                    height: Math.max(0, root._consoleHeight() - root.consoleChromeH)
                    contentWidth: width
                    contentHeight: consoleList.height
                    clip: true
                    boundsBehavior: Flickable.StopAtBounds
                    property bool pinBottom: true
                    onContentHeightChanged: if (consoleScroll.pinBottom)
                        consoleScroll.contentY = Math.max(0, consoleScroll.contentHeight - consoleScroll.height)
                    onContentYChanged: consoleScroll.pinBottom =
                        consoleScroll.contentY >= consoleScroll.contentHeight - consoleScroll.height - 2
                    Column {
                        id: consoleList
                        width: consoleScroll.width
                        spacing: Metrics.md
                        Repeater {
                            model: root.consoleLines
                            delegate: Rectangle {
                                required property var modelData
                                width: consoleList.width
                                height: 26
                                color: "transparent"
                                Text {
                                    anchors.left: parent.left
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: parent.width
                                    text: modelData ? modelData.message : ""
                                    font.family: Type.family
                                    font.pixelSize: Type.sizeBody
                                    color: modelData ? root.lineColor(modelData.type) : Colors.surfaceVariantText
                                    elide: Text.ElideRight
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // ── Header: print transport lives on the dashboard chrome, not in the
    // STATUS card, so the card's height only has to describe its own data.
    // Transport (left) + notification bell (right) sit in the empty band
    // above the first card — the whole chromeBand strip, which the Flickable
    // clips at its top so scrolled cards can never cover the controls. The
    // controls are centred in the band, so nothing moves when panel heights
    // change. Both are square, bold and icon-led: chrome, not card.
    readonly property int chromeBand: 30 + Metrics.panelMargin
    readonly property int transportH: 34
    property bool notifOpen: false
    readonly property int notifRows: Math.max(1, root.moonraker.notifications.length)
    readonly property int notifListH: Math.min(288, root.notifRows * 48)

    function toggleNotifications() {
        if (root.notifOpen) { root.closeNotifications(); return }
        root.moonraker.markNotificationsRead()
        root.notifOpen = true
    }
    function closeNotifications() {
        root.moonraker.markNotificationsRead()
        root.notifOpen = false
    }
    function notifGlyph(type) {
        if (type === "error") return Icons.error
        if (type === "warning") return Icons.warning
        return Icons.info
    }
    function notifColor(type) {
        if (type === "error") return Colors.error
        if (type === "warning") return Colors.tempWarm
        return Colors.textSecondary
    }
    function hhmm(t) {
        var d = new Date(Number(t) || 0)
        return ("0" + d.getHours()).slice(-2) + ":" + ("0" + d.getMinutes()).slice(-2)
    }

    Row {
        id: headerBar
        anchors.left: parent.left
        anchors.leftMargin: Metrics.panelMargin
        anchors.top: parent.top
        anchors.topMargin: Math.round((root.chromeBand - root.transportH) / 2)
        height: root.transportH
        spacing: Metrics.md

        Button { text: root.ps?.printState === "paused" ? "RESUME" : "PAUSE"
                 icon: root.ps?.printState === "paused" ? Icons.play : Icons.pause
                 variant: "plain"; height: root.transportH; rounded: false; bold: true
                 iconPixelSize: Type.iconStandalone; active: root.on && root.jobActive
                 onPressed: root.ps?.printState === "paused" ? root.moonraker.resumePrint() : root.moonraker.pausePrint() }
        Button { text: "CANCEL"; icon: Icons.stop; variant: "plain"; height: root.transportH
                 rounded: false; bold: true; iconPixelSize: Type.iconStandalone; active: root.on && root.jobActive
                 onPressed: root.askCancel() }
        Button { text: "E-STOP"; icon: Icons.power; variant: "danger"; solid: true; height: root.transportH
                 rounded: false; bold: true; iconPixelSize: Type.iconStandalone; active: root.on
                 onPressed: root.askEStop() }
    }

    Item {
        id: bellButton
        anchors.right: parent.right
        anchors.rightMargin: Metrics.panelMargin
        anchors.verticalCenter: headerBar.verticalCenter
        width: root.transportH
        height: root.transportH

        Button { anchors.fill: parent; text: ""; icon: Icons.bell; variant: "plain"
                 rounded: false; iconPixelSize: Type.iconLead
                 onPressed: root.toggleNotifications() }
        Rectangle {
            visible: root.moonraker.unread > 0 && !root.notifOpen
            anchors.right: parent.right
            anchors.rightMargin: -3
            anchors.top: parent.top
            anchors.topMargin: -3
            width: Math.max(18, countText.width + 8)
            height: 18
            color: Colors.error
            Text {
                id: countText
                anchors.centerIn: parent
                text: root.moonraker.unread > 99 ? "99+" : String(root.moonraker.unread)
                font.family: Type.family
                font.pixelSize: Type.sizeCaption
                font.bold: true
                color: Colors.errorText
            }
        }
    }

    // Notifications panel: the event log MoonrakerService keeps, newest first.
    Rectangle {
        visible: root.notifOpen
        z: 60
        anchors.fill: parent
        color: "transparent"
        MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.LeftButton
            onClicked: root.closeNotifications()
        }
    }
    Rectangle {
        visible: root.notifOpen
        z: 65
        anchors.top: headerBar.bottom
        anchors.topMargin: Metrics.md
        anchors.right: parent.right
        anchors.rightMargin: Metrics.panelMargin
        width: 380
        height: Metrics.lg * 2 + 24 + Metrics.sm + 1 + Metrics.sm + root.notifListH
        radius: 0
        color: Colors.surfaceContainerHigh
        border.width: Metrics.borderWidth
        border.color: Colors.outlineVariant

        Column {
            anchors.fill: parent
            anchors.margins: Metrics.lg
            spacing: Metrics.sm

            Item {
                width: parent.width
                height: 24

                Text {
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    text: Icons.bell + " NOTIFICATIONS"
                    font.family: Type.family
                    font.pixelSize: Type.sizeCaption
                    font.bold: true
                    font.letterSpacing: 1.0
                    color: Colors.textTertiary
                }
                Button {
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    width: 64
                    height: 24
                    text: "CLEAR"
                    variant: "plain"
                    rounded: false
                    active: root.moonraker.notifications.length > 0
                    onPressed: root.moonraker.clearNotifications()
                }
            }

            Rectangle { width: parent.width; height: 1; color: Colors.separator }

            Text {
                visible: root.moonraker.notifications.length === 0
                width: parent.width
                height: root.notifListH
                verticalAlignment: Text.AlignVCenter
                horizontalAlignment: Text.AlignHCenter
                text: "No printer events this session"
                font.family: Type.family
                font.pixelSize: Type.sizeSmall
                color: Colors.textTertiary
            }

            Flickable {
                visible: root.moonraker.notifications.length > 0
                width: parent.width
                height: root.notifListH
                contentHeight: notifList.height
                clip: true

                Column {
                    id: notifList
                    width: parent.width

                    Repeater {
                        model: root.moonraker.notifications
                        delegate: Item {
                            id: nrow
                            required property var modelData
                            width: parent ? parent.width : 0
                            height: 48

                            Rectangle {
                                anchors.fill: parent
                                color: nmouse.containsMouse ? Colors.hoverFill : "transparent"
                            }
                            Text {
                                anchors.left: parent.left
                                anchors.top: parent.top
                                anchors.topMargin: 6
                                text: root.notifGlyph(nrow.modelData.type)
                                font.family: Type.family
                                font.pixelSize: Type.sizeSmall
                                color: root.notifColor(nrow.modelData.type)
                            }
                            Text {
                                anchors.left: parent.left
                                anchors.leftMargin: 24
                                anchors.right: parent.right
                                anchors.rightMargin: 46
                                anchors.top: parent.top
                                anchors.topMargin: 4
                                text: nrow.modelData.title
                                font.family: Type.family
                                font.pixelSize: Type.sizeSmall
                                font.bold: true
                                color: root.notifColor(nrow.modelData.type)
                                elide: Text.ElideRight
                            }
                            Text {
                                anchors.left: parent.left
                                anchors.leftMargin: 24
                                anchors.right: parent.right
                                anchors.rightMargin: 46
                                anchors.top: parent.top
                                anchors.topMargin: 25
                                text: nrow.modelData.detail
                                font.family: Type.family
                                font.pixelSize: Type.sizeCaption
                                color: Colors.textSecondary
                                elide: Text.ElideRight
                            }
                            Text {
                                anchors.right: parent.right
                                anchors.top: parent.top
                                anchors.topMargin: 5
                                text: root.hhmm(nrow.modelData.time)
                                font.family: Type.family
                                font.pixelSize: Type.sizeCaption
                                color: Colors.textTertiary
                            }
                            MouseArea {
                                id: nmouse
                                anchors.fill: parent
                                hoverEnabled: true
                            }
                        }
                    }
                }
            }
        }
    }

    // ── Body ──────────────────────────────────────────────────────────
    Flickable {
        id: scroll
        ScrollRail { flickable: scroll }
        anchors.fill: parent
        anchors.topMargin: root.chromeBand
        clip: true
        contentWidth: width
        contentHeight: Math.max(height, body.implicitHeight + Metrics.panelMargin)

        Column {
            id: body
            x: Metrics.panelMargin
            y: 0
            width: parent.width - Metrics.panelMargin * 2
            spacing: Metrics.lg

            Row {
                width: parent.width
                height: root._gridHeight()
                spacing: Metrics.lg

                Column {
                    width: (parent.width - Metrics.lg) / 2
                    spacing: Metrics.lg
                    Repeater {
                        model: root._partition().left
                        delegate: root.panelDelegate
                    }
                }

                Column {
                    width: (parent.width - Metrics.lg) / 2
                    spacing: Metrics.lg
                    Repeater {
                        model: root._partition().right
                        delegate: root.panelDelegate
                    }
                }
            }
        }
    }

    // ── Bump font helpers / setters (kept on root for reuse) ─────────
    function fmt(v) {
        var n = Number(v)
        return Number.isNaN(n) ? "—" : (n.toFixed(n > 100 ? 0 : 1))
    }
    function dur(s) {
        var t = Number(s) || 0
        var m = Math.floor(t / 60)
        return (m < 10 ? "0" + m : m) + ":" + ("0" + Math.floor(t % 60)).slice(-2)
    }
    function remaining() {
        var d = Number(root.ps?.printDuration || 0)
        var p = Number(root.ps?.printProgress || 0)
        if (p <= 0.001) return "—"
        return root.dur(d / p - d)
    }
    function statusMeta() {
        if (!root.on) return "printer unreachable — retrying…"
        var s = root.ps?.printState
        var pct = root.fmt(root.ps.printProgress * 100) + "%"
        if (s === "printing") return "printing · elapsed " + root.dur(root.ps.printDuration)
            + " · left " + root.remaining() + " · " + pct
        if (s === "paused") return "paused · " + pct
        if (s === "complete") return "complete · " + root.dur(root.ps.printDuration)
        if (s === "error") return "error · " + pct
        if (s === "cancelled") return "cancelled"
        return pct
    }
    function fil(mm) {
        var n = Number(mm) || 0
        return n > 0 ? (n / 1000).toFixed(2) + "m" : "—"
    }
    function panelTitle(id) {
        if (id === "status") {
            var s = String(root.ps?.printState || "")
            if (s === "printing" || s === "paused") return s.toUpperCase()
            if (s === "standby" || s === "complete" || s === "cancelled" || s === "error") return s.toUpperCase()
            return "STATUS"
        }
        return root.labelFor(id)
    }
    function tempColor(c, t) {
        var tv = Number(t)
        if (!tv || tv <= 0) return Colors.surfaceVariantText
        var d = Math.abs(Number(c) - tv)
        if (d < 8) return Colors.tempHot
        if (d < 25) return Colors.tempWarm
        return Colors.tempCool
    }
    function stateColor(s) {
        if (s === "printing") return Colors.success
        if (s === "paused") return Colors.tempWarm
        if (s === "complete") return Colors.success
        if (s === "cancelled" || s === "error") return Colors.error
        if (s === "standby") return Colors.surfaceVariantText
        return Colors.accent
    }
    function klippyColor(s) {
        if (s === "ready") return Colors.success
        if (s === "error") return Colors.error
        if (s === "shutdown") return Colors.tempWarm
        return Colors.outlineVariant
    }
    property real jogDist: 1.0
    property int jogFeed: 40
    function jog(a, s, feed) { root.moonraker.jog(a, s * root.jogDist, feed || (s < 0 ? root.jogFeed * 0.6 : root.jogFeed)) }
    function axisPos(a) {
        if (a === "X") return root.ps?.toolheadX
        if (a === "Y") return root.ps?.toolheadY
        return root.ps?.toolheadZ
    }
    property int extAmount: 10
    property int extSpeed: 25
    function setHeaterTarget(key, target, delta) {
        root.moonraker.setHeaterTemp(key, Math.max(0, Number(target || 0) + delta))
    }
    function pct(v) { return Number.isNaN(Number(v)) ? "—" : Number(v).toFixed(1) + "%" }
    function memFmt(v) {
        var t = Number(v)
        if (Number.isNaN(t) || t === 0) return "—"
        return t >= 1073741824 ? (t / 1073741824).toFixed(1) + " GB" : (t / 1048576).toFixed(0) + " MB"
    }
    function extrudeRetract(sign) { root.moonraker.extrude(sign * root.extAmount, root.extSpeed) }
    function setPreset(name, ext, bed) {
        root.moonraker.sendGcode("SET_EXTRUDER_TEMPERATURE EXTRUDER " + ext)
        root.moonraker.sendGcode("SET_HEATER_TEMPERATURE HEATER_BED " + bed)
    }
    function askCancel() {
        if (!Settings.confirmCancel) { root.moonraker.cancelPrint(); return }
        if (root.confirmDialog) root.confirmDialog.ask("Cancel the current print?", {
            confirm: "CANCEL PRINT", destructive: true,
            onConfirm: function() { root.moonraker.cancelPrint() }
        })
    }
    function askEStop() {
        if (!Settings.confirmEStop) { root.moonraker.emergencyStop(); return }
        if (root.confirmDialog) root.confirmDialog.ask("Emergency stop — motors and heaters off immediately?", {
            confirm: "E-STOP", destructive: true,
            onConfirm: function() { root.moonraker.emergencyStop() }
        })
    }
    function askStartPrint(file) {
        if (!root.on || !file) return
        if (!Settings.confirmStart) { root.moonraker.startPrint(file); return }
        if (root.confirmDialog) root.confirmDialog.ask("Start printing \"" + file + "\"?", {
            confirm: "START PRINT",
            onConfirm: function() { root.moonraker.startPrint(file) }
        })
    }
    // SAVE_CONFIG restarts Klipper, which aborts an active print — the only
    // case worth a confirmation. Idle saves go straight through.
    function askSaveConfig() {
        if (!root.on) return
        var busy = root.ps?.printState === "printing" || root.ps?.printState === "paused"
        if (!busy) { root.moonraker.saveConfig(); return }
        if (root.confirmDialog) root.confirmDialog.ask("Save the config and restart Klipper? The current print will end.", {
            confirm: "SAVE & RESTART", destructive: true,
            onConfirm: function() { root.moonraker.saveConfig() }
        })
    }
}
