import QtQuick
import "../../ui/js/Contrast.js" as Contrast

// Run by tests/test_glass.py: qml6 -platform offscreen glass.qml -- <name>=<bg>,<fg>,<accent> …
// For each palette, the material Theme.qml builds (surface and muted the way it mixes them), the
// glass alpha and the lifted inks; prints one "RESULT {json}" line and quits.
Item {
    function mix(a, b, t) {
        return Qt.rgba(a.r + (b.r - a.r) * t, a.g + (b.g - a.g) * t, a.b + (b.b - a.b) * t, 1)
    }
    function hex(c) {
        var h = function (v) { return ("0" + Math.round(v * 255).toString(16)).slice(-2) }
        return "#" + h(c.r) + h(c.g) + h(c.b)
    }

    Component.onCompleted: {
        var args = Qt.application.arguments, out = {}, started = Date.now()
        for (var i = args.indexOf("--") + 1; i < args.length; i++) {
            var eq = args[i].indexOf("="), parts = args[i].slice(eq + 1).split(",")
            var bg = Qt.color(parts[0]), fg = Qt.color(parts[1]), accent = Qt.color(parts[2])
            var surface = mix(bg, fg, 0.045)
            var muted = Contrast.ensure(mix(fg, bg, 0.35), surface, 4.5)
            // Theme.selection (the accent at 0.16) and Theme.hover (the foreground at 0.05).
            var washes = [Qt.rgba(accent.r, accent.g, accent.b, 0.16), Qt.rgba(fg.r, fg.g, fg.b, 0.05)]
            // As Theme.qml: the alpha from the unfaded material, the text lifted for a window Hyprland
            // fades to 0.96 (the `terminal` tag while an SSH tab is shown).
            var m = Contrast.material(bg, surface, fg, muted, washes, 0.75)
            var mf = Contrast.material(bg, surface, fg, muted, washes, 0.75, 0.96)
            // Transparent: no blur, so the bare desktop's white; Theme's 245 (0.96).
            var tf = Contrast.material(bg, surface, fg, muted, washes, 1, 0.96)
            var kt = Contrast.inks(tf, 245, 4.5)
            var a = Contrast.floor(m, 4.5)
            var k = Contrast.inks(mf, a, 4.5)
            out[args[i].slice(0, eq)] = { alpha: a, background: hex(m.background), surface: hex(m.surface),
                                          foreground: hex(k.foreground), muted: hex(k.muted),
                                          accent: hex(Contrast.lift(mf, accent, a, 3, true)),
                                          transparent: { foreground: hex(kt.foreground), muted: hex(kt.muted),
                                                         accent: hex(Contrast.lift(tf, accent, 245, 3, true)) } }
        }
        console.log("RESULT " + JSON.stringify({ palettes: out, ms: Date.now() - started }))
        Qt.exit(0)
    }
}
