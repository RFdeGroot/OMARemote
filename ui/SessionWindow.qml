import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.Commons
import "js/Format.js" as Format

// A session in a window of its own: a title bar, the session as a tab draws it (connecting, prompts,
// why it ended), and the keys that work here at the bottom. ctrl+alt+t hands it to a tab.
FocusScope {
    id: root
    property var host: null
    // The theme is in: the window (boot/shell.qml, window/shell.qml) shows from then on.
    readonly property bool themed: Theme.loaded

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
    // Hyprland fullscreen (the bar hidden): the window covers its whole screen. Only the remote
    // desktop shows; the top edge slides in a bar to leave (connectionBar). Maximised keeps the
    // Omarchy bar, so it is not this.
    readonly property bool wholeScreen: !!host && !!host.screen && host.screen.width > 0 && host.screen.height > 0
                                        && host.width >= host.screen.width && host.height >= host.screen.height
    property bool barShown: false
    // Set once the window was really whole screen: a new window can look like one for a moment
    // before Hyprland places it, and must not be centred again for that.
    property bool wasWholeScreen: false
    Timer { id: settled; interval: 500; onTriggered: root.wasWholeScreen = root.wholeScreen }
    onWholeScreenChanged: {
        barShown = false
        if (wholeScreen) {
            settled.restart()
            return
        }
        settled.stop()
        // Hyprland brings a floating window back at its size but not centred (part off screen).
        if (wasWholeScreen)
            Quickshell.execDetached([Sessions.bin, "center", String(Quickshell.processId)])
        wasWholeScreen = false
    }
    // Kept on a special workspace of its own, shown and hidden by its shortcut (omaremote toggle).
    readonly property bool hotkey: {
        Store.stored
        var c = root.session ? Store.get(root.session.connection) : null
        return !!c && c.openIn === "hotkey"
    }
    // Reconnecting: the connection whose new session this window waits for.
    property string pendingConnection: ""
    // The live session a reconnect replaces, stopped once the new one is shown.
    property string replacedSession: ""
    property real reconnectAt: 0
    // Why the last reconnect failed, in the status bar for a while (the old session kept running).
    property string notice: ""
    Timer { id: noticeTimer; interval: 6000; onTriggered: root.notice = "" }

    // "show" puts the new session on screen with the old one still running behind it; "swap"
    // stops the old one; "failed" goes back to the old one while it runs.
    function stepReplacing() {
        if (pendingConnection === "" || replacedSession === "")
            return
        var s = Format.reconnectCandidate(Sessions.sessions, pendingConnection, replacedSession, reconnectAt)
        var step = Format.reconnectStep(s, reconnectAt, Date.now())
        if (step === "wait")
            return
        if (step === "show") {
            sessionId = s.id
            return
        }
        pendingConnection = ""
        if (step === "swap") {
            sessionId = s.id
            Sessions.stop(replacedSession)
        } else {
            // Back to the old one while it runs; else the failed new one, whose panel says why.
            var old = Sessions.sessions.filter(function (x) { return x.id === root.replacedSession })[0]
            notice = "Reconnect failed" + (s && s.error ? ": " + s.error : "")
            noticeTimer.restart()
            if (old && Sessions.isActive(old)) {
                sessionId = replacedSession
                if (s)
                    Sessions.forget(s.id)
            } else if (s) {
                sessionId = s.id
            }
        }
        replacedSession = ""
    }
    Timer {
        interval: 500
        repeat: true
        running: root.replacedSession !== ""
        onTriggered: root.stepReplacing()
    }

    focus: true

    // Claims the session as shown here, so the manager leaves it alone and brings this window forward.
    function claim() {
        if (sessionId !== "")
            Quickshell.execDetached([Sessions.bin, "view", sessionId, "window", String(Quickshell.processId)])
    }
    // A new window floats at 90% of its monitor, centred; after that it is an ordinary window
    // (Omarchy's keys resize it, tile it, move it). Not again after a reconnect in it. A hotkey
    // window goes to its special workspace too (place in bin/omaremote-session).
    Component.onCompleted: {
        claim()
        Quickshell.execDetached([Sessions.bin, "place", sessionId, String(Quickshell.processId)])
        // An SSH session's window is a terminal to Hyprland (Omarchy's Super+V/Super+C), as in a tab.
        if (session && session.protocol === "ssh")
            Quickshell.execDetached([Sessions.bin, "terminal-tag", String(Quickshell.processId), "on"])
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

    // A live session (ctrl+alt+r, or back after unlockAfter) stays on screen until the new one is
    // up (Format.reconnectStep), then stops: a locked Windows desktop comes back signed in.
    function reconnect() {
        if (!session || pendingConnection !== "")
            return
        replacedSession = live ? sessionId : ""
        reconnectAt = Date.now()
        pendingConnection = session.connection
        var dpr = Sessions.monitorScale / 100
        Sessions.launchInTab(session.connection, Math.round(view.width * dpr), Math.round(view.height * dpr), Math.round(dpr * 100))
    }

    // Called as the window closes: a live session ends with it, unless it moved to a tab.
    function closing() {
        if (replacedSession !== "" && replacedSession !== sessionId)
            Sessions.stop(replacedSession) // a reconnect under way: the old one ran behind the new one
        if (replacedSession !== "" && sessionId === replacedSession) {
            var s = Format.reconnectCandidate(Sessions.sessions, pendingConnection, replacedSession, reconnectAt)
            if (s)
                Sessions.stop(s.id)
        }
        if (!movingToTab && live)
            Sessions.stop(sessionId)
    }

    Connections {
        target: Sessions
        function onSessionsChanged() {
            if (root.pendingConnection === "")
                return
            if (root.replacedSession !== "")
                return root.stepReplacing()
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
            visible: !root.wholeScreen
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
                    textFormat: Text.PlainText
                    anchors.verticalCenter: parent.verticalCenter
                    text: root.title
                    color: Theme.foreground
                    font.family: Theme.font
                    font.pixelSize: Theme.caption
                    font.bold: true
                }
                Text {
                    textFormat: Text.PlainText
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
                else if (where === "hide" && root.hotkey) Quickshell.execDetached([Sessions.bin, "hide", root.sessionId])
                // The manager comes forward with the quick connect card; this session stays here.
                else if (where === "quick") Quickshell.execDetached(["uwsm-app", "--", root.launcher, "quick"])
            }
            onToggleFullscreen: Quickshell.execDetached([Sessions.bin, "fullscreen"])
            onReconnectRequested: root.reconnect()
            // ctrl+alt+w, or Close on an ended session: as the close key, it disconnects.
            onCloseRequested: { root.closing(); if (root.host) root.host.quit() }
        }

        StatusBar {
            visible: !root.wholeScreen
            Layout.fillWidth: true
            showCounts: false
            notice: root.notice
            noticeIsError: true
            info: root.live && root.session.protocol === "gliff" ? (Sessions.stats[root.session.id] || "") : ""
            hints: (root.hotkey ? [["ctrl+alt+h", "hide"]] : []).concat([["ctrl+alt+t", "to a tab"], ["ctrl+alt+⏎", "fullscreen"],
                    root.session && root.session.protocol === "ssh" ? ["ctrl+shift+c/v", "copy/paste"]
                    : root.session && root.session.protocol === "gliff" ? Format.gliffKeyHint(Sessions.capturedSession === root.session.id)
                    : ["ctrl+alt+end", "ctrl+alt+del"],
                    ["ctrl+alt+home", "to connections"], [Sessions.closeKey, "disconnect"]])
        }
    }

    // Whole screen: resting the pointer on the top edge slides in a bar to leave fullscreen (as
    // Windows' own Remote Desktop bar does); ctrl+alt+⏎ does the same. Only the edge's top two
    // pixels are taken from the remote desktop, and only for hovering: clicks still go through.
    Item {
        visible: root.wholeScreen
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        height: 2
        z: 10
        HoverHandler {
            onHoveredChanged: hovered ? showDelay.restart() : showDelay.stop()
        }
    }
    Timer { id: showDelay; interval: 250; onTriggered: { root.barShown = true; hideDelay.restart() } }
    Timer { id: hideDelay; interval: 1500; onTriggered: if (!barHover.hovered) root.barShown = false }

    Rectangle {
        id: connectionBar
        visible: root.wholeScreen
        z: 11
        anchors.horizontalCenter: parent.horizontalCenter
        y: root.barShown ? 0 : -height - 1
        Behavior on y { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
        width: barRow.implicitWidth + 2 * Theme.padX
        height: Theme.control + 2 * Theme.gap
        color: Theme.surface
        border.width: 1
        border.color: Theme.hairline
        HoverHandler {
            id: barHover
            onHoveredChanged: if (!hovered) hideDelay.restart()
        }
        Row {
            id: barRow
            anchors.centerIn: parent
            spacing: Theme.gap
            Glyph {
                anchors.verticalCenter: parent.verticalCenter
                text: ""
                size: Theme.caption - 3
                color: !root.session ? Theme.muted
                     : root.session.state === "connected" ? Theme.success
                     : root.session.state === "connecting" ? Theme.warning : Theme.urgent
            }
            Text {
                textFormat: Text.PlainText
                anchors.verticalCenter: parent.verticalCenter
                text: root.title
                color: Theme.foreground
                font.family: Theme.font
                font.pixelSize: Theme.caption
                font.bold: true
            }
            Item { width: Theme.gap; height: 1 }
            ActionButton {
                anchors.verticalCenter: parent.verticalCenter
                primary: true
                text: "Exit fullscreen"
                hint: Keymap.session("ctrl+alt+⏎")
                onClicked: { root.barShown = false; Quickshell.execDetached([Sessions.bin, "fullscreen"]) }
            }
            ActionButton {
                anchors.verticalCenter: parent.verticalCenter
                visible: root.live
                text: "To a tab"
                hint: Keymap.session("ctrl+alt+t")
                onClicked: root.toTab(false)
            }
            ActionButton {
                anchors.verticalCenter: parent.verticalCenter
                danger: true
                text: "Disconnect"
                hint: Keymap.session(Sessions.closeKey)
                onClicked: { root.closing(); if (root.host) root.host.quit() }
            }
        }
    }
}
