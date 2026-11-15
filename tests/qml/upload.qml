import QtQuick
import OMARemote

// Run by tests/test_upload.py: qml6 upload.qml -- <socket> <ppm>. A 64x48 RdpView pixel for pixel,
// showing the fake session's frame; 1.4 s in, saves what the window shows to <ppm> and quits.
Window {
    id: root
    visible: true
    readonly property var args: Qt.application.arguments
    width: 64
    height: 48
    color: "black"

    RdpView {
        anchors.fill: parent
        socketPath: root.args[root.args.length - 2]
    }

    Timer {
        running: true
        interval: 1400
        onTriggered: root.contentItem.grabToImage(function (result) {
            result.saveToFile(root.args[root.args.length - 1])
            Qt.exit(0)
        })
    }
    Timer { running: true; interval: 10000; onTriggered: Qt.exit(1) }
}
