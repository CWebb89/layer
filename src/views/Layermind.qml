pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Io
import "../theme"
import "../components"

// LayerMind diagnostics: reads the daemon's per-printer context snapshot at
// ~/.local/state/layermind/<printer>.json (matching klip-tui's naming where
// "Voron V2.4" -> voron24.json). Rendered defensively — the schema lives in
// the layermind-shared crate, so we surface scalars as key/value rows and
// the first array-of-strings field as a colored diagnostic feed (color is
// a keyword guess — error/warn/ok — not a schema-declared severity).
Item {
    id: root

    required property QtObject moonraker
    property var context: null
    property bool haveFile: false
    property var rows: []

    readonly property string printer: moonraker.activePrinter

    function snapshotPath() {
        var e = Quickshell.env("HOME")
        var home = (e && e !== "null") ? e : ""
        // The daemon's stem drops the model's version prefix: "Voron V2.4" ->
        // voron24.json, "Voron V0.2" -> voron02.json. Stripping every
        // non-alphanumeric character alone produced "voronv24", so the view
        // reported "no snapshot" for a file that was sitting right there.
        var stem = root.printer.toLowerCase().replace(/v(?=\d)/g, "").replace(/[^a-z0-9]/g, "")
        return home + "/.local/state/layermind/" + stem + ".json"
    }

    function refresh() { root._read() }

    function _read() {
        if (!root.printer) return
        var safe = root.snapshotPath().replace(/'/g, "'\\''")
        proc.command = ["bash", "-c", "cat '" + safe + "' 2>/dev/null || echo '{}'"]
        proc.running = false
        proc.running = true
    }

    property var proc: Process {
        command: []
        running: false
        stdout: StdioCollector {
            onStreamFinished: {
                var t = text.trim()
                root.haveFile = t !== "" && t !== "{}" && t !== "null"
                try {
                    root.context = JSON.parse(t)
                } catch (e) {
                    root.context = null
                    root.haveFile = false
                }
                root.render()
            }
        }
    }

    // Keyword guess only — LayerMind's schema doesn't declare a severity
    // field, so this reads the message text itself. Falls back to the
    // neutral text color for anything it doesn't recognize.
    function _lineColor(s) {
        var t = String(s).toLowerCase()
        if (t.indexOf("error") >= 0 || t.indexOf("fail") >= 0 || t.indexOf("critical") >= 0) return Colors.error
        if (t.indexOf("warn") >= 0 || t.indexOf("caution") >= 0 || t.indexOf("clog") >= 0) return Colors.tempWarm
        if (t.indexOf(" ok") >= 0 || t.indexOf("pass") >= 0 || t.indexOf("good") >= 0 || t.indexOf("complete") >= 0) return Colors.success
        return Colors.textPrimary
    }

    // The daemon writes an array holding one context object; the view was
    // written against a bare object, so a real snapshot parsed to `[]` and drew
    // no rows at all. Accept either shape, then walk the object one level deep:
    // every interesting field lives inside `summary` / `health` / `current_state`.
    function render() {
        var c = root.context
        if (Array.isArray(c)) c = c.length > 0 ? c[0] : null
        var out = []
        if (!c || typeof c !== "object") { root.rows = out; return }
        root._flatten(c, "", out, 30)
        if (out.length >= 30) out.push({ kind: "line", text: "… more fields not shown", color: Colors.textTertiary })
        var list = root._firstStringArray(c, 0)
        if (list !== null) {
            for (var i = 0; i < list.length && i < 8; i++) {
                var s = String(list[i])
                out.push({ kind: "line", text: s.charAt(0) === "-" ? s.slice(1).trim() : s, color: root._lineColor(s) })
            }
        }
        root.rows = out
    }

    function _flatten(o, prefix, out, cap) {
        for (var k in o) {
            if (k === "type" || k === "schema") continue
            var v = o[k]
            if (v === null || v === undefined) continue
            if (typeof v === "string" || typeof v === "number" || typeof v === "boolean") {
                if (out.length >= cap) return
                out.push({ kind: "kv", key: prefix + k, value: typeof v === "number" ? String(Math.round(v * 1000) / 1000) : String(v) })
            } else if (typeof v === "object" && !Array.isArray(v) && prefix === "") {
                root._flatten(v, k + ".", out, cap)
                if (out.length >= cap) return
            }
        }
    }

    function _firstStringArray(o, depth) {
        for (var k in o) {
            var v = o[k]
            if (Array.isArray(v) && v.length > 0 && typeof v[0] === "string") return v
        }
        if (depth >= 1) return null
        for (var kk in o) {
            var vv = o[kk]
            if (vv && typeof vv === "object" && !Array.isArray(vv)) {
                var found = root._firstStringArray(vv, depth + 1)
                if (found !== null) return found
            }
        }
        return null
    }

    property var reTimer: Timer {
        interval: 4000
        repeat: true
        running: true
        onTriggered: { if (root.visible) root._read() }
    }

    Column {
        anchors.fill: parent
        anchors.margins: Metrics.panelMargin

        Card {
            width: parent.width
            height: parent.height
            header: Icons.layermind + " LAYERMIND · DIAGNOSTICS"

            Column {
                anchors.left: parent.left
                anchors.leftMargin: Metrics.panelPadding
                anchors.right: parent.right
                anchors.rightMargin: Metrics.panelPadding
                anchors.top: parent.top
                anchors.topMargin: Metrics.panelPadding + 6
                spacing: Metrics.md

                Row {
                    width: parent.width
                    spacing: Metrics.sm
                    Rectangle {
                        width: 8
                        height: 8
                        radius: 4
                        anchors.verticalCenter: parent.verticalCenter
                        color: root.haveFile ? Colors.success : Colors.outlineVariant
                    }
                    Text {
                        text: root.printer || "no active printer"
                        font.family: Type.family
                        font.pixelSize: Type.sizeSmall
                        font.bold: true
                        color: Colors.textPrimary
                    }
                    Text {
                        text: root.haveFile ? "· snapshot live" : "· no snapshot"
                        font.family: Type.family
                        font.pixelSize: Type.sizeSmall
                        color: Colors.surfaceVariantText
                    }
                }

                Separator { visible: root.haveFile }

                Item {
                    visible: !root.haveFile
                    width: parent.width
                    height: 90
                    Rectangle {
                        anchors.fill: parent
                        radius: Metrics.radiusSmall
                        color: Colors.surfaceContainerLow
                        border.width: Metrics.borderWidth
                        border.color: Colors.outlineVariant
                    }
                    Text {
                        anchors.fill: parent
                        anchors.margins: Metrics.md
                        text: root.printer
                            ? "No LayerMind snapshot for '" + root.printer + "'\nExpected at:\n    "
                                + root.snapshotPath() + "\nStart the daemon and re-read with Enter."
                            : "No active printer."
                        font.family: Type.family
                        font.pixelSize: Type.sizeBody
                        color: Colors.surfaceVariantText
                        textFormat: Text.PlainText
                        wrapMode: Text.Wrap
                    }
                }

                Repeater {
                    model: root.rows
                    delegate: Item {
                        id: rowItem
                        required property var modelData
                        width: parent ? parent.width : 0
                        height: rowItem.modelData.kind === "line" ? 26 : 22

                        Row {
                            visible: rowItem.modelData.kind === "kv"
                            anchors.left: parent.left
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: Metrics.sm
                            Text {
                                width: 320
                                text: rowItem.modelData.key ?? ""
                                font.family: Type.family
                                font.pixelSize: Type.sizeSmall
                                color: Colors.surfaceVariantText
                                elide: Text.ElideRight
                            }
                            Text {
                                width: Math.max(60, (rowItem.width || 0) - 320 - Metrics.sm)
                                text: rowItem.modelData.value ?? ""
                                font.family: Type.family
                                font.pixelSize: Type.sizeSmall
                                font.bold: true
                                color: Colors.textPrimary
                                elide: Text.ElideRight
                            }
                        }

                        Rectangle {
                            visible: rowItem.modelData.kind === "line"
                            anchors.fill: parent
                            anchors.topMargin: 2
                            anchors.bottomMargin: 2
                            radius: Metrics.radiusSmall
                            color: Colors.alpha(rowItem.modelData.color, 0.08)
                        }
                        Row {
                            visible: rowItem.modelData.kind === "line"
                            anchors.left: parent.left
                            anchors.leftMargin: Metrics.sm
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: Metrics.sm
                            Rectangle {
                                width: 6
                                height: 6
                                radius: 3
                                anchors.verticalCenter: parent.verticalCenter
                                color: rowItem.modelData.color
                            }
                            Text {
                                width: (rowItem.width || 0) - Metrics.sm * 2 - 6 - Metrics.panelPadding * 2
                                text: rowItem.modelData.text ?? ""
                                font.family: Type.family
                                font.pixelSize: Type.sizeSmall
                                color: rowItem.modelData.color
                                elide: Text.ElideRight
                            }
                        }
                    }
                }
            }
        }
    }
}
