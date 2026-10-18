import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import "js/Format.js" as Format
import "js/Limits.js" as Limits

// The whole window: header with search, sidebar, connection list, and the detail or editor pane.
// Keyboard first: every action has a key, listed in the status bar.
FocusScope {
    id: root
    property var host: null

    property string filter: "all"
    property string query: ""
    property string selectedId: ""
    property bool editing: false
    // The group whose settings are open, and the credential set being edited ("new" for a new one).
    property string editingGroup: ""
    // editingGroup while making a new group (no group name can be a line break).
    readonly property string newGroup: "\n"
    // Connections dropped on "New group" (or sent there with m): they move in once it is saved.
    property var pendingGroupMove: []
    // The connection being dragged onto a group, if any.
    property string draggingId: ""
    readonly property var dragging: { Store.stored; return draggingId ? Store.get(draggingId) : null }
    property string editingCredential: ""
    readonly property bool busy: editing || editingGroup !== "" || editingCredential !== ""
    property string notice: ""
    property bool noticeIsError: false
    property bool deleteArmed: false
    property var logSession: null

    // Tabs: "home" is the connections view; the rest are session ids, in the order opened.
    property string currentTab: "home"
    property var openTabs: []
    // Connection ids launched into a tab whose session has not shown up in the list yet.
    property var pendingTabs: []
    // Connection ids launched for an own window, waiting for their session like pendingTabs.
    property var pendingWindows: []
    // Fullscreen with the chrome hidden, for a session tab.
    property bool immersive: false
    // The connections list docked beside session tabs; the desktop resizes to the room left.
    readonly property bool pinned: !!Store.ui.pinned
    readonly property int dockWidth: pinned && !immersive ? 211 : 0

    readonly property var tabSessions: {
        var byId = {}
        for (var i = 0; i < Sessions.sessions.length; i++)
            byId[Sessions.sessions[i].id] = Sessions.sessions[i]
        return root.openTabs.map(function (id) { return byId[id] }).filter(function (s) { return !!s })
    }

    focus: true

    readonly property bool inTrash: filter === "trash"

    // A search that reads as an address (Format.quickSpec): connect to it without saving it first.
    readonly property var quickSpec: {
        if (root.inTrash || !root.query)
            return null
        return Format.quickSpec(root.query, root.listed.length === 0)
    }
    readonly property string quickRowId: "quick:"
    // The list with the "Connect to …" row on top when the search reads as an address.
    readonly property var shownWithQuick: {
        var spec = root.quickSpec
        if (!spec)
            return root.listed
        // A saved connection to that very server is the one to use: no unsaved twin next to it.
        for (var i = 0; i < Store.connections.length; i++) {
            var c = Store.connections[i]
            if (c.protocol === spec.protocol && String(c.host).toLowerCase() === spec.host.toLowerCase()
                    && Number(c.port) === spec.port && (!spec.username || c.username === spec.username))
                return root.listed
        }
        var who = spec.username ? (spec.domain ? spec.domain + "\\" : "") + spec.username + "@" : ""
        var defaultPort = { rdp: 3389, vnc: 5900, ssh: 22 }[spec.protocol]
        // A whole connection (a blank one with what was typed), so the detail pane reads like any other.
        var row = Store.resolve(Object.assign(Store.blankIn(""), {
            id: root.quickRowId, protocol: spec.protocol, host: spec.host, port: spec.port,
            username: spec.username, domain: spec.domain, group: "", credential: "custom",
            name: "Connect to " + who + spec.host + (spec.port !== defaultPort ? ":" + spec.port : "")
        }))
        row.quickRow = true
        return [row].concat(root.listed)
    }
    readonly property var shown: shownWithQuick
    readonly property var listed: {
        if (root.inTrash)
            return Store.trashedConnections.filter(function (c) { return Format.matches(c, root.query) })
                                           .sort(function (a, b) { return b.trashedAt - a.trashedAt })
        // Quick connections show where they matter: in Recent and Active.
        var source = root.filter === "recent" || root.filter === "active"
                     ? Store.connections.concat(Store.quickConnections) : Store.connections
        var list = source.filter(function (c) {
            if (!Format.matches(c, root.query))
                return false
            if (root.filter === "favourites")
                return c.favourite
            if (root.filter === "recent")
                return c.lastConnected > 0
            if (root.filter === "active")
                return Sessions.activeFor(c.id).length > 0
            if (root.filter.indexOf("group:") === 0)
                return c.group === root.filter.slice(6)
            return true
        })
        if (root.filter === "recent")
            return list.sort(function (a, b) { return b.lastConnected - a.lastConnected })
        if (root.grouped)
            return list.sort(function (a, b) {
                // Groups by name, those without one last, each in the usual order.
                if (a.group !== b.group)
                    return !a.group ? 1 : !b.group ? -1 : a.group.localeCompare(b.group)
                return byName(a, b)
            })
        return list.sort(byName)
    }

    // All connections, unsearched, is shown under group headings once there are groups.
    readonly property bool grouped: filter === "all" && query === ""
                                    && Store.connections.some(function (c) { return !!c.group })

    // Favourites first, then by name: the list's order, and the pinned list's.
    function byName(a, b) {
        if (a.favourite !== b.favourite)
            return a.favourite ? -1 : 1
        return (a.name || a.host).localeCompare(b.name || b.host)
    }

    readonly property var selected: {
        Store.connections; Store.trashedConnections; Store.quickConnections
        if (root.selectedId === root.quickRowId)
            return root.shown.length > 0 && root.shown[0].quickRow ? root.shown[0] : null
        return root.inTrash ? Store.trashedGet(root.selectedId) : Store.get(root.selectedId)
    }
    // An emptied trash has nothing left to show.
    readonly property int trashCount: Store.trash.length
    onTrashCountChanged: if (trashCount === 0 && inTrash) filter = "all"

    // Keep a selection whenever there is something to select.
    onShownChanged: {
        for (var i = 0; i < shown.length; i++)
            if (shown[i].id === selectedId)
                return
        // The first real match, before the "Connect to …" row, which is one ↑ away.
        if (!editing)
            selectedId = shown.length > 1 && shown[0].quickRow ? shown[1].id
                       : shown.length > 0 ? shown[0].id : ""
    }
    onSelectedIdChanged: {
        deleteArmed = false
        var c = Store.get(selectedId)
        if (c && c.savePassword)
            Sessions.checkSecret(c.secretKind, c.secretId)
    }

    function say(text, isError) {
        notice = text
        noticeIsError = !!isError
        noticeTimer.restart()
    }

    function move(delta) {
        if (shown.length === 0)
            return
        var at = 0
        for (var i = 0; i < shown.length; i++)
            if (shown[i].id === selectedId)
                at = i
        at = Math.max(0, Math.min(shown.length - 1, at + delta))
        selectedId = shown[at].id
        list.positionViewAtIndex(at, ListView.Contain)
    }

    // The "Connect to …" row: a quick connection for what was typed, then connected like any other.
    // Its id goes into connections.json first; the session starts once that is written.
    function connectQuick() {
        var spec = root.quickSpec
        if (!spec)
            return
        var id = Store.quickConnect(spec)
        query = ""
        selectedId = id
        quickLaunch.target = id
        quickLaunch.restart()
    }
    Timer { id: quickLaunch; property string target: ""; interval: 200; onTriggered: root.connect(target) }

    function connect(id) {
        if ((id || selectedId) === quickRowId)
            return connectQuick()
        var c = Store.get(id || selectedId)
        if (!c)
            return
        // RDP allows one session per user: a second connect would end the first, so go to it instead.
        var running = Sessions.activeFor(c.id)
        var hotkey = c.openIn === "hotkey" && c.protocol !== "vnc"
        // A hotkey window lives on its own special workspace: shown there, wherever that is.
        if (hotkey && running.length > 0 && (!running[0].tab || running[0].view === "window")) {
            Quickshell.execDetached([Sessions.bin, "toggle", "--show", c.id])
            return
        }
        if (running.length > 0) {
            if (running[0].tab && running[0].view !== "window")
                showTab(running[0].id)
            else
                Sessions.focus(running[0])
            say("Switched to " + (c.name || c.host))
            return
        }
        if ((c.openIn === "window" || hotkey) && c.protocol !== "vnc") {
            say("Connecting to " + (c.name || c.host) + "…")
            // All monitors needs FreeRDP's own window; otherwise OMARemote draws the window itself.
            if (c.multimon && (c.protocol || "rdp") === "rdp") {
                Sessions.launch(c.id)
                return
            }
            var windowDpr = Sessions.monitorScale / 100
            Sessions.launchInTab(c.id, Math.round(1280 * windowDpr), Math.round(800 * windowDpr), Math.round(windowDpr * 100))
            pendingWindows = pendingWindows.concat([c.id])
            return
        }
        // Start the desktop at the size it will be shown at, in device pixels.
        var dpr = Sessions.monitorScale / 100
        Sessions.launchInTab(c.id, Math.round(sessionArea.width * dpr), Math.round(sessionArea.height * dpr), Math.round(dpr * 100))
        pendingTabs = pendingTabs.concat([c.id])
    }

    function showTab(id) {
        if (id !== "home" && openTabs.indexOf(id) < 0)
            openTabs = openTabs.concat([id])
        currentTab = id
        if (id === "home") {
            immersive = false
            root.takeKeys()
        }
    }

    function closeTab(id) {
        var s = null
        for (var i = 0; i < tabSessions.length; i++)
            if (tabSessions[i].id === id)
                s = tabSessions[i]
        // Closing a tab disconnects; the Windows session itself stays logged in.
        if (s && Sessions.isActive(s))
            Sessions.stop(s.id)
        var at = openTabs.indexOf(id)
        openTabs = openTabs.filter(function (t) { return t !== id })
        if (currentTab === id)
            showTab(openTabs.length > 0 ? openTabs[Math.min(at, openTabs.length - 1)] : "home")
    }

    // ctrl+alt+o: the session leaves its tab for a window of its own (the window takes over the
    // connection; nothing reconnects).
    // The window is closing (Hyprland's close key, super+w by default): the sessions shown in its tabs end
    // with it. Sessions in own windows, hotkey windows and FreeRDP's window are theirs, not ours.
    function closing() {
        var list = Sessions.sessions
        for (var i = 0; i < list.length; i++) {
            var s = list[i]
            if (s.tab && s.view !== "window" && Sessions.isActive(s))
                Sessions.stop(s.id)
        }
    }

    function popOut(id) {
        var at = openTabs.indexOf(id)
        if (at < 0)
            return
        openTabs = openTabs.filter(function (t) { return t !== id })
        if (currentTab === id)
            showTab(openTabs.length > 0 ? openTabs[Math.min(at, openTabs.length - 1)] : "home")
        openWindow(id)
    }

    function openWindow(id) {
        Quickshell.execDetached(["uwsm-app", "--", Sessions.bin.replace(/omaremote-session$/, "omaremote"), "window", id])
    }

    // An own window's ctrl+alt+t (or omaremote adopt): the session moves into a tab here, shown there
    // without taking the focus; with home (ctrl+alt+home) the manager comes forward on its connections.
    function adoptSession(id, home) {
        var list = Sessions.sessions
        for (var i = 0; i < list.length; i++) {
            var s = list[i]
            if (s.id !== id)
                continue
            if (!s.tab || !Sessions.isActive(s))
                return "not a running session: " + id
            Quickshell.execDetached([Sessions.bin, "view", id, "tab"])
            if (openTabs.indexOf(id) < 0)
                openTabs = openTabs.concat([id])
            showTab(home ? "home" : id)
            // ctrl+alt+home goes to the manager (its workspace); ctrl+alt+t leaves you where you are.
            if (home)
                raise()
            return "ok"
        }
        return "unknown session: " + id
    }

    function cycleTab(delta) {
        var all = ["home"].concat(openTabs)
        var at = Math.max(0, all.indexOf(currentTab))
        showTab(all[(at + delta + all.length) % all.length])
    }

    function reconnect(s) {
        closeTab(s.id)
        connect(s.connection)
    }

    function togglePinned() {
        Store.setUi("pinned", !pinned)
        say(pinned ? "Connections pinned beside sessions" : "Connections unpinned")
    }

    function toggleImmersive() {
        immersive = !immersive
        Quickshell.execDetached([Sessions.bin, "fullscreen"])
    }

    function startNew() {
        var c = Store.blankIn(filter.indexOf("group:") === 0 ? filter.slice(6) : "")
        closePanels()
        editing = true
        editor.load(c)
    }

    function startEdit() {
        if (!selected || selected.quickRow)
            return
        if (selected.quick)
            return saveQuickSelected()
        closePanels()
        editing = true
        editor.load(selected)
        if (selected.savePassword)
            Sessions.checkSecret(selected.secretKind, selected.secretId)
        if (selected.gatewaySavePassword)
            Sessions.checkSecret("gateway", selected.id)
    }

    // The quick connect card (o, ctrl+l, the button, `omaremote quick`): opened on the home tab, with
    // the search text when that reads as an address.
    function openQuick(text) {
        showTab("home")
        closePanels()
        quickCard.open(text !== undefined ? text : (quickSpec ? query : ""))
    }
    // From the card: a quick connection now, or ("Also save it") the editor on a new connection that
    // connects once saved.
    property bool connectAfterSave: false
    function quickCardConnect(spec) {
        if (spec.save) {
            closePanels()
            editing = true
            connectAfterSave = true
            editor.load(Object.assign(Store.blankIn(""), {
                protocol: spec.protocol, host: spec.host, port: spec.port, name: spec.host,
                username: spec.username, domain: spec.domain, credential: spec.credential, sshKey: spec.sshKey
            }))
            return
        }
        var id = Store.quickConnect(spec)
        query = ""
        selectedId = id
        quickLaunch.target = id
        quickLaunch.restart()
    }

    // Saving a quick connection: the editor opens on it as a new connection; once saved, the quick
    // one is gone and the saved one syncs like any other.
    property string savingQuick: ""
    function saveQuickSelected() {
        if (!selected || !selected.quick)
            return
        var c = JSON.parse(JSON.stringify(Store.quick.filter(function (q) { return q.id === selected.id })[0]))
        savingQuick = c.id
        delete c.used
        c.id = ""
        closePanels()
        editing = true
        editor.load(Object.assign(Store.blankIn(""), c))
    }

    function finishEdit() {
        closePanels()
        root.takeKeys()
    }

    function closePanels() {
        editing = false
        editingGroup = ""
        editingCredential = ""
    }

    function openGroup(name) {
        closePanels()
        editingGroup = name || newGroup
        groupEditor.load(name || "")
    }

    function openCredential(id) {
        closePanels()
        editingCredential = id || "new"
        credentialEditor.load(id ? Store.credential(id) : { username: "", domain: "", savePassword: true })
    }

    // A credential set made from the fields of an editor; returns its id.
    function createCredential(username, domain, savePassword, password) {
        var id = Store.upsertCredential({ username: username, domain: domain, savePassword: savePassword })
        if (savePassword && password !== "")
            Sessions.setSecret("credential", id, password)
        return id
    }

    // from: the name it had ("" for a new group); a different name renames it.
    function saveGroup(from, name, credential, newCredential, settings, apply) {
        if (credential === "new")
            credential = createCredential(newCredential.username, newCredential.domain,
                                          newCredential.savePassword, newCredential.password)
        if (from === "")
            Store.createGroup(name)
        else
            Store.renameGroup(from, name)
        Store.setGroup(name, credential, settings, apply && from !== "")
        var moving = pendingGroupMove
        pendingGroupMove = []
        finishEdit()
        if (moving.length > 0) {
            moveToGroup(moving, name)
            return
        }
        say(from === "" ? "Made group " + name
            : (from !== name ? "Renamed " + from + " to " + name : "Saved group " + name)
              + (apply && Store.membersOf(name) > 0 ? ", applied to " + Store.membersOf(name) + " connections" : ""))
    }

    function deleteGroup(name) {
        var n = Store.deleteGroup(name)
        if (filter === "group:" + name)
            filter = "all"
        finishEdit()
        say("Deleted group " + name + (n > 0 ? "; its " + n + (n === 1 ? " connection is" : " connections are") + " in no group now" : ""))
    }

    function dragFrom(id) {
        if (busy || inTrash)
            return
        selectedId = id
        draggingId = id
    }
    function dragTo(sceneX, sceneY) {
        var p = root.mapFromItem(null, sceneX, sceneY)
        dragProxy.x = p.x
        dragProxy.y = p.y
    }
    function dragDone() {
        if (draggingId)
            dragProxy.Drag.drop()
        draggingId = ""
    }
    // A drop on a group (from the sidebar or a heading in the list): "" out of its group, "\n" a new one.
    function dropOnGroup(name) {
        var id = draggingId
        if (!id)
            return
        if (name === newGroup) {
            pendingGroupMove = [id]
            openGroup("")
        } else {
            moveToGroup([id], name)
        }
    }
    function chooseGroup(value) {
        if (value === newGroup) {
            pendingGroupMove = [selectedId]
            openGroup("")
        } else {
            moveToGroup([selectedId], value)
            takeKeys()
        }
    }

    // Drag and drop and m: into a group, "" for none. Says what happened to signing in.
    function moveToGroup(ids, name) {
        var before = {}
        for (var i = 0; i < ids.length; i++) {
            var c = Store.get(ids[i])
            if (c)
                before[c.id] = c.credentialSource || ""
        }
        var moved = Store.moveToGroup(ids, name)
        if (moved.length === 0)
            return
        var what = moved.length === 1 ? (moved[0].name || moved[0].host) : moved.length + " connections"
        var after = Store.get(moved[0].id)
        var signIn = ""
        if (moved.length === 1 && after && after.protocol !== "ssh" && after.protocol !== "gliff") {
            if (moved[0].credential === "inherit" && after.username)
                signIn = "; signs in as " + (after.domain ? after.domain + "\\" : "") + after.username
            else if (before[moved[0].id] === "group" && moved[0].credential === "custom")
                signIn = "; asks for credentials when connecting"
        }
        say((name ? "Moved " + what + " to " + name : "Took " + what + " out of its group") + signIn)
    }

    function saveCredential(cred, password, passwordTouched) {
        var id = Store.upsertCredential(cred)
        if (!cred.savePassword)
            Sessions.clearSecret("credential", id)
        else if (passwordTouched && password !== "")
            Sessions.setSecret("credential", id, password)
        say("Saved " + Store.credentialLabel(cred))
        finishEdit()
    }

    function deleteCredential(id) {
        var label = Store.credentialLabel(Store.credential(id))
        Sessions.clearSecret("credential", id)
        Store.removeCredential(id)
        say("Removed " + label)
        finishEdit()
    }

    function saveEdit(c, password, passwordTouched, gatewayPassword, gatewayPasswordTouched) {
        if (c.credential === "new")
            c.credential = createCredential(c.username.trim(), String(c.domain || "").trim(), !!c.savePassword, password)
        // Whether a gateway password was saved before this edit: only then can there be one to clear.
        var before = c.id ? Store.get(c.id) : null
        var hadGatewayPassword = !!before && !!before.gatewaySavePassword
        var id = Store.upsert(c)
        if (savingQuick !== "") {
            Store.forgetQuick(savingQuick)
            savingQuick = ""
        }
        if (connectAfterSave) {
            connectAfterSave = false
            quickLaunch.target = id
            quickLaunch.restart()
        }
        if (c.credential !== "custom" || !c.savePassword)
            Sessions.clearSecret("connection", id) // no password of its own any more
        else if (passwordTouched && password !== "")
            Sessions.setSecret("connection", id, password)
        if (!c.gatewaySavePassword || !String(c.gateway || "").trim()) {
            if (hadGatewayPassword)
                Sessions.clearSecret("gateway", id)
        }
        else if (gatewayPasswordTouched && gatewayPassword !== "")
            Sessions.setSecret("gateway", id, gatewayPassword)
        if (query !== "" && !Format.matches(c, query))
            query = ""
        if (filter !== "all" && filter !== "favourites" && filter !== "group:" + c.group)
            filter = "all"
        selectedId = id
        say("Saved " + (c.name || c.host))
        finishEdit()
    }

    function deleteSelected() {
        if (selected && selected.quick) {
            Store.forgetQuick(selected.id)
            say("Forgot " + selected.host)
            return
        }
        if (!selected)
            return
        if (!deleteArmed) {
            deleteArmed = true
            disarm.restart()
            say(inTrash ? "Press delete again to delete " + (selected.name || selected.host) + " for good, password included"
                        : "Press delete again to move " + (selected.name || selected.host) + " to Recently deleted", true)
            return
        }
        var c = selected
        deleteArmed = false
        if (inTrash) {
            Sessions.clearSecret("connection", c.id)
            Sessions.clearSecret("gateway", c.id)
            Store.purge(c.id)
            say("Deleted " + (c.name || c.host) + " for good")
            return
        }
        // The trash keeps it 30 days, keyring password included.
        Store.trashConnections([c.id], "local")
        say("Moved " + (c.name || c.host) + " to Recently deleted (5, then r restores it)")
    }

    function restoreSelected() {
        if (!selected || !inTrash)
            return
        var c = selected
        Store.restore(c.id)
        say("Restored " + (c.name || c.host))
    }

    function duplicateSelected() {
        if (selected && (selected.quick || selected.quickRow))
            return
        if (!selected)
            return
        selectedId = Store.duplicate(selected.id)
        say("Duplicated")
    }

    Timer { id: noticeTimer; interval: 4000; onTriggered: root.notice = "" }
    Timer { id: disarm; interval: 3000; onTriggered: root.deleteArmed = false }

    Connections {
        target: Sessions
        function onLogRequested(s) {
            root.logSession = s
            logView.forceActiveFocus()
        }
    }

    function showLog() {
        var list = selected ? Sessions.forConnection(selected.id) : []
        if (list.length > 0)
            Sessions.openLog(list[0])
        else
            say("No sessions yet for " + (selected ? selected.name : "this connection"))
    }

    function closeLog() {
        logSession = null
        if (currentTab === "home")
            root.takeKeys()
        else {
            var view = tabViews.itemAt(openTabs.indexOf(currentTab))
            if (view && view.item)
                view.item.focusDesktop()
        }
    }

    // Gives the keyboard back to the app's own keys (the handler below). Focusing this FocusScope
    // itself would hand the keys to whichever child had them last, even one hidden since (the
    // editor's name field after a save, the closed keymap sheet), which then swallowed typed keys
    // while arrows still reached the list.
    function takeKeys() {
        keyHome.forceActiveFocus()
    }
    Item { id: keyHome; focus: true }

    // The tab shown is a terminal: its hints are copy and paste, not ctrl+alt+del.
    readonly property bool currentIsSsh: {
        var list = Sessions.sessions
        for (var i = 0; i < list.length; i++)
            if (list[i].id === currentTab)
                return list[i].protocol === "ssh"
        return false
    }

    readonly property bool currentIsGliff: {
        var list = Sessions.sessions
        for (var i = 0; i < list.length; i++)
            if (list[i].id === currentTab)
                return list[i].protocol === "gliff"
        return false
    }

    // While an SSH session is shown, the window is tagged as a terminal for Hyprland, so Omarchy's
    // Super+V and Super+C paste and copy there (Shift+Insert, Ctrl+Insert) instead of sending Ctrl+V
    // and Ctrl+C, which a terminal reads as a character and an interrupt. RDP and VNC tabs get
    // Ctrl+V and Ctrl+C, as Windows wants.
    property bool taggedTerminal: false
    readonly property bool wantsTerminalTag: root.currentTab !== "home" && root.currentIsSsh
    onWantsTerminalTagChanged: terminalTagTimer.restart()
    Timer {
        id: terminalTagTimer
        interval: 150
        onTriggered: {
            if (root.wantsTerminalTag === root.taggedTerminal)
                return
            root.taggedTerminal = root.wantsTerminalTag
            Quickshell.execDetached([Sessions.bin, "terminal-tag", String(Quickshell.processId),
                                     root.wantsTerminalTag ? "on" : "off"])
        }
    }

    // The tab shown holds a session that has ended or failed: its hints are the panel's keys.
    readonly property bool currentEnded: {
        var list = Sessions.sessions
        for (var i = 0; i < list.length; i++)
            if (list[i].id === currentTab)
                return !Sessions.isActive(list[i])
        return false
    }

    // Where list-or-sidebar keys go on the connections tab.
    property string focusArea: "list"
    property int sidebarCursor: 0

    // Right Ctrl held, when it is the session key (Settings › Keyboard): its chords work here too.
    property bool hostHeld: false
    Keys.onReleased: function (event) {
        if (Keymap.isHostKey(event)) {
            root.hostHeld = false
            event.accepted = true
        }
    }

    // Every key here goes through Keymap.qml, the same table the keymap sheet (?) draws.
    Keys.onPressed: function (event) {
        if (Keymap.isHostKey(event)) {
            root.hostHeld = true
            event.accepted = true
            return
        }
        if (root.currentTab !== "home")
            return
        // The settings panel owns the keys while it is open.
        if (settingsPanel.opened || aboutCard.opened || groupPicker.opened || quickCard.opened || importCard.opened) {
            event.accepted = true
            return
        }
        // Alt+1…9 picks a tab by number: one row in the table, nine keys.
        if ((event.modifiers & Qt.AltModifier) && event.key >= Qt.Key_1 && event.key <= Qt.Key_9) {
            var tabs = ["home"].concat(root.openTabs)
            if (event.key - Qt.Key_1 < tabs.length)
                root.showTab(tabs[event.key - Qt.Key_1])
            event.accepted = true
            return
        }
        // With an editor or the log open only the app-wide keys apply; the rest are theirs.
        var context = root.busy || root.logSession ? "none" : root.focusArea
        var action = Keymap.match(event, context, root.hostHeld)
        if (action === "")
            return
        root.runAction(action)
        event.accepted = true
    }

    function focusList() {
        focusArea = "list"
        root.takeKeys()
    }

    function runAction(action) {
        var sidebarEntry = sidebar.entries[sidebarCursor]
        // The "Connect to …" row and quick connections take only what fits them: a quick one is
        // saved with s (or e) and forgotten with delete; the rest waits until it is saved.
        if (selected && (selected.quickRow || selected.quick)
                && ["edit", "duplicate", "delete", "favourite", "moveGroup", "groupSettings"].indexOf(action) >= 0) {
            if (selected.quickRow)
                say("Press ⏎ to connect to it")
            else if (action === "edit" || action === "groupSettings")
                saveQuickSelected()
            else if (action === "delete") {
                Store.forgetQuick(selected.id)
                say("Forgot " + selected.host)
            } else
                say("Save it as a connection first: s")
            return
        }
        // In the trash a connection can only come back or go for good.
        if (inTrash && ["connect", "edit", "duplicate", "favourite", "log", "groupSettings"].indexOf(action) >= 0) {
            if (action === "connect")
                restoreSelected()
            else if (selected)
                say("In Recently deleted: press r to restore it first")
            return
        }
        switch (action) {
        case "settings": settingsPanel.open(); break
        // Straight to the file chooser; without one, to the path field in Settings › Import & export.
        case "importConnections":
            if (Sync.noChooser) settingsPanel.open("transfer"); else Sync.importVia("")
            break
        case "exportConnections":
            if (Sync.noChooser) settingsPanel.open("transfer"); else Sync.exportVia("")
            break
        case "importRemmina":
            if (Sync.remminaFolders.length > 0) Sync.importRemmina(); else say("No Remmina profiles here (~/.local/share/remmina)")
            break
        case "import1Remote":
            if (Sync.noChooser) settingsPanel.open("transfer"); else Sync.import1Remote()
            break
        case "importSshConfig":
            if (Sync.sshConfigFound) Sync.importSshConfig(); else say("There is no ~/.ssh/config")
            break
        case "restore": if (inTrash) restoreSelected(); else say("Restore works in Recently deleted (5)"); break
        case "filterTrash":
            if (trashCount > 0) filter = "trash"
            else say("Recently deleted is empty")
            break
        case "connect": connect(); break
        case "quickConnect": openQuick(); break
        case "down": move(1); break
        case "up": move(-1); break
        case "first": move(-1e6); break
        case "last": move(1e6); break
        case "new": startNew(); break
        case "edit": startEdit(); break
        case "duplicate": duplicateSelected(); break
        case "delete": deleteSelected(); break
        case "favourite": if (selected) Store.toggleFavourite(selected.id); break
        case "log": showLog(); break
        case "browse":
            if (selected && selected.protocol === "ssh" && !inTrash)
                Sessions.browse(selected.id)
            else
                say("Files are for SSH connections")
            break
        case "unmount":
            if (selected && selected.protocol === "ssh" && Sessions.isMounted(selected.id))
                Sessions.unmountFiles(selected.id)
            else
                say("No files of this connection are mounted")
            break
        case "moveGroup":
            if (selected && !inTrash)
                groupPicker.open(selected.name || selected.host, selected.group)
            break
        case "groupSettings":
            if (selected && selected.group)
                openGroup(selected.group)
            else
                say("This connection is not in a group")
            break
        case "search":
            showTab("home")
            search.forceActiveFocus()
            search.selectAll()
            break
        case "clear":
            if (deleteArmed) deleteArmed = false
            else if (query !== "") query = ""
            else if (filter !== "all") filter = "all"
            break
        case "filterAll": filter = "all"; break
        case "filterFavourites": filter = "favourites"; break
        case "filterRecent": filter = "recent"; break
        case "filterActive": filter = "active"; break
        case "newCredential": openCredential(""); break
        case "focusSidebar":
            focusArea = "sidebar"
            sidebarCursor = Math.max(0, sidebar.indexOf(filter.indexOf("group:") === 0 ? "group" : "filter",
                                                        filter.indexOf("group:") === 0 ? filter.slice(6) : filter))
            break
        case "focusList": focusList(); break
        case "sidebarDown": sidebarCursor = Math.min(sidebar.entries.length - 1, sidebarCursor + 1); break
        case "sidebarUp": sidebarCursor = Math.max(0, sidebarCursor - 1); break
        case "sidebarOpen":
            if (!sidebarEntry) break
            if (sidebarEntry.kind === "filter") { filter = sidebarEntry.value; focusList() }
            else if (sidebarEntry.kind === "group") { filter = "group:" + sidebarEntry.value; focusList() }
            else if (sidebarEntry.kind === "credential") openCredential(sidebarEntry.value)
            else if (sidebarEntry.kind === "newGroup") openGroup("")
            else if (sidebarEntry.kind === "update") Updates.install()
            else if (sidebarEntry.kind === "pluginInstall") Updates.installPlugin()
            else if (sidebarEntry.kind === "pluginUpdate") Updates.updatePlugin()
            else openCredential("")
            break
        case "sidebarDismiss":
            if (sidebarEntry && sidebarEntry.kind === "pluginInstall") {
                Updates.declinePlugin(true)
                say("Bar plugin offer hidden; ? → \"Show the bar plugin offer again\" brings it back")
            }
            break
        case "pluginOffer":
            Updates.declinePlugin(false)
            say(Updates.pluginMissing ? "Bar plugin offer shown again" : "The bar plugin is installed already")
            break
        case "sidebarSettings":
            if (sidebarEntry && sidebarEntry.kind === "group") openGroup(sidebarEntry.value)
            else if (sidebarEntry && sidebarEntry.kind === "credential") openCredential(sidebarEntry.value)
            break
        case "pin": togglePinned(); break
        case "nextTab": cycleTab(1); break
        case "previousTab": cycleTab(-1); break
        case "keys": keymapSheet.open(); break
        }
    }

    Rectangle {
        anchors.fill: parent
        color: Theme.background
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        // Header: tabs, then search and new while on the connections tab.
        Rectangle {
            id: header
            Layout.fillWidth: true
            implicitHeight: root.immersive ? 0 : tabBar.implicitHeight
            visible: !root.immersive
            color: Theme.surface

            RowLayout {
                anchors.fill: parent
                anchors.rightMargin: Theme.gap
                spacing: Theme.gap
                TabBar {
                    id: tabBar
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    clip: true
                    current: root.currentTab
                    tabs: root.tabSessions.map(function (s) { return { id: s.id, title: s.name, state: s.state } })
                    onPicked: function (id) { root.showTab(id) }
                    onClosed: function (id) { root.closeTab(id) }
                }
                Rectangle {
                    Layout.preferredWidth: Theme.chrome - 6
                    Layout.preferredHeight: Theme.chrome - 6
                    radius: Theme.radius
                    color: root.pinned ? Theme.selection : pinMouse.containsMouse ? Theme.hover : "transparent"
                    Glyph {
                        anchors.centerIn: parent
                        text: "\uf08d"
                        size: Theme.caption
                        color: root.pinned ? Theme.accent : Theme.muted
                        rotation: root.pinned ? 0 : 45
                    }
                    MouseArea {
                        id: pinMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.togglePinned()
                    }
                }
                ActionButton {
                    visible: root.currentTab === "home"
                    Layout.preferredHeight: Theme.chrome - 6
                    fontSize: Theme.caption
                    icon: "\u{f0241}"
                    text: "Quick connect"
                    hint: "o"
                    onClicked: root.openQuick()
                }
                ActionButton {
                    visible: root.currentTab === "home"
                    Layout.preferredHeight: Theme.chrome - 6
                    fontSize: Theme.caption
                    icon: "\uf067"
                    text: "New"
                    hint: "n"
                    onClicked: root.startNew()
                }
                Input {
                    id: search
                    maximumLength: Limits.address
                    visible: root.currentTab === "home"
                    Layout.preferredWidth: Math.min(260, root.width * 0.22)
                    Layout.preferredHeight: Theme.chrome - 6
                    width: Layout.preferredWidth
                    verticalPadding: 0
                    font.pixelSize: Theme.caption
                    placeholderText: "/  search"
                    text: root.query
                    onTextEdited: root.query = text
                    Keys.onPressed: function (event) {
                        if (event.key === Qt.Key_L && (event.modifiers & Qt.ControlModifier)) {
                            root.openQuick()
                            event.accepted = true
                        } else if (event.key === Qt.Key_Escape) {
                            root.query = ""
                            root.takeKeys()
                            event.accepted = true
                        } else if (event.key === Qt.Key_Down || event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                            root.takeKeys()
                            if (event.key !== Qt.Key_Down && root.shown.length === 1)
                                root.connect(root.shown[0].id)
                            event.accepted = true
                        }
                    }
                }
                // Settings, as in Flea: after a short divider, at the far right.
                Rectangle {
                    Layout.preferredWidth: 1
                    Layout.preferredHeight: Theme.chrome - 12
                    color: Theme.foreground
                    opacity: 0.12
                }
                Rectangle {
                    Layout.preferredWidth: Theme.chrome - 6
                    Layout.preferredHeight: Theme.chrome - 6
                    radius: Theme.radius
                    color: settingsPanel.opened ? Theme.selection : settingsMouse.containsMouse ? Theme.hover : "transparent"
                    SettingsGlyph {
                        anchors.centerIn: parent
                        size: Theme.caption + 3
                        color: settingsPanel.opened ? Theme.accent : settingsMouse.containsMouse ? Theme.foreground : Theme.muted
                    }
                    MouseArea {
                        id: settingsMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: settingsPanel.opened ? settingsPanel.close() : settingsPanel.open()
                    }
                }
            }
            Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Theme.foreground; opacity: 0.12 }
        }

        Item {
            id: content
            Layout.fillWidth: true
            Layout.fillHeight: true

        RowLayout {
            anchors.fill: parent
            visible: root.currentTab === "home"
            spacing: 0

            Sidebar {
                id: sidebar
                focused: root.focusArea === "sidebar" && !root.busy && root.activeFocus
                cursor: root.sidebarCursor
                Layout.preferredWidth: 210
                Layout.fillHeight: true
                filter: root.filter
                editingGroup: root.editingGroup
                creatingGroup: root.editingGroup === root.newGroup
                editingCredential: root.editingCredential
                onPicked: function (f) { if (root.busy) root.finishEdit(); root.filter = f; root.takeKeys() }
                onGroupSettingsRequested: function (name) { root.openGroup(name) }
                dragging: root.dragging !== null
                dragGroup: root.dragging ? root.dragging.group || "" : ""
                onDroppedOnGroup: function (name) { root.dropOnGroup(name) }
                onCredentialRequested: function (id) { root.openCredential(id) }
                onAboutRequested: aboutCard.open()
            }
            Rectangle { Layout.fillHeight: true; width: 1; color: Theme.hairline }

            Item {
                Layout.fillWidth: true
                Layout.fillHeight: true

                ConnectionList {
                    id: list
                    anchors.fill: parent
                    model: root.shown
                    grouped: root.grouped
                    selectedId: root.selectedId
                    onPicked: function (id) { if (!root.busy) { root.selectedId = id; root.focusList() } }
                    onActivated: function (id) { if (!root.busy) { root.selectedId = id; root.connect(id) } }
                    rowDragging: root.dragging !== null
                    dragGroup: root.dragging ? root.dragging.group || "" : ""
                    onRowDragStarted: function (id) { root.dragFrom(id) }
                    onDragMoved: function (x, y) { root.dragTo(x, y) }
                    onRowDragEnded: root.dragDone()
                    onDroppedOnGroup: function (name) { root.dropOnGroup(name) }
                }

                Column {
                    anchors.centerIn: parent
                    visible: root.shown.length === 0 && Store.connections.length > 0
                    spacing: Theme.gap
                    Text {
                        textFormat: Text.PlainText
                        anchors.horizontalCenter: parent.horizontalCenter
                        text: root.query !== "" ? "No match for “" + root.query + "”" : "Nothing here yet"
                        color: Theme.muted
                        font.family: Theme.font
                        font.pixelSize: Theme.body
                    }
                    Text {
                        textFormat: Text.PlainText
                        anchors.horizontalCenter: parent.horizontalCenter
                        text: "esc to clear"
                        color: Theme.muted
                        font.family: Theme.font
                        font.pixelSize: Theme.caption
                    }
                }
            }

            Rectangle { Layout.fillHeight: true; width: 1; color: Theme.hairline }

            Item {
                Layout.preferredWidth: root.busy ? Math.max(460, Math.min(600, root.width * 0.46))
                                                    : Math.max(340, Math.min(440, root.width * 0.36))
                Layout.fillHeight: true

                Detail {
                    anchors.fill: parent
                    visible: !root.busy
                    connection: root.selected
                    deleteArmed: root.deleteArmed
                    onConnectRequested: root.connect()
                    onEditRequested: root.startEdit()
                    onDuplicateRequested: root.duplicateSelected()
                    onDeleteRequested: root.deleteSelected()
                    onRestoreRequested: root.restoreSelected()
                    onFavouriteRequested: root.runAction("favourite")
                    onNewRequested: root.startNew()
                    onSaveQuickRequested: root.saveQuickSelected()
                }
                Editor {
                    id: editor
                    anchors.fill: parent
                    visible: root.editing
                    focus: root.editing
                    onSaved: function (c, password, touched, gatewayPassword, gatewayTouched) {
                        root.saveEdit(c, password, touched, gatewayPassword, gatewayTouched)
                    }
                    onCancelled: { root.savingQuick = ""; root.connectAfterSave = false; root.finishEdit() }
                }
                GroupEditor {
                    id: groupEditor
                    anchors.fill: parent
                    visible: root.editingGroup !== ""
                    focus: visible
                    onSaved: function (from, name, credential, newCredential, settings, apply) {
                        root.saveGroup(from, name, credential, newCredential, settings, apply)
                    }
                    onDeleted: function (name) { root.deleteGroup(name) }
                    onCancelled: { root.pendingGroupMove = []; root.finishEdit() }
                }
                CredentialEditor {
                    id: credentialEditor
                    anchors.fill: parent
                    visible: root.editingCredential !== ""
                    focus: visible
                    onSaved: function (cred, password, touched) { root.saveCredential(cred, password, touched) }
                    onDeleted: function (id) { root.deleteCredential(id) }
                    onCancelled: root.finishEdit()
                }
            }
        }

            PinnedList {
                width: root.dockWidth
                height: parent.height
                visible: root.dockWidth > 0 && root.currentTab !== "home"
                // Every connection, whatever the connections tab is searching or showing.
                model: Store.connections.slice().sort(root.byName)
                currentConnection: {
                    for (var i = 0; i < root.tabSessions.length; i++)
                        if (root.tabSessions[i].id === root.currentTab)
                            return root.tabSessions[i].connection
                    return ""
                }
                onUnpin: root.togglePinned()
                onSwitchRequested: function (id) { root.connect(id) }
                onConnectRequested: function (id) { root.connect(id) }
            }

            // Where session tabs draw: right of the docked list while pinned. Sized the same on
            // the connections tab, so a new session starts at the size it will be shown at.
            Item {
                id: sessionArea
                anchors.fill: parent
                anchors.leftMargin: root.dockWidth

                // One view per open tab, kept alive while hidden so switching is instant. Loaded by
                // URL so a missing native plugin breaks only the tabs, not the whole window.
                Repeater {
                    id: tabViews
                    model: root.openTabs
                    delegate: Loader {
                        id: tabLoader
                        required property string modelData
                        readonly property var session: {
                            for (var i = 0; i < root.tabSessions.length; i++)
                                if (root.tabSessions[i].id === modelData)
                                    return root.tabSessions[i]
                            return null
                        }
                        anchors.fill: parent
                        visible: root.currentTab === modelData
                        focus: visible
                        source: Qt.resolvedUrl("SessionView.qml")
                        onLoaded: {
                            item.session = Qt.binding(function () { return tabLoader.session })
                            item.current = Qt.binding(function () { return root.currentTab === tabLoader.modelData })
                            item.reconnectRequested.connect(function () { root.reconnect(tabLoader.session) })
                            item.closeRequested.connect(function () { root.closeTab(tabLoader.modelData) })
                            item.navigate.connect(function (where) {
                                if (where === "keys") keymapSheet.open()
                                else if (where === "quick") root.openQuick("")
                            else if (where === "window") root.popOut(tabLoader.modelData)
                            else if (where === "tab") return
                                else if (where === "home") root.showTab("home")
                                else root.cycleTab(where === "next" ? 1 : -1)
                            })
                            item.toggleFullscreen.connect(root.toggleImmersive)
                            item.togglePinned.connect(root.togglePinned)
                        }
                        Column {
                            anchors.centerIn: parent
                            visible: tabLoader.status === Loader.Error
                            spacing: Theme.gap
                            Text {
                                textFormat: Text.PlainText
                                text: "Sessions cannot be shown in a tab: the native renderer is not built."
                                color: Theme.urgent
                                font.family: Theme.font
                                font.pixelSize: Theme.body
                            }
                            Text {
                                textFormat: Text.PlainText
                                text: "Run ./install.sh, or set this connection to open in a window."
                                color: Theme.muted
                                font.family: Theme.font
                                font.pixelSize: Theme.small
                            }
                        }
                    }
                }
            }
        }

        StatusBar {
            info: root.debugStats || (root.currentIsGliff && !root.currentEnded ? (Sessions.stats[root.currentTab] || "") : "")
            id: statusBar
            Layout.fillWidth: true
            visible: !root.immersive
            // A broken connections.json stays on screen: nothing is saved until it is fixed.
            notice: root.notice || (Store.broken ? "connections.json is not valid JSON: nothing is saved until it is fixed (a copy is in connections.json.broken)" : "")
            noticeIsError: root.notice ? root.noticeIsError : Store.broken
            hints: root.currentTab !== "home" && root.currentEnded
                       ? [["⏎", "reconnect"], ["l", "log"], ["w", "close tab"], ["ctrl+alt+home", "connections"],
                          ["ctrl+alt+pgup/pgdn", "tabs"], ["ctrl+alt+k", "keys"]]
                 : root.currentTab !== "home" ? [["ctrl+alt+home", "connections"], ["ctrl+alt+pgup/pgdn", "tabs"], ["ctrl+alt+w", "close tab"]]
                                                .concat(root.currentIsSsh ? [["ctrl+shift+c/v", "copy/paste"]]
                                                        : root.currentIsGliff ? [Format.gliffKeyHint(Sessions.capturedSession === root.currentTab)]
                                                        : [["ctrl+alt+end", "ctrl+alt+del"]])
                                                .concat([["ctrl+alt+⏎", "fullscreen"], ["ctrl+alt+o", "own window"], ["ctrl+alt+p", root.pinned ? "unpin" : "pin"], ["ctrl+alt+k", "keys"]])
                 : root.logSession ? [["w", "warnings only"], ["j k", "scroll"], ["G", "end"], ["esc", "close"]]
                 : root.busy ? [["tab", "next field"], ["←→", "choose"], ["space", "toggle"], ["ctrl+s", "save"], ["esc", "cancel"], ["f1", "keys"]]
                 : root.focusArea === "sidebar" ? [["j k", "move"], ["⏎", "open"], ["s", "group settings"], ["tab", "list"], ["?", "keys"]]
                 : root.inTrash ? [["r", "restore"], ["del del", "delete for good"], ["1", "all connections"], [",", "settings"], ["?", "keys"]]
                 : root.selected && root.selected.quickRow ? [["⏎", "connect"], ["j k", "move"], ["/", "search"], ["?", "keys"]]
                 : root.selected && root.selected.quick ? [["⏎", "connect"], ["s", "save"], ["del", "forget"], ["/", "search"], ["tab", "sidebar"], ["?", "keys"]]
                 : [["⏎", "connect"], ["n", "new"], ["e", "edit"], ["s", "group"], ["/", "search"], ["tab", "sidebar"], [",", "settings"], ["?", "keys"]]
        }
    }

    // The log covers everything right of the sidebar, between header and status bar.
    LogView {
        id: logView
        visible: root.logSession !== null
        session: root.logSession
        x: root.currentTab === "home" ? 211 : root.dockWidth
        y: header.height
        width: root.width - x
        height: root.height - header.height - statusBar.height
        onClosed: root.closeLog()
    }

    // Sync runs beside the window; it waits while an editor is open and speaks in the status bar.
    Binding { target: Sync; property: "paused"; value: root.busy }
    Connections {
        target: Sync
        function onNotice(text, isError) { root.say(text, isError) }
    }

    // A synced file that would move many connections to the trash at once: the user decides.
    Rectangle {
        id: deletionCard
        visible: !!Sync.pending
        z: 95
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        anchors.bottomMargin: Theme.control * 2
        width: Math.min(560, parent.width - 2 * Theme.panelPad)
        height: cardBody.implicitHeight + 2 * Theme.panelPad
        radius: Theme.radius
        color: Theme.surface
        border.width: 1
        border.color: Theme.warning
        ColumnLayout {
            id: cardBody
            x: Theme.panelPad
            y: Theme.panelPad
            width: parent.width - 2 * Theme.panelPad
            spacing: Theme.gap
            Text {
                textFormat: Text.PlainText
                Layout.fillWidth: true
                wrapMode: Text.Wrap
                text: Sync.pending ? Sync.pending.ids.length + " connections were deleted on " + Sync.pending.system : ""
                color: Theme.foreground
                font.family: Theme.font
                font.pixelSize: Theme.title
                font.bold: true
            }
            Text {
                textFormat: Text.PlainText
                Layout.fillWidth: true
                wrapMode: Text.Wrap
                text: Sync.pending ? Sync.pending.names.join(", ")
                      + ".\n\nThat is a lot at once, so nothing happened yet. Move them to Recently deleted here too "
                      + "(restorable for 30 days), or keep them: they then go back to " + Sync.pending.system + "." : ""
                color: Theme.muted
                font.family: Theme.font
                font.pixelSize: Theme.small
            }
            RowLayout {
                Layout.fillWidth: true
                spacing: Theme.gap
                Item { Layout.fillWidth: true }
                ActionButton { text: "Keep them"; onClicked: Sync.confirmPending(false) }
                ActionButton { danger: true; text: "Move to trash"; onClicked: Sync.confirmPending(true) }
            }
        }
    }

    // GVFS's folder layer is gone (Omarchy's suspend hook, omacom/omarchy#5214, fix pending in
    // PR #14496): restarting gvfs-daemon brings it back, but disconnects other network locations,
    // so only on the user's say-so.
    property string gvfsFor: ""

    // An SSH session that ended where no "Disconnected" panel is left to ask (its tab closed, its
    // own window closed): with Settings › SSH › After a session = Ask, the manager asks here,
    // once the last session to that connection is gone and its files are still mounted.
    property var filesAsk: []      // connection ids to ask about
    property var activeSsh: ({})   // session id -> connection id, as last seen running
    Connections {
        target: Sessions
        function onSessionsChanged() {
            var now = {}
            var ended = []
            var list = Sessions.sessions
            for (var i = 0; i < list.length; i++) {
                var s = list[i]
                if (s.protocol !== "ssh")
                    continue
                if (Sessions.isActive(s))
                    now[s.id] = s.connection
                else if (root.activeSsh[s.id] !== undefined
                         && root.openTabs.indexOf(s.id) < 0 && !(s.view === "window" && s.viewer))
                    ended.push(s.connection)
            }
            root.activeSsh = now
            if (ended.length > 0 && (Store.ui.sftpOnEnd || "ask") === "ask") {
                root.filesAsk = root.filesAsk.concat(ended.filter(function (c) { return root.filesAsk.indexOf(c) < 0 }))
                Sessions.refreshMounts()
            }
        }
    }
    // Asked about: mounted, and no session to it running any more.
    readonly property string filesAskFor: {
        Sessions.mountedFiles; Sessions.sessions
        for (var i = 0; i < filesAsk.length; i++)
            if (Sessions.isMounted(filesAsk[i]) && Sessions.activeFor(filesAsk[i]).length === 0)
                return filesAsk[i]
        return ""
    }
    function filesAnswered(id) {
        filesAsk = filesAsk.filter(function (c) { return c !== id })
    }
    Rectangle {
        visible: root.filesAskFor !== "" && root.gvfsFor === ""
        z: 96
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        anchors.bottomMargin: Theme.control * 2
        width: Math.min(520, parent.width - 2 * Theme.panelPad)
        height: filesAskBody.implicitHeight + 2 * Theme.panelPad
        radius: Theme.radius
        color: Theme.surface
        border.width: 1
        border.color: Theme.hairline
        RowLayout {
            id: filesAskBody
            x: Theme.panelPad
            y: Theme.panelPad
            width: parent.width - 2 * Theme.panelPad
            spacing: Theme.gap
            Text {
                textFormat: Text.PlainText
                Layout.fillWidth: true
                wrapMode: Text.Wrap
                text: { var c = Store.get(root.filesAskFor); return "Files of " + (c ? (c.name || c.host) : "it") + " are still mounted" }
                color: Theme.foreground
                font.family: Theme.font
                font.pixelSize: Theme.small
            }
            ActionButton { text: "Keep"; onClicked: root.filesAnswered(root.filesAskFor) }
            ActionButton { primary: true; text: "Unmount"; onClicked: { var id = root.filesAskFor; Sessions.unmountFiles(id); root.filesAnswered(id) } }
        }
    }
    Connections {
        target: Sessions
        function onFilesNotice(text, isError) { root.say(text, isError) }
        function onFilesNeedGvfs(id) { root.gvfsFor = id }
    }
    Rectangle {
        visible: root.gvfsFor !== ""
        z: 96
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        anchors.bottomMargin: Theme.control * 2
        width: Math.min(600, parent.width - 2 * Theme.panelPad)
        height: gvfsBody.implicitHeight + 2 * Theme.panelPad
        radius: Theme.radius
        color: Theme.surface
        border.width: 1
        border.color: Theme.warning
        ColumnLayout {
            id: gvfsBody
            x: Theme.panelPad
            y: Theme.panelPad
            width: parent.width - 2 * Theme.panelPad
            spacing: Theme.gap
            Text {
                textFormat: Text.PlainText
                Layout.fillWidth: true
                wrapMode: Text.Wrap
                text: "The files can't open as a folder"
                color: Theme.foreground
                font.family: Theme.font
                font.pixelSize: Theme.title
                font.bold: true
            }
            Text {
                textFormat: Text.PlainText
                Layout.fillWidth: true
                wrapMode: Text.Wrap
                text: "GVFS's folder layer is gone since the last suspend (a known Omarchy issue, fixed in a pending "
                      + "update). Restarting GVFS brings it back; other network locations that are open now (SMB and "
                      + "the like) disconnect."
                color: Theme.muted
                font.family: Theme.font
                font.pixelSize: Theme.small
            }
            RowLayout {
                Layout.fillWidth: true
                spacing: Theme.gap
                Item { Layout.fillWidth: true }
                ActionButton { text: "Cancel"; onClicked: root.gvfsFor = "" }
                ActionButton { primary: true; text: "Restart GVFS"; onClicked: { Sessions.restartGvfs(root.gvfsFor); root.gvfsFor = "" } }
            }
        }
    }

    // Another system changed where connections that sign in here point: the credentials would go
    // to the new address, so nothing changed yet (bin/omaremote-session, ADDRESS_KEYS and
    // SHARING_KEYS).
    Rectangle {
        visible: Sync.pendingAddress.length > 0 && !Sync.pending
        z: 95
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        anchors.bottomMargin: Theme.control * 2
        width: Math.min(620, parent.width - 2 * Theme.panelPad)
        height: addressBody.implicitHeight + 2 * Theme.panelPad
        radius: Theme.radius
        color: Theme.surface
        border.width: 1
        border.color: Theme.warning
        ColumnLayout {
            id: addressBody
            x: Theme.panelPad
            y: Theme.panelPad
            width: parent.width - 2 * Theme.panelPad
            spacing: Theme.gap
            Text {
                textFormat: Text.PlainText
                Layout.fillWidth: true
                wrapMode: Text.Wrap
                text: Sync.pendingAddress.length === 1
                      ? Sync.pendingAddress[0].system + " changed where " + Sync.pendingAddress[0].name
                        + " connects or what it shares"
                      : (Sync.pendingAddress.length > 0 ? Sync.pendingAddress[0].system : "") + " changed where "
                        + Sync.pendingAddress.length + " connections connect or what they share"
                color: Theme.foreground
                font.family: Theme.font
                font.pixelSize: Theme.title
                font.bold: true
            }
            Text {
                textFormat: Text.PlainText
                Layout.fillWidth: true
                wrapMode: Text.Wrap
                text: Sync.pendingAddress.map(function (x) { return x.name + ":  " + x.from + "  →  " + x.to }).join("\n")
                color: Theme.foreground
                font.family: Theme.font
                font.pixelSize: Theme.small
            }
            Text {
                textFormat: Text.PlainText
                Layout.fillWidth: true
                wrapMode: Text.Wrap
                text: "This system signs in there with a saved password, a credential set or an SSH key, which "
                      + "would then go to the new address, or would share your home folder or microphone with it. "
                      + "Accept it only if you made this change yourself; keep yours and it goes back to the other "
                      + "systems."
                color: Theme.muted
                font.family: Theme.font
                font.pixelSize: Theme.small
            }
            RowLayout {
                Layout.fillWidth: true
                spacing: Theme.gap
                Item { Layout.fillWidth: true }
                ActionButton { text: "Keep mine"; onClicked: Sync.confirmAddress(false) }
                ActionButton { primary: true; text: "Accept"; onClicked: Sync.confirmAddress(true) }
            }
        }
    }

    SettingsPanel {
        id: settingsPanel
        anchors.fill: parent
        z: 90
        onClosed: {
            if (root.currentTab === "home" && !root.busy)
                root.takeKeys()
            else
                root.refocus()
        }
    }

    ImportCard {
        id: importCard
        anchors.fill: parent
        z: 96
        onClosed: settingsPanel.opened ? settingsPanel.forceActiveFocus() : root.takeKeys()
    }

    GroupPicker {
        id: groupPicker
        anchors.fill: parent
        z: 90
        onChosen: function (value) { root.chooseGroup(value) }
        onClosed: root.takeKeys()
    }

    // What follows the pointer while a connection is dragged onto a group. Its corner is the
    // pointer: that is where the groups look for it.
    Item {
        id: dragProxy
        z: 200
        visible: root.draggingId !== ""
        Drag.active: root.draggingId !== ""
        Drag.keys: ["connection"]
        Rectangle {
            x: 14
            y: 6
            width: dragLabel.implicitWidth + 2 * Theme.padX
            height: dragLabel.implicitHeight + Theme.gap
            radius: Theme.radius
            color: Theme.surface
            border.width: 1
            border.color: Theme.accent
            Text {
                textFormat: Text.PlainText
                id: dragLabel
                anchors.centerIn: parent
                text: root.dragging ? (root.dragging.name || root.dragging.host) : ""
                color: Theme.foreground
                font.family: Theme.font
                font.pixelSize: Theme.small
            }
        }
    }

    QuickConnectCard {
        id: quickCard
        anchors.fill: parent
        z: 90
        onConnectRequested: function (spec) { root.quickCardConnect(spec) }
        onClosed: root.takeKeys()
    }

    AboutCard {
        id: aboutCard
        anchors.fill: parent
        z: 90
        onClosed: {
            if (root.currentTab === "home" && !root.busy)
                root.takeKeys()
            else
                root.refocus()
        }
    }

    // The keymap sheet covers the whole window.
    KeymapSheet {
        id: keymapSheet
        anchors.fill: parent
        z: 100
        onRun: function (action) {
            root.takeKeys()
            root.runAction(action)
        }
        onClosed: {
            if (root.currentTab === "home" && !root.busy)
                root.takeKeys()
            else
                root.refocus()
        }
    }

    // Puts focus back where it belongs after an overlay: the current session, or the open editor.
    function refocus() {
        if (currentTab !== "home") {
            var view = tabViews.itemAt(openTabs.indexOf(currentTab))
            if (view && view.item)
                view.item.focusDesktop()
        } else if (editing) editor.forceActiveFocus()
        else if (editingGroup) groupEditor.forceActiveFocus()
        else if (editingCredential) credentialEditor.forceActiveFocus()
        else root.takeKeys()
    }

    // Surface a failure the moment it happens, even while looking at another connection.
    property var seenFailures: ({})
    Connections {
        target: Sessions
        function onSessionsChanged() {
            var next = {}
            for (var i = 0; i < Sessions.sessions.length; i++) {
                var s = Sessions.sessions[i]
                if (s.state === "failed") {
                    next[s.id] = true
                    if (!root.seenFailures[s.id] && root.ready)
                        root.say(s.name + ": " + (s.error || "connection failed"), true)
                }
            }
            root.seenFailures = next
            root.adoptTabs()
            root.ready = true
        }
    }
    property bool ready: false
    // `omaremote open <name>` while the app was not running: connect once sessions are known.
    onReadyChanged: {
        if (ready && Quickshell.env("OMAREMOTE_OPEN"))
            Qt.callLater(function () { root.openNamed(Quickshell.env("OMAREMOTE_OPEN")) })
        if (ready && Quickshell.env("OMAREMOTE_QUICK") === "1")
            Qt.callLater(function () { root.openQuick("") })
        if (ready && Quickshell.env("OMAREMOTE_ADOPT"))
            Qt.callLater(function () { root.adoptSession(Quickshell.env("OMAREMOTE_ADOPT"), Quickshell.env("OMAREMOTE_ADOPT_HOME") === "1") })
    }

    // For `omaremote open` and the Omarchy bar plugin: qs ipc --pid <pid> call omaremote open <name>.
    IpcHandler {
        target: "omaremote"
        function open(name: string): string { return root.openNamed(name) }
        function focus(): void { root.raise() }
        // omaremote quick: the quick connect card, the window brought forward.
        function quick(): void { root.raise(); root.openQuick("") }
        function adopt(id: string): string { return root.adoptSession(id, false) }
        // Into a tab, but the manager comes forward on its connections (an own window's ctrl+alt+home).
        function stash(id: string): string { return root.adoptSession(id, true) }
        // Out of its tab into a window of its own (omaremote open --window).
        function popout(id: string): string {
            if (root.openTabs.indexOf(id) >= 0) root.popOut(id)
            else root.openWindow(id)
            return "ok"
        }
        // For bin/omaremote-update, which restarts the window on the new version.
        // For bin/omaremote-update: a restart, so the tabs' sessions run on and come back.
        function quit(): void { if (root.host) root.host.quit() }
    }

    // A connection by id, then by name, then by host (names and hosts ignore case).
    function findConnection(name) {
        var want = String(name || "").trim()
        var lower = want.toLowerCase()
        var list = Store.connections
        var byId = Store.get(want)
        if (byId)
            return byId
        for (var i = 0; i < list.length; i++)
            if (String(list[i].name || "").toLowerCase() === lower)
                return list[i]
        for (var j = 0; j < list.length; j++)
            if (String(list[j].host || "").toLowerCase() === lower)
                return list[j]
        return null
    }

    // Shows the connection's running session, or connects it; brings this window forward unless
    // the session lives in its own window (connect() focuses that one).
    function openNamed(name) {
        var c = findConnection(name)
        if (!c)
            return showRunning(name) ? "ok" : "unknown connection: " + name
        var running = Sessions.activeFor(c.id)
        var ownWindow = running.length > 0 ? (!running[0].tab || running[0].view === "window")
                                           : ((c.openIn === "window" || c.openIn === "hotkey") && c.protocol !== "vnc")
        selectedId = c.id
        connect(c.id)
        if (!ownWindow)
            raise()
        return "ok"
    }

    // This window, on whichever workspace it is.
    // A running session by its connection id or its own id: still there when its connection was
    // deleted while it ran (the bar plugin names sessions by connection id).
    function showRunning(name) {
        var want = String(name || "").trim()
        var list = Sessions.sessions
        for (var i = 0; i < list.length; i++) {
            var s = list[i]
            if (!Sessions.isActive(s) || (s.connection !== want && s.id !== want))
                continue
            if (s.tab && s.view !== "window") {
                showTab(s.id)
                raise()
            } else {
                Sessions.focus(s)
            }
            return true
        }
        return false
    }

    function raise() {
        Quickshell.execDetached([Sessions.bin, "focus", "class", "omaremote"])
    }

    // Gives every live tab session a tab: ones just launched (and switches to them), and on
    // startup the ones still running from before, which reattach.
    function adoptTabs() {
        var pending = pendingTabs.slice()
        var add = []
        var focus = ""
        var windows = pendingWindows.slice()
        for (var i = 0; i < Sessions.sessions.length; i++) {
            var s = Sessions.sessions[i]
            if (!s.tab || openTabs.indexOf(s.id) >= 0 || add.indexOf(s.id) >= 0)
                continue
            var forWindow = windows.indexOf(s.connection)
            if (forWindow >= 0 && s.view !== "window") {
                windows.splice(forWindow, 1)
                pendingWindows = windows
                s.view = "window" // until the window claims it, so this pass does not take it
                openWindow(s.id)
                continue
            }
            if (s.view === "window")
                continue
            var waited = pending.indexOf(s.connection)
            if (waited >= 0) {
                pending.splice(waited, 1)
                add.push(s.id)
                focus = s.id
            } else if (!ready && Sessions.isActive(s)) {
                add.push(s.id)
            }
        }
        if (add.length === 0)
            return
        pendingTabs = pending
        openTabs = openTabs.concat(add)
        if (focus)
            showTab(focus)
    }

    // Driven by the snapshot hook in boot/shell.qml: new, edit, down, connect, filter:<f>, query:<q>,
    // run:<keymap action>, focus (logs which item has the keyboard), update:<version> (as if GitHub had it).
    property string debugStats: ""
    function debugAction(a) {
        var parts = a.split(":")
        if (a === "new") startNew()
        else if (a === "edit") startEdit()
        else if (a === "down") move(1)
        else if (a === "connect") connect()
        else if (a === "delete") deleteSelected()
        else if (a === "log") showLog()
        else if (a === "keys") keymapSheet.open()
        else if (parts[0] === "settings") settingsPanel.open(parts[1] || "")
        else if (a === "about") aboutCard.open()
        else if (parts[0] === "quickcard") openQuick(parts.slice(1).join(":"))
        else if (parts[0] === "quickset") quickCard[parts[1]] = parts[2] === "true" ? true : parts.slice(2).join(":")
        else if (a === "drag") { draggingId = selectedId; dragProxy.x = 140; dragProxy.y = 250 }
        else if (parts[0] === "move") moveToGroup([selectedId], parts.slice(1).join(":"))
        else if (parts[0] === "renamegroup") Store.renameGroup(parts[1], parts[2])
        else if (parts[0] === "deletegroup") deleteGroup(parts[1])
        else if (parts[0] === "gname") groupEditor.name = parts.slice(1).join(":")
        else if (a === "movenew") chooseGroup(newGroup)
        else if (parts[0] === "quickentry") selectedId = Store.quickConnect(Format.quickSpec(parts.slice(1).join(":"), true))
        else if (a === "gvfscard") gvfsFor = selectedId
        else if (a === "filescard") { Sessions.mountedFiles = [selectedId]; filesAsk = [selectedId] }
        else if (a === "settingsend") settingsPanel.scrollToEnd()
        // stats:<words, comma separated> shows a Gliff stats line in the bar; statscard opens its card.
        else if (parts[0] === "stats") debugStats = parts.slice(1).join(":").split(",").join(" ")
        else if (a === "statscard") statusBar.statsOpen = true
        else if (parts[0] === "ui") {
            var v = parts.slice(2).join(":")
            try { v = JSON.parse(v) } catch (e) {} // a JSON value, else the text
            Store.setUi(parts[1], v)
        }
        else if (parts[0] === "importcard") Sync.scanForeign(parts.slice(1).join(":").split(","), "sample")
        else if (a === "addresscard") Sync.pendingAddress = [{ system: "laptop", id: "c-1", name: "File Server", from: "files.acme.lan", to: "files.example.net" }]
        else if (a === "enter") keymapSheet.runPicked()
        else if (parts[0] === "walk") {
            // Walks the focus chain the way Tab does, n steps.
            for (var t = 0; t < parseInt(parts[1]); t++) {
                var w = root.Window.window
                var next = w.activeFocusItem ? w.activeFocusItem.nextItemInFocusChain(true) : null
                if (next) next.forceActiveFocus(Qt.TabFocusReason)
            }
        }
        else if (parts[0] === "type") { for (var i = 0; i < parts[1].length; i++) keymapSheet.query += parts[1][i] }
        else if (parts[0] === "winsize") {
            // winsize:WxH, a small screen.
            var wh = parts[1].split("x")
            root.Window.window.width = parseInt(wh[0])
            root.Window.window.height = parseInt(wh[1])
        }
        else if (a === "sidebar") runAction("focusSidebar")
        else if (parts[0] === "group") openGroup(parts.slice(1).join(":"))
        else if (parts[0] === "pick") editor.pickCredential(parts[1])
        else if (parts[0] === "set") editor.set(parts[1], parts.slice(2).join(":"))
        else if (a === "save") (editingGroup ? groupEditor : editingCredential ? credentialEditor : editor).save()
        else if (parts[0] === "cred") openCredential(parts[1] === "new" ? "" : parts[1])
        else if (a === "pin") togglePinned()
        else if (a === "popout") popOut(currentTab)
        else if (parts[0] === "run") runAction(parts[1])
        else if (parts[0] === "update") { Updates.latest = parts.slice(1).join(":"); Updates.newer = true }
        else if (a === "plugin-missing") { Updates.pluginSupported = true; Updates.pluginInstalled = false }
        else if (a === "plugin-newer") { Updates.pluginSupported = true; Updates.pluginNewer = true }
        else if (a === "focus") {
            // Which item has the keyboard, and its parents: for chasing keys that go nowhere.
            var chain = []
            for (var f = root.Window.window.activeFocusItem; f; f = f.parent)
                chain.push(String(f).split("(")[0] + (f.visible ? "" : "[hidden]"))
            console.log("FOCUS " + (chain.join(" < ") || "nothing"))
        }
        else if (parts[0] === "tab") showTab(parts[1] === "1" ? openTabs[0] : parts[1])
        else if (parts[0] === "filter") filter = parts.slice(1).join(":")
        else if (parts[0] === "create") { startNew(); editor.set("host", parts[1]); editor.set("group", "Lab"); editor.save() }
        else if (parts[0] === "query") query = parts.slice(1).join(":")
        else if (parts[0] === "select") selectedId = parts[1]
        else if (parts[0] === "scroll") editor.children[0].children[1].contentY = parseInt(parts[1])
    }

    Component.onCompleted: root.takeKeys()
}
