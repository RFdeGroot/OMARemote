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
        // Shown once the body has the theme, so it never shows the default colours first; after a
        // second it shows whatever the theme files do (missing, unreadable, never ending). Until it
        // shows, a second `omaremote` does not find it (running_pid asks hyprctl for mapped windows).
        visible: (body.item && body.item.showable) || themeWait.over

        Timer {
            id: themeWait
            interval: 1000
            running: true
            property bool over: false
            onTriggered: over = true
        }

        // Qt.quit() ends Quickshell cleanly (exit code 0); killing the process instead made a
        // shell print "Terminated" after closing the window.
        function quit() {
            Qt.quit()
        }

        Connections {
            target: Quickshell
            // Closing it (super+w) ends what it shows, its tabs, as closing an own window ends
            // that one's session; own and hotkey windows run on. A restart for an update goes
            // through quit() instead, and its tabs come back.
            function onLastWindowClosed() {
                if (body.item)
                    body.item.closing()
                window.quit()
            }
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
