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
        } catch (e) {
            r.error = String(e)
        }
        console.log("RESULT " + JSON.stringify(r))
        Qt.exit(0)
    }
}
