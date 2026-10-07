pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// Running and recent sessions. Each one is supervised by bin/omaremote-session outside this
// process; this side asks it to launch and stop, and re-reads the list whenever it says something changed.
Singleton {
    id: root

    readonly property string bin: Quickshell.env("OMAREMOTE_BIN") || (Quickshell.shellDir + "/../../bin/omaremote-session")

    property var sessions: []
    property string changesPath: ""
    // "connection:<id>" or "credential:<id>" -> true when the keyring holds that password.
    property var secrets: ({})

    // Whether a resolved connection's password is stored: true, false, or undefined (not asked yet).
    function passwordStored(c) {
        return c && c.secretId ? secrets[c.secretKind + ":" + c.secretId] : false
    }

    readonly property int activeCount: sessions.filter(isActive).length

    function isActive(s) {
        return s.state === "connecting" || s.state === "connected"
    }

    function forConnection(id) {
        return sessions.filter(function (s) { return s.connection === id })
    }

    function activeFor(id) {
        return sessions.filter(function (s) { return s.connection === id && isActive(s) })
    }

    // The newest session of a connection decides the dot beside it: connecting, connected or failed.
    function stateFor(id) {
        var list = forConnection(id)
        if (list.length === 0)
            return ""
        for (var i = 0; i < list.length; i++)
            if (isActive(list[i]))
                return list[i].state
        return list[0].state === "failed" ? "failed" : ""
    }

    function refresh() {
        if (lister.running)
            lister.again = true
        else
            lister.running = true
    }

    function launch(id) {
        Quickshell.execDetached([bin, "launch", id])
    }

    // Starts a session drawn in a tab; width and height are the tab's size in device pixels.
    function launchInTab(id, width, height, scale) {
        Quickshell.execDetached([bin, "launch", id, "--tab", width + "x" + height + "@" + scale])
    }

    // Raise the session's window; Hyprland switches to its workspace.
    function focus(s) {
        if (s && s.pid)
            Quickshell.execDetached(["hyprctl", "dispatch", "focuswindow", "pid:" + s.pid])
    }

    function stop(sid) {
        Quickshell.execDetached([bin, "stop", sid])
    }

    function forget(sid) {
        Quickshell.execDetached([bin, "forget", sid])
    }

    function forgetFinished(id) {
        var list = forConnection(id)
        for (var i = 0; i < list.length; i++)
            if (!isActive(list[i]))
                forget(list[i].id)
    }

    // Body shows the log in its own viewer.
    signal logRequested(var session)
    function openLog(s) {
        if (s && s.log)
            logRequested(s)
    }

    // kind is "connection" or "credential".
    function setSecret(kind, id, password) {
        writer.queue = writer.queue.concat([{ kind: kind, id: id, password: password }])
        writer.next()
    }

    function clearSecret(kind, id) {
        var next = Object.assign({}, secrets)
        delete next[kind + ":" + id]
        secrets = next
        Quickshell.execDetached([bin, "secret", "clear", kind, id])
    }

    function checkSecret(kind, id) {
        if (!id)
            return
        checker.queue = checker.queue.concat([{ kind: kind, id: id }])
        checker.next()
    }

    function markSecret(kind, id, has) {
        var next = Object.assign({}, secrets)
        next[kind + ":" + id] = has
        secrets = next
    }

    // What "Auto" scale resolves to right now; the backend asks again at every launch.
    property int monitorScale: 100
    Process {
        command: [root.bin, "monitor-scale"]
        running: true
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: root.monitorScale = parseInt(text) || 100
        }
    }

    // Where the backend keeps session state; the list is (re)read whenever its changes file moves.
    Process {
        command: [root.bin, "paths"]
        running: true
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                try {
                    root.changesPath = JSON.parse(text).changes
                } catch (e) {
                    console.warn("omaremote-session paths failed: " + e)
                }
                root.refresh()
            }
        }
    }

    Process {
        id: lister
        property bool again: false
        command: [root.bin, "list"]
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                try {
                    root.sessions = JSON.parse(text)
                } catch (e) {
                    console.warn("omaremote-session list failed: " + e)
                }
            }
        }
        onExited: {
            if (again) {
                again = false
                running = true
            }
        }
    }

    FileView {
        path: root.changesPath
        watchChanges: root.changesPath !== ""
        printErrors: false
        onFileChanged: root.refresh()
    }

    // A supervisor killed outright writes nothing; a slow poll while something runs catches it.
    Timer {
        interval: 3000
        repeat: true
        running: root.activeCount > 0
        onTriggered: root.refresh()
    }

    // Keyring writes and lookups go one at a time, queued, so quick edits never drop one.
    Process {
        id: writer
        property var queue: []
        property var current: null
        function next() {
            if (running || queue.length === 0)
                return
            current = queue[0]
            queue = queue.slice(1)
            command = [root.bin, "secret", "set", current.kind, current.id]
            stdinEnabled = true
            running = true
        }
        onStarted: {
            write(current.password)
            current.password = ""
            stdinEnabled = false
        }
        onExited: function (code) {
            root.markSecret(current.kind, current.id, code === 0)
            Qt.callLater(next)
        }
    }

    Process {
        id: checker
        property var queue: []
        property var current: null
        function next() {
            if (running || queue.length === 0)
                return
            current = queue[0]
            queue = queue.slice(1)
            command = [root.bin, "secret", "has", current.kind, current.id]
            running = true
        }
        onExited: function (code) {
            root.markSecret(current.kind, current.id, code === 0)
            Qt.callLater(next)
        }
    }
}
