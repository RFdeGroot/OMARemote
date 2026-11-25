import QtQuick
import OMARemote

// Run by tests/test_scrollbar.py: qml6 -platform offscreen scrollbar.qml -- <socket>. An RdpView on
// a fake session that sends `scrollbar` lines; asks for a row (scrollToRow) once it has two, and
// prints what it saw as one "RESULT {json}" line when the session hangs up.
Window {
    visible: true
    width: 400
    height: 300
    readonly property var args: Qt.application.arguments
    property var seen: []

    RdpView {
        id: view
        anchors.fill: parent
        socketPath: args[args.length - 1]
        onScrollbarChanged: {
            seen.push([scrollTotal, scrollOffset, scrollLength])
            if (seen.length === 2)
                scrollToRow(7)
        }
        onAttachedChanged: if (!attached && seen.length) done.start()
    }
    Timer {
        id: done
        interval: 50
        onTriggered: {
            console.log("RESULT " + JSON.stringify({ seen: seen }))
            Qt.exit(0)
        }
    }
    Timer { interval: 15000; running: true; onTriggered: { console.log("RESULT {\"timeout\": true}"); Qt.exit(1) } }
}
