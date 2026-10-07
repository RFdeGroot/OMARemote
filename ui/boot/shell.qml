//@ pragma AppId omaremote
//@ pragma ShellId omaremote
//@ pragma NativeTextRendering

import Quickshell
import QtQuick

// The entry holds the window only; the body is loaded by file URL so it sits outside the qs: scheme,
// the same split Flea makes.
ShellRoot {
    FloatingWindow {
        id: window
        title: "OMARemote"
        implicitWidth: 1040
        implicitHeight: 640
        color: "#101315"

        // Quickshell 0.3.1 has no exit API, so the process ends itself the way Flea's does.
        function quit() {
            Quickshell.execDetached(["kill", String(Quickshell.processId)])
        }

        Connections {
            target: Quickshell
            function onLastWindowClosed() { window.quit() }
        }

        Loader {
            id: body
            anchors.fill: parent
            focus: true
            Component.onCompleted: setSource("file://" + Quickshell.shellDir + "/../Body.qml", { host: window })
        }

        // Test hook: OMAREMOTE_SNAPSHOT=<png> renders the window, saves it and quits;
        // OMAREMOTE_ACTIONS (space separated, see Body.debugAction) drives it there first.
        Timer {
            running: !!Quickshell.env("OMAREMOTE_SNAPSHOT")
            interval: 1500
            onTriggered: {
                var actions = String(Quickshell.env("OMAREMOTE_ACTIONS") || "").split(" ")
                for (var i = 0; i < actions.length; i++)
                    if (actions[i] && body.item)
                        body.item.debugAction(actions[i])
                snap.start()
            }
        }
        Timer {
            id: snap
            interval: parseInt(Quickshell.env("OMAREMOTE_SNAP_DELAY") || "600")
            onTriggered: body.grabToImage(function (result) {
                result.saveToFile(Quickshell.env("OMAREMOTE_SNAPSHOT"))
                window.quit()
            })
        }
    }
}
