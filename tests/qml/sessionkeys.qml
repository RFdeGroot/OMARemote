import QtQuick
import "../../ui/js/Format.js" as Format

// Run by tests/test_session_keys.py: qml6 -platform offscreen sessionkeys.qml. Prints one
// "RESULT {json}" line.
Item {
    Component.onCompleted: {
        var r = {}
        try {
            var modes = ["ctrlalt", "rctrl", "ctrlaltshift", "bogus", undefined]
            var mods = { none: [false, false, false], ctrl: [true, false, false], ctrlalt: [true, true, false],
                         ctrlaltshift: [true, true, true] }
            r.chord = {}
            for (var i = 0; i < modes.length; i++) {
                var row = {}
                for (var m in mods)
                    for (var held = 0; held < 2; held++)
                        row[m + (held ? "+held" : "")] = Format.isSessionChord(modes[i], mods[m][0], mods[m][1], mods[m][2], !!held)
                r.chord[String(modes[i])] = row
            }
            r.spec = modes.map(function (m) {
                return [Format.sessionSpec(m, "ctrl+alt+home"), Format.sessionSpec(m, "ctrl+shift+c")]
            })
        } catch (e) {
            r.error = String(e)
        }
        console.log("RESULT " + JSON.stringify(r))
        Qt.exit(0)
    }
}
