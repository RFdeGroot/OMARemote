pragma Singleton

import QtQuick
import Quickshell

// The one key table. Body.qml dispatches the list, sidebar and app keys through match(), and the
// keymap sheet (?) draws every row from here, so a key cannot be advertised without working or
// work without being advertised. Rows with run: false are handled where they live (editors, the
// session view, the log) and are listed for reference.
Singleton {
    id: root

    // context: where the key works.
    //   list     the connections list has focus
    //   sidebar  the sidebar has focus
    //   app      anywhere outside a session and outside text entry
    //   session  inside a remote desktop (always Ctrl+Alt, everything else goes to Windows)
    //   form     an editor (connection, group, credential set)
    //   log      the log viewer
    readonly property var bindings: [
        // Connections
        { group: "Connections", context: "list", action: "connect", keys: ["return", "enter"], label: "Connect, or switch to its session" },
        { group: "Connections", context: "list", action: "down", keys: ["j", "down"], label: "Next connection" },
        { group: "Connections", context: "list", action: "up", keys: ["k", "up"], label: "Previous connection" },
        { group: "Connections", context: "list", action: "first", keys: ["g", "home"], label: "First connection" },
        { group: "Connections", context: "list", action: "last", keys: ["shift+g", "end"], label: "Last connection" },
        { group: "Connections", context: "list", action: "new", keys: ["n", "ctrl+n"], label: "New connection" },
        { group: "Connections", context: "list", action: "edit", keys: ["e", "f2"], label: "Edit connection" },
        { group: "Connections", context: "list", action: "duplicate", keys: ["d"], label: "Duplicate connection" },
        { group: "Connections", context: "list", action: "delete", keys: ["delete", "x"], label: "Delete connection (press twice)" },
        { group: "Connections", context: "list", action: "favourite", keys: ["f"], label: "Toggle favourite" },
        { group: "Connections", context: "list", action: "log", keys: ["l"], label: "Log of the last session" },
        { group: "Connections", context: "list", action: "groupSettings", keys: ["s"], label: "Settings of its group" },
        { group: "Connections", context: "list", action: "search", keys: ["/", "ctrl+f"], label: "Search connections" },
        { group: "Connections", context: "list", action: "clear", keys: ["escape"], label: "Clear search, then filter" },

        // Views
        { group: "Views", context: "list", action: "filterAll", keys: ["1"], label: "All connections" },
        { group: "Views", context: "list", action: "filterFavourites", keys: ["2"], label: "Favourites" },
        { group: "Views", context: "list", action: "filterRecent", keys: ["3"], label: "Recent" },
        { group: "Views", context: "list", action: "filterActive", keys: ["4"], label: "Active sessions" },
        { group: "Views", context: "list", action: "focusSidebar", keys: ["tab"], label: "Move to the sidebar" },
        { group: "Views", context: "list", action: "newCredential", keys: ["c"], label: "New credential set" },

        // Sidebar
        { group: "Sidebar", context: "sidebar", action: "sidebarDown", keys: ["j", "down"], label: "Next entry" },
        { group: "Sidebar", context: "sidebar", action: "sidebarUp", keys: ["k", "up"], label: "Previous entry" },
        { group: "Sidebar", context: "sidebar", action: "sidebarOpen", keys: ["return", "enter", "l", "right"], label: "Open view, group or credential set" },
        { group: "Sidebar", context: "sidebar", action: "sidebarSettings", keys: ["s", "menu"], label: "Group settings" },
        { group: "Sidebar", context: "sidebar", action: "sidebarDismiss", keys: ["x", "delete"], label: "Hide the bar plugin offer (on it)" },
        { group: "Sidebar", context: "sidebar", action: "focusList", keys: ["tab", "escape", "h", "left"], label: "Back to the list" },

        // Tabs
        { group: "Tabs", context: "app", action: "nextTab", keys: ["ctrl+tab", "ctrl+pgdown"], label: "Next tab" },
        { group: "Tabs", context: "app", action: "previousTab", keys: ["ctrl+shift+tab", "ctrl+pgup"], label: "Previous tab" },
        { group: "Tabs", context: "app", action: "tabN", keys: ["alt+1…9"], label: "Go to tab 1–9", run: false },
        { group: "Tabs", context: "list", action: "pin", keys: ["p"], label: "Pin or unpin the connections list" },
        { group: "Tabs", context: "app", action: "pluginOffer", keys: [], label: "Show the bar plugin offer again" },
        { group: "Tabs", context: "app", action: "keys", keys: ["?", "f1"], label: "This keymap" },
        { group: "Tabs", context: "app", action: "quit", keys: ["ctrl+q"], label: "Quit OMARemote" },

        // In a session
        { group: "In a session", context: "session", action: "home", keys: ["ctrl+alt+home"], label: "Back to connections", run: false },
        { group: "In a session", context: "session", action: "nextTab", keys: ["ctrl+alt+pgdown"], label: "Next tab", run: false },
        { group: "In a session", context: "session", action: "previousTab", keys: ["ctrl+alt+pgup"], label: "Previous tab", run: false },
        { group: "In a session", context: "session", action: "cad", keys: ["ctrl+alt+end"], label: "Send Ctrl+Alt+Del", run: false },
        { group: "In a session", context: "session", action: "fullscreen", keys: ["ctrl+alt+return"], label: "Fullscreen", run: false },
        { group: "In a session", context: "session", action: "popOut", keys: ["ctrl+alt+o"], label: "Move to its own window", run: false },
        { group: "In a session", context: "session", action: "toTab", keys: ["ctrl+alt+t"], label: "Own window: back into a tab", run: false },
        { group: "In a session", context: "session", action: "toConnections", keys: ["ctrl+alt+home"], label: "Own window: into a tab, connections forward", run: false },
        { group: "In a session", context: "session", action: "pin", keys: ["ctrl+alt+p"], label: "Pin or unpin the connections list", run: false },
        { group: "In a session", context: "session", action: "keys", keys: ["ctrl+alt+k"], label: "This keymap", run: false },

        // Editors
        { group: "Editors", context: "form", action: "nextField", keys: ["tab"], label: "Next field", run: false },
        { group: "Editors", context: "form", action: "previousField", keys: ["shift+tab"], label: "Previous field", run: false },
        { group: "Editors", context: "form", action: "choose", keys: ["left", "right"], label: "Choose an option", run: false },
        { group: "Editors", context: "form", action: "toggle", keys: ["space"], label: "Toggle a switch, open a list", run: false },
        { group: "Editors", context: "form", action: "save", keys: ["ctrl+s"], label: "Save", run: false },
        { group: "Editors", context: "form", action: "cancel", keys: ["escape"], label: "Cancel", run: false },

        // Log
        { group: "Log", context: "log", action: "problems", keys: ["w"], label: "Warnings and errors only", run: false },
        { group: "Log", context: "log", action: "scroll", keys: ["j", "k"], label: "Scroll", run: false },
        { group: "Log", context: "log", action: "ends", keys: ["g", "shift+g"], label: "Top, end", run: false },
        { group: "Log", context: "log", action: "close", keys: ["escape"], label: "Close", run: false }
    ]

    readonly property var groups: {
        var out = []
        for (var i = 0; i < bindings.length; i++)
            if (out.indexOf(bindings[i].group) < 0)
                out.push(bindings[i].group)
        return out
    }

    readonly property var keyNames: ({
        "return": Qt.Key_Return, "enter": Qt.Key_Enter, "escape": Qt.Key_Escape, "tab": Qt.Key_Tab,
        "space": Qt.Key_Space, "delete": Qt.Key_Delete, "home": Qt.Key_Home, "end": Qt.Key_End,
        "pgup": Qt.Key_PageUp, "pgdown": Qt.Key_PageDown, "up": Qt.Key_Up, "down": Qt.Key_Down,
        "left": Qt.Key_Left, "right": Qt.Key_Right, "menu": Qt.Key_Menu, "f1": Qt.Key_F1, "f2": Qt.Key_F2,
        "/": Qt.Key_Slash, "?": Qt.Key_Question
    })

    // "ctrl+shift+tab" -> {key, ctrl, alt, shift}
    function parse(spec) {
        var parts = spec.split("+")
        var name = parts[parts.length - 1]
        var key = keyNames[name]
        if (key === undefined && name.length === 1)
            key = name.toUpperCase().charCodeAt(0) // Qt.Key_A..Z and Key_0..9 are their ASCII codes
        return { key: key, ctrl: parts.indexOf("ctrl") >= 0, alt: parts.indexOf("alt") >= 0, shift: parts.indexOf("shift") >= 0 }
    }

    // The action a key event means in a context, or "".
    function match(event, context) {
        var ctrl = (event.modifiers & Qt.ControlModifier) !== 0
        var alt = (event.modifiers & Qt.AltModifier) !== 0
        var shift = (event.modifiers & Qt.ShiftModifier) !== 0
        // Shift+Tab arrives as Backtab.
        var key = event.key === Qt.Key_Backtab ? Qt.Key_Tab : event.key
        if (event.key === Qt.Key_Backtab)
            shift = true
        for (var i = 0; i < bindings.length; i++) {
            var b = bindings[i]
            if (b.run === false || (b.context !== context && b.context !== "app"))
                continue
            for (var j = 0; j < b.keys.length; j++) {
                var k = parse(b.keys[j])
                // ? needs Shift on most layouts; the key itself says which.
                var shiftOk = k.key === Qt.Key_Question || k.shift === shift
                if (k.key === key && k.ctrl === ctrl && k.alt === alt && shiftOk)
                    return b.action
            }
        }
        return ""
    }

    // How a key is drawn on a cap: "ctrl+shift+tab" -> "Ctrl Shift Tab".
    function cap(spec) {
        var names = { "return": "⏎", "enter": "⏎", "escape": "Esc", "delete": "Del", "pgup": "PgUp",
                      "pgdown": "PgDn", "up": "↑", "down": "↓", "left": "←", "right": "→", "space": "Space",
                      "tab": "Tab", "home": "Home", "end": "End", "menu": "Menu", "f1": "F1", "f2": "F2",
                      "ctrl": "Ctrl", "alt": "Alt", "shift": "Shift" }
        return spec.split("+").map(function (p) { return names[p] || p }).join(" ")
    }

    // The caps of a row, the duplicate ⏎ of Return/Enter folded into one.
    function caps(b) {
        var out = []
        for (var i = 0; i < b.keys.length; i++) {
            var c = cap(b.keys[i])
            if (out.indexOf(c) < 0)
                out.push(c)
        }
        return out
    }
}
