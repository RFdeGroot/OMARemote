import QtQuick
import OMARemote

// Run by tests/test_search.py: qml6 -platform offscreen search.qml -- <socket>. An RdpView on a
// fake session: once attached it searches, steps up and down and ends the search; it notes every
// count the session says (and where its shell is), and prints them as one "RESULT {json}" line when the session hangs up.
Window {
    visible: true
    width: 400
    height: 300
    readonly property var args: Qt.application.arguments
    property var seen: []
    property var dirs: [] // workingDirectory as it changes
    property var bells: [] // [features, audio, volume] each ring
    property var progress: [] // [state, percent] each report

    RdpView {
        id: view
        anchors.fill: parent
        socketPath: args[args.length - 1]
        onAttachedChanged: {
            if (attached) {
                search("Ab ü")
                searchStep(true)
                searchStep(false)
                search("")
            } else if (seen.length) {
                done.start()
            }
        }
        onSearchChanged: seen.push([searchTotal, searchSelected])
        onWorkingDirectoryChanged: dirs.push(workingDirectory)
        onBell: function (features, audio, volume) { bells.push([features, audio, volume]) }
        onProgressChanged: progress.push([progressState, progressPercent])
    }
    Timer {
        id: done
        interval: 50
        onTriggered: {
            console.log("RESULT " + JSON.stringify({ seen: seen, dirs: dirs, bells: bells, progress: progress }))
            Qt.exit(0)
        }
    }
    Timer { interval: 15000; running: true; onTriggered: { console.log("RESULT {\"timeout\": true}"); Qt.exit(1) } }
}
