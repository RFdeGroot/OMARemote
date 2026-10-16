import QtQuick
import OMARemote

// Run by tests/test_clipboard.py: qml6 -platform offscreen clipboard.qml -- <socket> <share 0|1> <ms>.
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
        shareClipboard: root.args[root.args.length - 2] === "1"
    }

    function done() {
        sink.text = ""
        sink.paste()
        console.log("RESULT " + JSON.stringify({ focused: view.activeFocus, attached: view.attached,
                                                 clipboard: sink.text, ticks: ticks,
                                                 cursors: view.cachedCursors() }))
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
            view.socketPath = root.args[root.args.length - 3]
            change.start()
        }
    }
    // A copy elsewhere on the desktop while the session has the keyboard.
    Timer { id: change; interval: 400; onTriggered: { source.text = "copied"; source.selectAll(); source.copy() } }
    Timer { running: true; interval: parseInt(root.args[root.args.length - 1]); onTriggered: root.done() }
}
