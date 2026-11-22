import QtQuick
import OMARemote

// Run by tests/test_ssh.py: qml6 -platform offscreen terminal.qml -- <socket> <alpha> <backdrop> <png> [late].
// An RdpView for a terminal (terminalAlpha) attached to a real omaremote-ssh, in front of a backdrop
// colour; once the picture has been shown a while, saves the window as <png> and quits. "late": the
// view starts as no terminal (-1) and is told 700 ms after the first frame, so a frame already mapped
// is read again in the other format (RdpView::setTerminalAlpha).
Window {
    id: win
    visible: true
    readonly property var args: Qt.application.arguments.slice(Qt.application.arguments.indexOf("--") + 1)
    readonly property bool late: args[4] === "late"
    width: 400
    height: 300
    color: "transparent"

    Item {
        id: scene
        anchors.fill: parent
        Rectangle { anchors.fill: parent; color: win.args[2] }
        RdpView {
            id: view
            anchors.fill: parent
            terminalAlpha: win.late ? -1 : parseInt(win.args[1])
            socketPath: win.args[0]
            // The size asked for (times the screen scale), not the session's first default frame.
            onRemoteSizeChanged: if (remoteSize.width >= 400 && remoteSize.width !== 1280) {
                if (win.late)
                    tell.start()
                else
                    done.restart()
            }
        }
    }

    Timer {
        id: tell
        interval: 700
        onTriggered: {
            view.terminalAlpha = parseInt(win.args[1])
            done.restart()
        }
    }
    Timer {
        id: done
        interval: 1500
        onTriggered: scene.grabToImage(function (result) {
            result.saveToFile(win.args[3])
            Qt.exit(0)
        })
    }
    Timer { running: true; interval: 15000; onTriggered: Qt.exit(1) }
}
