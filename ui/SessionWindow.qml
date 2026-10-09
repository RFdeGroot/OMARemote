import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.Commons

// A session in a window of its own: a title bar, the session as a tab draws it (connecting, prompts,
// why it ended), and the keys that work here at the bottom. ctrl+alt+t hands it to a tab.
FocusScope {
    id: root
    property var host: null

    property string sessionId: Quickshell.env("OMAREMOTE_SESSION") || ""
    readonly property var session: {
        var list = Sessions.sessions
        for (var i = 0; i < list.length; i++)
            if (list[i].id === sessionId)
                return list[i]
        return null
    }
    readonly property bool live: !!session && Sessions.isActive(session)
    readonly property string title: session ? session.name : "OMARemote"
    readonly property string launcher: Sessions.bin.replace(/omaremote-session$/, "omaremote")

    property bool movingToTab: false
    // Reconnecting: the connection whose new session this window waits for.
    property string pendingConnection: ""

    focus: true

    // Claims the session as shown here, so the manager leaves it alone and brings this window forward.
    function claim() {
        if (sessionId !== "")
            Quickshell.execDetached([Sessions.bin, "view", sessionId, "window", String(Quickshell.processId)])
    }
    // A new window floats at 90% of its monitor, centred; after that it is an ordinary window
    // (Omarchy's keys resize it, tile it, move it). Not again after a reconnect in it.
    Component.onCompleted: {
        claim()
        Quickshell.execDetached([Sessions.bin, "float", "pid", String(Quickshell.processId)])
    }
    onSessionIdChanged: claim()

    // ctrl+alt+t: into a tab of the manager, which comes forward on it. ctrl+alt+home (home): into
    // a tab too, but the manager comes forward on its connections.
    function toTab(home) {
        if (!live)
            return
        movingToTab = true
        Quickshell.execDetached([Sessions.bin, "view", sessionId, "tab"])
        Quickshell.execDetached(["uwsm-app", "--", launcher, "adopt", sessionId].concat(home ? ["--home"] : []))
        Qt.callLater(function () { if (root.host) root.host.quit() })
    }

    function reconnect() {
        if (!session)
            return
        pendingConnection = session.connection
        var dpr = Sessions.monitorScale / 100
        Sessions.launchInTab(session.connection, Math.round(view.width * dpr), Math.round(view.height * dpr), Math.round(dpr * 100))
    }

    // Called as the window closes: a live session ends with it, unless it moved to a tab.
    function closing() {
        if (!movingToTab && live)
            Sessions.stop(sessionId)
    }

    Connections {
        target: Sessions
        function onSessionsChanged() {
            if (root.pendingConnection === "")
                return
            var list = Sessions.sessions
            for (var i = 0; i < list.length; i++) {
                var s = list[i]
                if (s.connection === root.pendingConnection && s.id !== root.sessionId && Sessions.isActive(s)) {
                    root.pendingConnection = ""
                    root.sessionId = s.id
                    return
                }
            }
        }
    }

    Rectangle {
        anchors.fill: parent
        color: Theme.background
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        // Title bar: what this window shows, in the manager's tab style.
        Rectangle {
            Layout.fillWidth: true
            implicitHeight: Theme.chrome
            color: Theme.surface
            Row {
                anchors.left: parent.left
                anchors.leftMargin: Theme.padX
                anchors.verticalCenter: parent.verticalCenter
                spacing: Theme.gap
                Glyph {
                    anchors.verticalCenter: parent.verticalCenter
                    text: ""
                    size: Theme.caption - 3
                    color: !root.session ? Theme.muted
                         : root.session.state === "connected" ? Theme.success
                         : root.session.state === "connecting" ? Theme.warning : Theme.urgent
                }
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: root.title
                    color: Theme.foreground
                    font.family: Theme.font
                    font.pixelSize: Theme.caption
                    font.bold: true
                }
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    visible: !!root.session
                    text: root.session ? String(root.session.protocol || "rdp").toUpperCase() + " · " + root.session.host : ""
                    color: Theme.muted
                    font.family: Theme.font
                    font.pixelSize: Theme.caption
                }
            }
            Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Theme.hairline }
        }

        SessionView {
            id: view
            Layout.fillWidth: true
            Layout.fillHeight: true
            session: root.session
            current: true
            inWindow: true
            onNavigate: function (where) {
                if (where === "tab") root.toTab(false)
                else if (where === "home") root.toTab(true)
            }
            onToggleFullscreen: Quickshell.execDetached([Sessions.bin, "fullscreen"])
            onReconnectRequested: root.reconnect()
            onCloseRequested: { if (root.host) root.host.quit() }
        }

        StatusBar {
            Layout.fillWidth: true
            showCounts: false
            hints: [["ctrl+alt+t", "to a tab"], ["ctrl+alt+⏎", "fullscreen"],
                    root.session && root.session.protocol === "ssh" ? ["ctrl+shift+c/v", "copy/paste"] : ["ctrl+alt+end", "ctrl+alt+del"],
                    ["ctrl+alt+home", "to connections"], ["super+w", "disconnect"]]
        }
    }
}
