pragma Singleton
import QtQuick

// Which text field is being edited, if any.
//
// Quickshell's window types are ProxyWindows and expose no `activeFocusItem` —
// reading `Window.activeFocusItem` from inside this shell always yields null.
// MainWindow used that null as "no text field has focus", which made its
// shortcut reclaimer grab active focus back every 200 ms: a field could hold
// focus for at most one tick, so nothing could be typed into any input in the
// app. The fields register themselves here instead, and the reclaimer asks the
// registered item whether it still holds focus — so a destroyed or hidden field
// reports nothing and the reclaimer keeps working.
QtObject {
    property Item current: null

    function acquire(item) {
        current = item
    }

    function release(item) {
        if (current === item) current = null
    }
}
