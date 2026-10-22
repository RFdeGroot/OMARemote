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
    // Synced changes to where connections that sign in here point (host, port, gateway, KDC):
    // [{system, id, name, from, to}], held back until the user accepts or keeps their own.
    property var pendingAddress: []

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
    property var allowAddress: []

    function syncNow(allowDeletionsFrom, allowAddressFor) {
        if (!enabled || !Store.loaded || Store.broken)
            return
        if (runner.running || paused) {
            again.restart()
            return
        }
        root.allow = allowDeletionsFrom || []
        root.allowAddress = allowAddressFor || root.allowAddress
        root.startedAt = Store.localRevision
        root.busy = true
        runner.running = true
    }

    // The user's answer to changed addresses: accept them, or keep what is here (stamped newer, so
    // it goes back to the other systems).
    function confirmAddress(accept) {
        var p = pendingAddress
        root.pendingAddress = []
        if (p.length === 0)
            return
        var ids = p.map(function (x) { return x.id })
        if (accept) {
            syncNow(root.allow, ids)
        } else {
            Store.touch(ids.filter(function (i) { return i.indexOf("group:") !== 0 }))
            Store.touchGroups(ids.filter(function (i) { return i.indexOf("group:") === 0 }).map(function (i) { return i.slice(6) }))
            notice("Kept the addresses here; they go back to " + p[0].system, false)
        }
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
        command: [Sessions.bin, "sync"]
        // System and group names in the environment, never on the command line.
        environment: ({ OMAREMOTE_ALLOW_DELETIONS: JSON.stringify(root.allow),
                        OMAREMOTE_ALLOW_ADDRESS: JSON.stringify(root.allowAddress) })
        stdout: StdioCollector { id: syncOut; waitForEnd: true }
        onExited: function (exitCode) {
            root.busy = false
            var result
            try {
                // Defence in depth only: the collector has buffered it all by now. The real bound is
                // the backend, which answers {"error"} instead of more than 16 MiB (ANSWER_MAX_BYTES).
                if (syncOut.text.length > 16 * 1024 * 1024)
                    throw new Error("too large")
                result = JSON.parse(syncOut.text)
            } catch (e) {
                root.lastError = runnerDeadline.hit ? "sync took longer than a minute and was stopped" : "sync gave no answer"
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
            root.allowAddress = []
            root.systemName = result.system || root.systemName
            Store.applyMerged(result.data)
            for (var i = 0; i < (result.purged || []).length; i++) {
                Sessions.clearSecret("connection", result.purged[i])
                Sessions.clearSecret("gateway", result.purged[i])
            }
            var report = result.report
            root.lastReport = report
            root.lastSync = Date.now()
            if (report.pendingDeletions.length > 0)
                root.pending = report.pendingDeletions[0]
            if ((report.pendingAddress || []).length > 0)
                root.pendingAddress = report.pendingAddress
            var said = root.summary(report)
            if (said)
                root.notice("Synced: " + said, false)
            if (report.errors.length > 0)
                root.notice("Sync: " + report.errors[0], true)
        }
    }

    // After an edit here, and again whenever a round was skipped or outdated.
    // Nothing waits without a deadline: a sync folder that hangs (a stalled network share) ends the
    // round instead of stopping sync until a restart.
    Timer {
        id: runnerDeadline
        property bool hit: false
        interval: 60000
        running: runner.running
        onRunningChanged: if (running) hit = false
        onTriggered: {
            hit = true
            runner.running = false
        }
    }
    Timer { id: again; interval: 3000; onTriggered: root.syncNow(root.allow, root.allowAddress) }
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
        for (var i = 0; i < old.length; i++) {
            Sessions.clearSecret("connection", old[i])
            Sessions.clearSecret("gateway", old[i])
        }
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

    // The file chooser could not open: Settings › Import & export then shows a path field for export and import.
    property bool noChooser: false

    function browseFolder() {
        browse("folder", "folder", "Sync folder for OMARemote", folder, "")
    }
    // Export… and Import…: the file chooser, in the folder used last; without one, the path typed.
    readonly property string lastPath: Store.ui.exportPath || "~/omaremote-connections.json"
    function exportVia(typed) {
        if (noChooser && typed.trim() !== "")
            chosen("export", typed.trim())
        else
            browse("export", "save", "Export OMARemote connections", lastPath, "omaremote-connections.json")
    }
    function importVia(typed) {
        if (noChooser && typed.trim() !== "")
            chosen("import", typed.trim())
        else
            browse("import", "import", "Import connections", lastPath, "")
    }
    // 1Remote lives on Windows: no folder to find, so the chooser shows .db files only (1Remote lets its database be renamed).
    function import1Remote() {
        browse("import", "1remote", "Import from 1Remote (*.db)", lastPath, "")
    }

    // What happened last, for Settings › Import & export (this system's own, in ui):
    // lastExport {file, connections, at}, lastImport {what, added, updated, at}; at in seconds.
    function remember(key, value) {
        value.at = Math.floor(Date.now() / 1000)
        Store.setUi(key, value)
    }

    function chosen(purpose, path, paths) {
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
            importChosen(paths || [path])
    }

    // OMARemote's own files merge as before; .rdp, Remmina and 1Remote files go through the preview.
    function importChosen(paths) {
        var own = paths.filter(function (p) { return /\.json$/i.test(p) })
        var foreign = paths.filter(function (p) { return !/\.json$/i.test(p) })
        if (foreign.length > 0) {
            scanForeign(foreign, foreign.length === 1 ? foreign[0].replace(/^.*\//, "") : foreign.length + " files")
            if (own.length > 0)
                notice("OMARemote's own files import on their own: pick them separately", true)
        } else if (own.length > 0) {
            importFrom(own[0])
        }
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
                // No chooser here (no xdg-desktop-portal): Settings shows a path field instead.
                root.noChooser = true
                root.notice("No file chooser available: type the path in the field", true)
                return
            }
            if (result.path)
                root.chosen(picker.purpose, result.path, result.paths)
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
                root.remember("lastExport", { file: r.file, connections: r.connections })
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
        importer.what = path.trim().replace(/^.*\//, "")
        importer.command = [Sessions.bin, "import", path.trim()]
        importer.running = true
    }

    Process {
        id: importer
        property string what: ""
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
            root.remember("lastImport", { what: importer.what, added: result.report.added.length,
                                          updated: result.report.updated.length })
            var said = root.summary(result.report)
            root.notice(said ? "Imported: " + said : "Import: nothing new", false)
        }
    }

    // ---------------------------------------------------------------- other clients

    // .rdp files, Remmina and ~/.ssh/config: a scan first (bin/omaremote-session scan_foreign),
    // shown in ImportCard; the connections picked there are then added. Only ever adds: what is
    // here already stays as it is, so importing again changes nothing.
    // {title, sources, entries: [{ref, status, reason, protocol, name, host, port, group, username,
    // notes, source}], errors}, or null.
    property var importPreview: null
    property var remminaFolders: []
    property bool sshConfigFound: false

    function scanForeign(sources, title) {
        if (scanner.running || foreignImporter.running)
            return
        scanner.title = title
        scanner.sources = sources
        scanner.running = true
    }
    function importRemmina() { scanForeign(["remmina"], "Remmina") }
    function importSshConfig() { scanForeign(["ssh-config"], "~/.ssh/config") }

    function applyForeign(refs) {
        var p = importPreview
        root.importPreview = null
        if (!p || refs.length === 0 || foreignImporter.running)
            return
        root.importStartedAt = Store.localRevision
        foreignImporter.picked = refs
        foreignImporter.sources = p.sources
        foreignImporter.what = p.title
        foreignImporter.running = true
    }

    Process {
        id: scanner
        property string title: ""
        property var sources: []
        // File names are often server names: in the environment, never on the command line.
        command: [Sessions.bin, "import-scan"]
        environment: ({ OMAREMOTE_IMPORT_SOURCES: JSON.stringify(scanner.sources) })
        stdout: StdioCollector { id: scanOut; waitForEnd: true }
        onExited: function (exitCode) {
            var r
            try {
                r = JSON.parse(scanOut.text)
            } catch (e) {
                root.notice("Import failed: no answer", true)
                return
            }
            if (r.error) {
                root.notice("Import failed: " + r.error, true)
                return
            }
            if (r.entries.length === 0) {
                root.notice(r.errors.length ? "Import: " + r.errors[0] : "Import: no connections found", true)
                return
            }
            root.importPreview = { title: scanner.title, sources: scanner.sources, entries: r.entries, errors: r.errors }
        }
    }

    Process {
        id: foreignImporter
        property var picked: []
        property var sources: []
        property string what: ""
        // Host and file names in the environment, never on the command line.
        command: [Sessions.bin, "import-foreign"]
        environment: ({ OMAREMOTE_IMPORT_SOURCES: JSON.stringify(foreignImporter.sources),
                        OMAREMOTE_IMPORT_PICK: JSON.stringify(foreignImporter.picked) })
        stdout: StdioCollector { id: foreignOut; waitForEnd: true }
        onExited: function (exitCode) {
            var result
            try {
                result = JSON.parse(foreignOut.text)
            } catch (e) {
                root.notice("Import failed: no answer", true)
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
            Store.localRevision++
            var n = result.report.added.length
            root.remember("lastImport", { what: foreignImporter.what, added: n, updated: 0 })
            root.notice(n ? "Imported: " + n + " added" : "Import: nothing new", false)
        }
    }

    Process {
        id: sourcesProbe
        command: [Sessions.bin, "import-sources"]
        running: true
        stdout: StdioCollector { id: sourcesOut; waitForEnd: true }
        onExited: {
            try {
                var r = JSON.parse(sourcesOut.text)
                root.remminaFolders = r.remmina || []
                root.sshConfigFound = !!r.sshConfig
            } catch (e) {
            }
        }
    }

    Component.onCompleted: start()
}
