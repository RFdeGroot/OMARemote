import QtQuick
import OMARemote

// Run by tests/test_clipboard.py: qml6 -platform offscreen clipboard.qml -- <socket> <share 0|1> <ms> <mode>.
// mode "away": the view loses the keyboard at 600 ms and gets it back 300 ms before the end;
// "copy-away": the same, with a copy elsewhere on the desktop at 1200 ms; "copy-return-away": the
// copy elsewhere arrives just after the view gets the keyboard back (Wayland sends the selection
// around the keyboard's arrival); anything else: focused. A mode with "vnc" in it attaches as VNC
// does (offerAtConnect off), "quiet" has no copy on the desktop at 400 ms, "late" turns offerAtConnect
// on at 800 ms, "shareoff" turns sharing off at 800 ms, "detach" leaves the session at 800 ms and
// comes back 300 ms before the end, "early" has a copy on the desktop 250 ms before attaching.
// An RdpView attached to the test's fake session, focused, while the desktop clipboard changes;
// prints one "RESULT {json}" line after <ms> and quits.
Window {
    id: root
    visible: true
    width: 300
    height: 200
    readonly property var args: Qt.application.arguments
    property int ticks: 0

    // Writes and reads the desktop clipboard as another app would (offscreen: in this process).
    TextInput { id: source }
    TextInput { id: sink }

    RdpView {
        id: view
        anchors.fill: parent
        shareClipboard: root.args[root.args.length - 3] === "1"
        withholdPasswords: root.args[root.args.length - 1].startsWith("withhold")
        offerAtConnect: root.args[root.args.length - 1].indexOf("vnc") < 0
    }

    function done() {
        sink.text = ""
        sink.paste()
        console.log("RESULT " + JSON.stringify({ focused: view.activeFocus, attached: view.attached,
                                                 clipboard: sink.text, ticks: ticks,
                                                 cursors: view.cachedCursors(), whileAway: root.whileAway,
                                                 remote: [view.remoteSize.width, view.remoteSize.height] }))
        Qt.exit(0)
    }

    // The event loop keeps turning while the clipboard is read (wl-paste runs on its own).
    Timer { running: true; repeat: true; interval: 100; onTriggered: root.ticks++ }

    Timer {
        running: true
        interval: 50
        onTriggered: {
            root.requestActivate()
            view.forceActiveFocus()
            if (root.mode.indexOf("early") >= 0) {
                source.text = "copied before attaching"
                source.selectAll()
                source.copy()
                attachLater.start()
            } else {
                view.socketPath = root.args[root.args.length - 4]
            }
            if (root.mode.indexOf("quiet") < 0)
                change.start()
        }
    }
    Timer { id: attachLater; interval: 250; onTriggered: view.socketPath = root.args[root.args.length - 4] }
    // A copy elsewhere on the desktop while the session has the keyboard.
    Timer { id: change; interval: 400; onTriggered: { source.text = "copied"; source.selectAll(); source.copy() } }
    readonly property string mode: root.args[root.args.length - 1]
    readonly property int ms: parseInt(root.args[root.args.length - 2])
    property string whileAway: ""
    Timer { running: root.mode.endsWith("away"); interval: 600; onTriggered: sink.forceActiveFocus() }
    Timer {
        running: root.mode === "copy-away"
        interval: 1200
        onTriggered: { source.text = "copied later"; source.selectAll(); source.copy() }
    }
    Timer {
        running: root.mode.endsWith("away")
        interval: root.ms - 300
        onTriggered: {
            sink.text = ""
            sink.paste()
            root.whileAway = sink.text
            view.forceActiveFocus()
            if (root.mode === "copy-return-away") {
                source.text = "copied on return"
                source.selectAll()
                source.copy()
                view.forceActiveFocus()
            }
        }
    }
    Timer { running: root.mode.indexOf("late") >= 0; interval: 800; onTriggered: view.offerAtConnect = true }
    Timer { running: root.mode.indexOf("shareoff") >= 0; interval: 800; onTriggered: view.shareClipboard = false }
    Timer { running: root.mode.indexOf("detach") >= 0; interval: 800; onTriggered: view.socketPath = "" }
    Timer {
        running: root.mode.indexOf("detach") >= 0
        interval: root.ms - 300
        onTriggered: view.socketPath = root.args[root.args.length - 4]
    }
    Timer { running: true; interval: root.ms; onTriggered: root.done() }
}
