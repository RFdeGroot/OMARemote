import QtQuick
import "../../ui/js/Format.js" as Format

// Run by tests/test_quick.py: qml6 -platform offscreen format.qml. Prints one "RESULT {json}" line.
Item {
    Component.onCompleted: {
        var r = {}
        try {
            // Filled in for pc.acme.lan, then the address changes.
            r.same = Format.quickCredential("k1", "pc.acme.lan", "PC.acme.lan")
            r.other = Format.quickCredential("k1", "pc.acme.lan", "evil.example")
            // Picked by hand: kept whatever is typed.
            r.picked = Format.quickCredential("k1", "", "evil.example")
            r.none = Format.quickCredential("custom", "", "evil.example")
            // What the card does: the typed address through quickSpec, then quickCredential.
            var spec = Format.quickSpec("evil.example:3390", true)
            r.typed = Format.quickCredential("k1", "pc.acme.lan", spec.host)
            // Gliff stats lines (omaremote-gliff send_stats) into the bar's words.
            var ok = Format.parseStats("fps=60 mbit=42.3 decode=6.1 decoder=VA-API size=3668x2064 chroma=4:4:4 server=GPU cap=60 rtt=4 dev=1 health=ok why=")
            r.okParts = Format.statsParts(ok)
            r.okRows = Format.statsRows(ok)
            var warn = Format.parseStats("fps=3 mbit=0.1 decode=5.0 decoder=CPU size=1920x1080 chroma=4:2:0 server=CPU cap=15 rtt=-1 dev=0 health=warn why=congested")
            r.warnParts = Format.statsParts(warn)
            r.reconnecting = Format.statsParts(Format.parseStats("health=bad why=reconnecting"))
            r.odd = Format.parseStats("health=weird why=x").health
            r.noStats = Format.parseStats("")
            r.ports = Format.defaultPorts
            r.gliffAddress = Format.address({ protocol: "gliff", host: "pc.lan", port: 22 })
        } catch (e) {
            r.error = String(e)
        }
        console.log("RESULT " + JSON.stringify(r))
        Qt.exit(0)
    }
}
