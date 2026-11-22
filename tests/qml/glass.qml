import QtQuick
import "../../ui/js/Contrast.js" as Contrast

// Run by tests/test_glass.py: qml6 -platform offscreen glass.qml -- theme=<need>,<accentNeed>,<fade>,<selection>,<hover>
// <name>=<bg>,<fg>,<accent> … The first holds Theme.qml's own numbers (read from it by the test).
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
        var first = args.indexOf("--") + 1
        var theme = args[first].slice(args[first].indexOf("=") + 1).split(",").map(parseFloat)
        var need = theme[0], accentNeed = theme[1], fade = theme[2], sel = theme[3], hov = theme[4]
        for (var i = first + 1; i < args.length; i++) {
            var eq = args[i].indexOf("="), parts = args[i].slice(eq + 1).split(",")
            var bg = Qt.color(parts[0]), fg = Qt.color(parts[1]), accent = Qt.color(parts[2])
            var surface = mix(bg, fg, 0.045)
            var muted = Contrast.ensure(mix(fg, bg, 0.35), surface, 4.5)
            // Theme.selection (the accent at 0.16) and Theme.hover (the foreground at 0.05).
            var washes = [Qt.rgba(accent.r, accent.g, accent.b, sel), Qt.rgba(fg.r, fg.g, fg.b, hov)]
            // As Theme.qml: the alpha from the unfaded material, the text lifted for a window Hyprland
            // fades to 0.96 (the `terminal` tag while an SSH tab is shown).
            var m = Contrast.material(bg, surface, fg, muted, washes, 0.75)
            var mf = Contrast.material(bg, surface, fg, muted, washes, 0.75, fade)
            // Transparent: no blur, so the bare desktop's white; Theme's 245 (0.96).
            var tf = Contrast.material(bg, surface, fg, muted, washes, 1, fade)
            // Through the fade with Theme's margins (fadedNeed, fadedAccentNeed).
            var kt = Contrast.inks(tf, 245, need)
            var a = Contrast.floor(m, 4.5)
            var k = Contrast.inks(mf, a, need)
            out[args[i].slice(0, eq)] = { alpha: a, background: hex(m.background), surface: hex(m.surface),
                                          foreground: hex(k.foreground), muted: hex(k.muted),
                                          accent: hex(Contrast.lift(mf, accent, a, accentNeed, true)),
                                          transparent: { foreground: hex(kt.foreground), muted: hex(kt.muted),
                                                         accent: hex(Contrast.lift(tf, accent, 245, accentNeed, true)) } }
        }
        console.log("RESULT " + JSON.stringify({ palettes: out, ms: Date.now() - started }))
        Qt.exit(0)
    }
}
