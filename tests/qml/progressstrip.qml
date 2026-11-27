import QtQuick

// Run by tests/test_progress.py: qml6 -platform offscreen progressstrip.qml, with ProgressStrip
// and stand-ins for Theme and Util on the import path. Prints one "RESULT {json}" line: per state,
// whether it shows, the bar's width, whether the block slides, and its colour.
Item {
    width: 200
    height: 10
    ProgressStrip { id: strip; anchors.fill: parent }
    Component.onCompleted: {
        var out = {}
        var cases = [["", -1], ["set", 25], ["set", -1], ["error", 50], ["pause", 80], ["indeterminate", -1]]
        for (var i = 0; i < cases.length; i++) {
            strip.state_ = cases[i][0]
            strip.percent = cases[i][1]
            var bar = strip.children[1]
            out[cases[i][0] + ":" + cases[i][1]] = { shown: strip.visible, width: bar.visible ? bar.width : 0,
                                                     pulsing: strip.pulsing, ink: String(strip.ink),
                                                     opacity: strip.inkOpacity }
        }
        console.log("RESULT " + JSON.stringify(out))
        Qt.exit(0)
    }
}
