pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland

// Omarchy's Window Opacity mode (Appearance › Windows), as Flea reads it: a file test in the toggles
// folder, never the command (it needs OMARCHY_PATH, missing over ssh and from some launchers).
// window-glassy.lua is Glassy, window-opaque.lua Opaque, neither Transparent (Omarchy's default).
//
// Glassy and Transparent give the manager window's regions a see-through ground (Theme.ground), over
// Hyprland's blur in Glassy, and SSH tabs a see-through terminal background, as Omarchy's own
// terminals have; text is lifted to stay readable. Remote desktops (RDP, VNC, Gliff), the area
// around them, cards and menus stay opaque. Opaque draws everything solid. OMARemote never adds a
// Hyprland rule or tag of its own, which would fade the whole window, the remote desktop included.
//
// Both see-through modes need Omarchy 4.5 (its glass.lua): 4.0.6 has no toggle files, which would read
// as Transparent, and fades every window itself.
//
// Probed in the background (a process), so nothing waits on the disk; the window's surface is see-through
// from the start (boot/shell.qml), so a switch shows live, on Hyprland's configreloaded.
Singleton {
    id: root

    readonly property string toggles: (Quickshell.env("XDG_STATE_HOME") || Quickshell.env("HOME") + "/.local/state")
                                      + "/omarchy/toggles/hypr"

    readonly property string glassLua: (Quickshell.env("OMARCHY_PATH") || "/usr/share/omarchy") + "/default/hypr/glass.lua"
    readonly property string glassLuaHome: Quickshell.env("HOME") + "/.local/share/omarchy/default/hypr/glass.lua"

    // "glassy", "transparent" or "opaque", from Omarchy's files; opaque until the probe answers.
    property string found: "opaque"

    // Test hook: OMAREMOTE_GLASS=glassy|transparent|opaque draws that mode whatever the toggles say
    // (snapshots on any machine); 1 and 0 are glassy and opaque.
    readonly property string forced: ({ "1": "glassy", "0": "opaque", "glassy": "glassy", "transparent": "transparent",
                                        "opaque": "opaque" })[Quickshell.env("OMAREMOTE_GLASS") || ""] || ""
    readonly property string mode: forced || found
    readonly property bool glassy: mode === "glassy"
    readonly property bool transparent: mode === "transparent"

    // The default terminal's see-through background from its theme file (0.65 in Glassy, or the
    // theme's own), and Hyprland's blur brightness: omaremote-session terminal-glass. Omarchy's
    // values until it answers, or when the answer is odd.
    property real terminalOpacity: 0.65
    property real blurBrightness: 0.75

    // A reload (Hyprland's, or a theme switch: Theme.qml) during a read runs one more once it ends,
    // so the last switch always counts.
    property bool again: false
    property bool readAgain: false
    function reread() {
        if (probe.running)
            again = true
        else
            probe.running = true
        if (reader.running)
            readAgain = true
        else
            reader.running = true
    }

    Process {
        id: reader
        running: true
        // The helper Sessions.bin names, worked out here so Theme (through this) needs no Sessions.
        command: [Quickshell.env("OMAREMOTE_BIN") || (Quickshell.shellDir + "/../../bin/omaremote-session"), "terminal-glass"]
        stdout: StdioCollector { id: answer; waitForEnd: true }
        onExited: function (exitCode) {
            if (exitCode === 0) {
                try {
                    var a = JSON.parse(answer.text)
                    if (typeof a.opacity === "number" && a.opacity >= 0 && a.opacity <= 1)
                        root.terminalOpacity = a.opacity
                    if (typeof a.blur === "number" && a.blur > 0 && a.blur <= 2)
                        root.blurBrightness = a.blur
                } catch (e) {}
            }
            if (root.readAgain) {
                root.readAgain = false
                running = true
            }
        }
    }

    // Only whether the files are there, never their contents: test -f in a process of its own (a
    // FIFO, a device or a huge file in their place costs nothing), paths as arguments, not code.
    // Exit 10: glassy, 11: transparent, anything else (also no Omarchy 4.5): opaque. Glassy wins
    // over Opaque, as in Omarchy.
    Process {
        id: probe
        running: true
        command: ["sh", "-c", "{ test -f \"$3\" || test -f \"$4\"; } || exit 1; "
                  + "test -f \"$1\" && exit 10; test -f \"$2\" && exit 1; exit 11", "sh",
                  root.toggles + "/window-glassy.lua", root.toggles + "/window-opaque.lua", root.glassLua, root.glassLuaHome]
        onExited: function (exitCode) {
            root.found = exitCode === 10 ? "glassy" : exitCode === 11 ? "transparent" : "opaque"
            if (root.again) {
                root.again = false
                running = true
            }
        }
    }

    // A Window Opacity switch reloads Hyprland's config without a theme switch.
    Connections {
        target: Hyprland
        function onRawEvent(event) {
            if (event.name === "configreloaded")
                root.reread()
        }
    }
}
