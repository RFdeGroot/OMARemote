import QtQuick
import OMARemote

// Run by tests/test_picture.py: qml6 -platform offscreen picture.qml -- <socket> <left> <width> <height>.
// An RdpView <left> from the window's edge, showing the fake session's frame; prints where the
// picture falls on the screen's pixels as one "RESULT {json}" line, and quits.
Window {
    visible: true
    readonly property var args: Qt.application.arguments
    width: 800
    height: 600

    RdpView {
        id: view
        x: parseInt(args[args.length - 3])
        width: parseInt(args[args.length - 2])
        height: parseInt(args[args.length - 1])
        socketPath: args[args.length - 4]
        onRemoteSizeChanged: done.start()
    }

    Timer {
        id: done
        interval: 50
        onTriggered: {
            const r = view.pictureOnScreen()
            console.log("RESULT " + JSON.stringify({ x: r.x, y: r.y, width: r.width, height: r.height }))
            Qt.exit(0)
        }
    }
    Timer { running: true; interval: 10000; onTriggered: Qt.exit(1) }
}
