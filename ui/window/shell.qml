//@ pragma AppId omaremote-session
//@ pragma ShellId omaremote-window
//@ pragma NativeTextRendering

import Quickshell
import QtQuick

// One session in a window of its own (omaremote window <session-id>), a process apart from the
// manager so either can close without the other. The app id matches FreeRDP's own windows, so one
// Hyprland window rule covers both.
ShellRoot {
    FloatingWindow {
        id: window
        title: body.item ? body.item.title : "OMARemote"
        implicitWidth: 1280
        implicitHeight: 800
        color: "#101315"

        function quit() {
            Qt.quit()
        }

        // Closing the window (super+w) disconnects, as closing a tab does; moving to a tab does not.
        Connections {
            target: Quickshell
            function onLastWindowClosed() {
                if (body.item)
                    body.item.closing()
                window.quit()
            }
        }

        // Test hook, as in boot/shell.qml: OMAREMOTE_SNAPSHOT=<png> renders the window and quits.
        Timer {
            running: !!Quickshell.env("OMAREMOTE_SNAPSHOT")
            interval: parseInt(Quickshell.env("OMAREMOTE_SNAP_DELAY") || "2500")
            onTriggered: body.grabToImage(function (result) {
                result.saveToFile(Quickshell.env("OMAREMOTE_SNAPSHOT"))
                Qt.quit()
            })
        }

        Loader {
            id: body
            anchors.fill: parent
            focus: true
            Component.onCompleted: setSource("file://" + Quickshell.shellDir + "/../SessionWindow.qml", { host: window })
        }
    }
}
