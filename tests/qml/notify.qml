import QtQuick
import OMARemote

// Run by tests/test_notify.py: qml6 -platform offscreen notify.qml, on a private D-Bus with a
// stand-in notification server. Sends two notifications, notes which keys a click comes back
// for, takes the first back, and prints one "RESULT {json}" line.
Item {
    property var clicks: [] // the keys activated came back with
    Notifier {
        id: notifier
        onActivated: function (key) { clicks.push(key) }
    }
    Timer {
        interval: 500 // the server's capabilities are in
        running: true
        onTriggered: {
            notifier.notify("s1", "Build", "a <b>&c</b>\u0007 done", -1)
            notifier.notify("s2", "click me", "", 3000)
            later.start()
        }
    }
    Timer {
        id: later
        interval: 1500
        onTriggered: { notifier.close("s1"); done.start() }
    }
    Timer {
        id: done
        interval: 500
        onTriggered: { console.log("RESULT " + JSON.stringify({ activated: clicks })); Qt.exit(0) }
    }
}
