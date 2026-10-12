pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// Hotkey windows: connections kept on a special workspace of their own, shown and hidden by a
// shortcut (omaremote toggle). This holds the limit, checks a shortcut against the others and
// against what Hyprland binds already, and keeps ~/.config/hypr/omaremote.lua in step when
// Settings › Hotkeys allows it (hypr-hotkeys in bin/omaremote-session does the writing).
Singleton {
    id: root

    readonly property int limit: 5
    // Settings › Hotkeys › "Write the shortcuts into Hyprland's config" (off unless switched on).
    readonly property bool writeConfig: !!Store.ui.hyprHotkeys
    // on, off, or unsupported (no ~/.config/hypr/hyprland.lua): what the writer last found.
    property string mode: "off"
    // With a read-only hyprland.lua: the line that loads omaremote.lua, for the user to add.
    property string loaderLine: ""
    // What Hyprland binds now, but OMARemote's own: [{mask, key, description}].
    property var hyprBinds: []

    readonly property var hotkeyConnections: Store.connections.filter(function (c) {
        return c.openIn === "hotkey" && c.protocol !== "vnc"
    })

    // As `hyprctl binds -j` counts modifiers.
    readonly property var mods: ({ SHIFT: 1, CAPS: 2, CTRL: 4, CONTROL: 4, ALT: 8, MOD2: 16, MOD3: 32,
                                   SUPER: 64, WIN: 64, LOGO: 64, MOD4: 64, MOD5: 128 })

    // "super + alt + w" -> { mask: 72, key: "W", text: "SUPER + ALT + W" }; null when it is not one.
    function parse(text) {
        var parts = String(text || "").replace(/,/g, "+").split("+").map(function (p) { return p.trim().toUpperCase() })
                                      .filter(function (p) { return p !== "" })
        if (parts.length === 0)
            return null
        var mask = 0
        for (var i = 0; i < parts.length - 1; i++) {
            if (mods[parts[i]] === undefined)
                return null
            mask |= mods[parts[i]]
        }
        var key = parts[parts.length - 1]
        if (mods[key] !== undefined)
            return null
        return { mask: mask, key: key, text: parts.join(" + ") }
    }

    // Why a shortcut cannot be used for connection `id`, or "".
    function conflict(text, id) {
        var want = parse(text)
        if (!want)
            return String(text || "").trim() === "" ? "" : "Not a shortcut: modifiers, then a key (SUPER + ALT + W)"
        if (want.mask === 0)
            return "Add a modifier (SUPER, ALT, CTRL): a key alone would be taken everywhere"
        var list = hotkeyConnections
        for (var i = 0; i < list.length; i++) {
            var other = parse(list[i].hotkey)
            if (list[i].id !== id && other && other.mask === want.mask && other.key === want.key)
                return "Used by " + (list[i].name || list[i].host) + " already"
        }
        for (var j = 0; j < hyprBinds.length; j++) {
            var b = hyprBinds[j]
            if (b.mask === want.mask && b.key === want.key)
                return "Hyprland uses it already: " + (b.description || "a binding")
        }
        return ""
    }

    // Hotkey windows other than `id`: the limit counts these.
    function countOthers(id) {
        return hotkeyConnections.filter(function (c) { return c.id !== id }).length
    }

    function refresh() {
        if (!bindsReader.running)
            bindsReader.running = true
    }
    Component.onCompleted: refresh()

    Process {
        id: bindsReader
        command: [Sessions.bin, "hotkeys"]
        stdout: StdioCollector { id: bindsOut; waitForEnd: true }
        onExited: {
            try {
                root.hyprBinds = JSON.parse(bindsOut.text) || []
            } catch (e) {
                root.hyprBinds = []
            }
        }
    }

    // The bindings file follows the connections and the setting, a moment after they change.
    Connections {
        target: Store
        function onStoredChanged() { writer.restart() }
        function onUiChanged() { writer.restart() }
        function onLoadedChanged() { writer.restart() }
    }
    Timer {
        id: writer
        interval: 800
        onTriggered: if (Store.loaded && !hyprWriter.running) hyprWriter.running = true
    }
    Process {
        id: hyprWriter
        command: [Sessions.bin, "hypr-hotkeys"]
        stdout: StdioCollector { id: hyprOut; waitForEnd: true }
        onExited: {
            try {
                var r = JSON.parse(hyprOut.text)
                if (r.error) {
                    Sync.notice("Could not update Hyprland's config: " + r.error, true)
                    // Taken out again because Hyprland rejected it: switched off, so the next
                    // change does not try the same again.
                    if (r.revert && root.writeConfig)
                        Store.setUi("hyprHotkeys", false)
                } else {
                    root.mode = r.mode
                    root.loaderLine = r.line || ""
                    if (r.changed)
                        root.refresh()
                }
            } catch (e) {
            }
        }
    }
}
