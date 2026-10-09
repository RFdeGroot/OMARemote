pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// Connections on every system: export and import a file by hand, or keep systems in step through
// a folder something else syncs (Nextcloud, Syncthing, …). bin/omaremote-session does the merging
// and prints the result; Store applies it, so connections.json keeps one writer. Who signs in
// (user names, credential sets, passwords, extra arguments) never leaves this system.
Singleton {
    id: root

    // Store.ui.sync: {folder, system, interval (minutes, 0 off)}.
    readonly property var settings: Store.ui.sync || ({})
    readonly property string folder: settings.folder || ""
    readonly property int interval: settings.interval !== undefined ? settings.interval : 5
    readonly property bool enabled: folder.trim() !== ""
    // Settings › Sync › "Sync when a file arrives": watch the folder (off unless switched on).
    readonly property bool watch: settings.watch === true
    // This system's file in the folder is <system>.omaremote.json.
    property string systemName: ""

    property bool busy: false
    // Set while an editor is open: a merge never lands under someone's typing.
    property bool paused: false
    property double lastSync: 0
    property var lastReport: null
    property string lastError: ""
    // A file that would trash many connections at once: {system, ids, names}, until the user says.
    property var pending: null

    signal notice(string text, bool isError)
    // A key file chosen in the file chooser, for the connection editor.
    signal keyPicked(string path)

    function set(key, value) {
        var next = Object.assign({}, settings)
        next[key] = value
        Store.setUi("sync", next)
    }

    function summary(report) {
        var parts = []
        if (report.added.length) parts.push(report.added.length + " added")
        if (report.updated.length) parts.push(report.updated.length + " updated")
        if (report.restored.length) parts.push(report.restored.length + " restored")
        if (report.trashed.length) parts.push(report.trashed.length + " moved to Recently deleted")
        return parts.join(", ")
    }

    // ---------------------------------------------------------------- folder sync

    property int startedAt: 0
    property var allow: []

    function syncNow(allowDeletionsFrom) {
        if (!enabled || !Store.loaded)
            return
        if (runner.running || paused) {
            again.restart()
            return
        }
        root.allow = allowDeletionsFrom || []
        root.startedAt = Store.localRevision
        root.busy = true
        runner.running = true
    }

    // The user's answer to a mass deletion.
    function confirmPending(trashThem) {
        var p = pending
        root.pending = null
        if (!p)
            return
        if (trashThem) {
            syncNow([p.system])
        } else {
            Store.touch(p.ids) // newer than the deletion: they sync back to the other system
            notice("Kept " + p.ids.length + " connections; they go back to " + p.system, false)
        }
    }

    Process {
        id: runner
        command: [Sessions.bin, "sync"].concat(root.allow.length ? ["--allow-deletions", root.allow.join(",")] : [])
        stdout: StdioCollector { id: syncOut; waitForEnd: true }
        onExited: function (exitCode) {
            root.busy = false
            var result
            try {
                result = JSON.parse(syncOut.text)
            } catch (e) {
                root.lastError = "sync gave no answer"
                return
            }
            if (result.error) {
                root.lastError = result.error
                return
            }
            // Edited here while it ran: what it merged is already out of date.
            if (Store.localRevision !== root.startedAt) {
                again.restart()
                return
            }
            root.lastError = ""
            root.allow = []
            root.systemName = result.system || root.systemName
            Store.applyMerged(result.data)
            for (var i = 0; i < (result.purged || []).length; i++)
                Sessions.clearSecret("connection", result.purged[i])
            var report = result.report
            root.lastReport = report
            root.lastSync = Date.now()
            if (report.pendingDeletions.length > 0)
                root.pending = report.pendingDeletions[0]
            var said = root.summary(report)
            if (said)
                root.notice("Synced: " + said, false)
            if (report.errors.length > 0)
                root.notice("Sync: " + report.errors[0], true)
        }
    }

    // After an edit here, and again whenever a round was skipped or outdated.
    Timer { id: again; interval: 3000; onTriggered: root.syncNow(root.allow) }
    Timer {
        interval: Math.max(1, root.interval) * 60000
        repeat: true
        running: root.enabled && root.interval > 0
        onTriggered: root.syncNow()
    }
    Connections {
        target: Store
        function onLocalRevisionChanged() { if (root.enabled) again.restart() }
        function onLoadedChanged() { root.start() }
    }
    onPausedChanged: if (!paused && enabled) again.restart()

    function start() {
        if (!Store.loaded)
            return
        // The trash empties itself after 30 days, sync or not.
        var old = Store.purgeOld()
        for (var i = 0; i < old.length; i++)
            Sessions.clearSecret("connection", old[i])
        if (enabled)
            syncNow()
    }

    Process {
        id: nameProbe
        command: [Sessions.bin, "system-name"]
        running: true
        stdout: StdioCollector { id: nameOut; waitForEnd: true }
        onExited: root.systemName = nameOut.text.trim()
    }

    // A new or changed folder syncs straight away, and is watched from then on.
    onFolderChanged: {
        if (enabled)
            again.restart()
        watcher.running = false
        rewatch.restart()
    }
    onWatchChanged: {
        watcher.running = false
        rewatch.restart()
    }

    // Another system's file arriving (Nextcloud delivering it) syncs within seconds, not at the
    // next interval; the interval stays as the fallback. Our own file's writes are not news.
    readonly property string ownFile: (settings.system || systemName) + ".omaremote.json"
    Process {
        id: watcher
        command: [Sessions.bin, "watch-folder", root.folder]
        running: root.enabled && root.watch && Store.loaded
        stdout: SplitParser {
            onRead: function (name) {
                if (name.trim() !== "" && name.trim() !== root.ownFile)
                    arrived.restart()
            }
        }
        // Ended (the folder setting changed, or something failed): watch again shortly.
        onExited: rewatch.restart()
    }
    Timer { id: rewatch; interval: 2000; onTriggered: watcher.running = root.enabled && root.watch && Store.loaded }
    // A burst of writes (a client syncing several files) becomes one round.
    Timer { id: arrived; interval: 2000; onTriggered: root.syncNow() }

    // ---------------------------------------------------------------- the desktop's file chooser

    // Through xdg-desktop-portal: whichever chooser the desktop set (Flea on Omarchy, else GTK's).
    // Without one, the buttons fall back to the path typed in the field.
    function browse(purpose, mode, title, current, name) {
        if (picker.running)
            return
        picker.purpose = purpose
        picker.fallback = current
        picker.command = [Sessions.bin, "pick", mode, "--title", title, "--current", current || "~"]
                         .concat(name ? ["--name", name] : [])
        picker.running = true
    }

    function browseFolder() {
        browse("folder", "folder", "Sync folder for OMARemote", folder, "")
    }
    function exportVia(current) {
        browse("export", "save", "Export OMARemote connections", current, "omaremote-connections.json")
    }
    function importVia(current) {
        browse("import", "open", "Import OMARemote connections", current, "")
    }

    function chosen(purpose, path) {
        if (purpose === "sshKey") {
            var home = Quickshell.env("HOME")
            keyPicked(path.indexOf(home + "/") === 0 ? "~" + path.slice(home.length) : path)
            return
        }
        if (purpose === "folder") {
            set("folder", path)
            return
        }
        Store.setUi("exportPath", path)
        if (purpose === "export")
            exportTo(path)
        else
            importFrom(path)
    }

    Process {
        id: picker
        property string purpose: ""
        property string fallback: ""
        stdout: StdioCollector { id: pickOut; waitForEnd: true }
        onExited: function (exitCode) {
            var result = {}
            try {
                result = JSON.parse(pickOut.text)
            } catch (e) {
                result = { error: "no file chooser" }
            }
            if (result.error) {
                // No chooser here: a typed path still works.
                if ((picker.purpose === "export" || picker.purpose === "import") && picker.fallback.trim() !== "")
                    root.chosen(picker.purpose, picker.fallback.trim())
                else
                    root.notice("No file chooser available: type the path in the field", true)
                return
            }
            if (result.path)
                root.chosen(picker.purpose, result.path)
        }
    }

    // ---------------------------------------------------------------- ~/.ssh/omaremote.conf

    // The keys chosen for SSH connections, also in ssh's own config when the user allows it (see
    // ssh_config_sync in bin/omaremote-session): brought in step after the connections or the
    // setting change. auto: OMARemote added the Include; manual: the user did; off: neither.
    property string sshConfigMode: "off"
    readonly property bool sshTerminalKeys: !!Store.ui.sshTerminalKeys

    Connections {
        target: Store
        function onStoredChanged() { sshConfig.restart() }
        function onUiChanged() { sshConfig.restart() }
    }
    Timer {
        id: sshConfig
        interval: 800
        onTriggered: if (!sshConfigWriter.running) sshConfigWriter.running = true
    }
    Process {
        id: sshConfigWriter
        command: [Sessions.bin, "ssh-config"]
        stdout: StdioCollector { id: sshConfigOut; waitForEnd: true }
        onExited: function (exitCode) {
            try {
                var r = JSON.parse(sshConfigOut.text)
                if (r.error)
                    root.notice("Could not update ssh's config: " + r.error, true)
                else
                    root.sshConfigMode = r.mode
            } catch (e) {
            }
        }
    }

    // ---------------------------------------------------------------- by hand

    function exportTo(path) {
        if (!path.trim() || exporter.running)
            return
        exporter.command = [Sessions.bin, "export", path.trim()]
        exporter.running = true
    }

    Process {
        id: exporter
        stdout: StdioCollector { id: exportOut; waitForEnd: true }
        onExited: function (exitCode) {
            try {
                var r = JSON.parse(exportOut.text)
                root.notice("Exported " + r.connections + " connections to " + r.file, false)
            } catch (e) {
                root.notice("Export failed: check the path", true)
            }
        }
    }

    property int importStartedAt: 0

    function importFrom(path) {
        if (!path.trim() || importer.running)
            return
        root.importStartedAt = Store.localRevision
        importer.command = [Sessions.bin, "import", path.trim()]
        importer.running = true
    }

    Process {
        id: importer
        stdout: StdioCollector { id: importOut; waitForEnd: true }
        onExited: function (exitCode) {
            var result
            try {
                result = JSON.parse(importOut.text)
            } catch (e) {
                root.notice("Import failed: not an OMARemote export", true)
                return
            }
            if (result.error) {
                root.notice("Import failed: " + result.error, true)
                return
            }
            if (Store.localRevision !== root.importStartedAt) {
                root.notice("Changed while importing: import again", true)
                return
            }
            Store.applyMerged(result.data)
            // Imported connections are edits here: they reach the sync folder too.
            Store.localRevision++
            var said = root.summary(result.report)
            root.notice(said ? "Imported: " + said : "Import: nothing new", false)
        }
    }

    Component.onCompleted: start()
}
