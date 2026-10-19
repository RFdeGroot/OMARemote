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
            r.unlock = {
                due: Format.unlockDue("rdp", 10, 10 * 60000),
                soon: Format.unlockDue("rdp", 10, 9 * 60000),
                off: Format.unlockDue("rdp", 0, 1e9),
                unset: Format.unlockDue("rdp", undefined, 1e9),
                text: Format.unlockDue("rdp", "10", 1e9),
                odd: Format.unlockDue("rdp", "x", 1e9),
                big: Format.unlockDue("rdp", 99999, 1e12),
                bool: Format.unlockDue("rdp", true, 1e9),
                vnc: Format.unlockDue("vnc", 10, 1e9),
                ssh: Format.unlockDue("ssh", 10, 1e9),
                gliff: Format.unlockDue("gliff", 10, 1e9)
            }
            var olds = [{ id: "old", connection: "c1", state: "connected", started: 100 },
                        { id: "other", connection: "c2", state: "connecting", started: 200 },
                        { id: "stale", connection: "c1", state: "ended", started: 50 }]
            var fresh = { id: "new", connection: "c1", state: "connecting", started: 200 }
            r.step = {
                none: Format.reconnectCandidate(olds, "c1", "old", 200000),
                found: Format.reconnectCandidate(olds.concat([fresh]), "c1", "old", 200000).id,
                // Newest first, as the list is: the first match wins.
                newest: Format.reconnectCandidate([{ id: "n2", connection: "c1", started: 201 }, fresh], "c1", "old", 200000).id,
                connecting: Format.reconnectStep(fresh, 200000, 201000),
                slow: Format.reconnectStep(fresh, 200000, 205000),
                connected: Format.reconnectStep({ state: "connected" }, 200000, 200500),
                failed: Format.reconnectStep({ state: "failed" }, 200000, 200500),
                missing: Format.reconnectStep(null, 200000, 210000),
                gone: Format.reconnectStep(null, 200000, 270000),
                // The old one, ended by Windows for the new sign-in, is no news; a lone failure is.
                replaced: Format.failureReplaced([fresh, { id: "old", connection: "c1", state: "failed", started: 100 }],
                                                 { id: "old", connection: "c1", state: "failed", started: 100 }),
                alone: Format.failureReplaced([{ id: "old", connection: "c1", state: "failed", started: 100 }],
                                              { id: "old", connection: "c1", state: "failed", started: 100 }),
                newFailed: Format.failureReplaced([{ id: "new", connection: "c1", state: "failed", started: 200 },
                                                   { id: "old", connection: "c1", state: "connected", started: 100 }],
                                                  { id: "new", connection: "c1", state: "failed", started: 200 }),
                ssh: Format.failureReplaced([{ id: "b", connection: "c1", protocol: "ssh", state: "connected", started: 200 }],
                                            { id: "a", connection: "c1", protocol: "ssh", state: "failed", started: 100 })
            }
        } catch (e) {
            r.error = String(e)
        }
        console.log("RESULT " + JSON.stringify(r))
        Qt.exit(0)
    }
}
