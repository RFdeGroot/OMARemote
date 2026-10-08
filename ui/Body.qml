import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import "js/Format.js" as Format

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

    readonly property var shown: {
        var list = Store.connections.filter(function (c) {
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

    readonly property var selected: { Store.connections; return Store.get(root.selectedId) }

    // Keep a selection whenever there is something to select.
    onShownChanged: {
        for (var i = 0; i < shown.length; i++)
            if (shown[i].id === selectedId)
                return
        if (!editing)
            selectedId = shown.length > 0 ? shown[0].id : ""
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

    function connect(id) {
        var c = Store.get(id || selectedId)
        if (!c)
            return
        // RDP allows one session per user: a second connect would end the first, so go to it instead.
        var running = Sessions.activeFor(c.id)
        if (running.length > 0) {
            if (running[0].tab)
                showTab(running[0].id)
            else
                Sessions.focus(running[0])
            say("Switched to " + (c.name || c.host))
            return
        }
        if (c.openIn === "window" && c.protocol !== "vnc") {
            say("Connecting to " + (c.name || c.host) + "…")
            Sessions.launch(c.id)
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
        Quickshell.execDetached(["hyprctl", "dispatch", "fullscreen", "0"])
    }

    function startNew() {
        var c = Store.blankIn(filter.indexOf("group:") === 0 ? filter.slice(6) : "")
        closePanels()
        editing = true
        editor.load(c)
    }

    function startEdit() {
        if (!selected)
            return
        closePanels()
        editing = true
        editor.load(selected)
        if (selected.savePassword)
            Sessions.checkSecret(selected.secretKind, selected.secretId)
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
        editingGroup = name
        groupEditor.load(name)
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

    function saveGroup(name, credential, newCredential, settings, apply) {
        if (credential === "new")
            credential = createCredential(newCredential.username, newCredential.domain,
                                          newCredential.savePassword, newCredential.password)
        Store.setGroup(name, credential, settings, apply)
        say("Saved group " + name + (apply ? ", applied to " + Store.membersOf(name) + " connections" : ""))
        finishEdit()
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

    function saveEdit(c, password, passwordTouched) {
        if (c.credential === "new")
            c.credential = createCredential(c.username.trim(), String(c.domain || "").trim(), !!c.savePassword, password)
        var id = Store.upsert(c)
        if (c.credential !== "custom" || !c.savePassword)
            Sessions.clearSecret("connection", id) // no password of its own any more
        else if (passwordTouched && password !== "")
            Sessions.setSecret("connection", id, password)
        if (query !== "" && !Format.matches(c, query))
            query = ""
        if (filter !== "all" && filter !== "favourites" && filter !== "group:" + c.group)
            filter = "all"
        selectedId = id
        say("Saved " + (c.name || c.host))
        finishEdit()
    }

    function deleteSelected() {
        if (!selected)
            return
        if (!deleteArmed) {
            deleteArmed = true
            disarm.restart()
            say("Press delete again to remove " + selected.name, true)
            return
        }
        var c = selected
        Sessions.clearSecret("connection", c.id)
        Store.remove(c.id)
        deleteArmed = false
        say("Removed " + c.name)
    }

    function duplicateSelected() {
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

    // Where list-or-sidebar keys go on the connections tab.
    property string focusArea: "list"
    property int sidebarCursor: 0

    // Every key here goes through Keymap.qml, the same table the keymap sheet (?) draws.
    Keys.onPressed: function (event) {
        if (root.currentTab !== "home")
            return
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
        var action = Keymap.match(event, context)
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
        switch (action) {
        case "connect": connect(); break
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
            else openCredential("")
            break
        case "sidebarSettings":
            if (sidebarEntry && sidebarEntry.kind === "group") openGroup(sidebarEntry.value)
            else if (sidebarEntry && sidebarEntry.kind === "credential") openCredential(sidebarEntry.value)
            break
        case "pin": togglePinned(); break
        case "nextTab": cycleTab(1); break
        case "previousTab": cycleTab(-1); break
        case "keys": keymapSheet.open(); break
        case "quit": if (root.host) root.host.quit(); break
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
                Input {
                    id: search
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
                        if (event.key === Qt.Key_Escape) {
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
                ActionButton {
                    visible: root.currentTab === "home"
                    Layout.preferredHeight: Theme.chrome - 6
                    fontSize: Theme.caption
                    icon: "\uf067"
                    text: "New"
                    hint: "n"
                    onClicked: root.startNew()
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
                editingCredential: root.editingCredential
                onPicked: function (f) { if (root.busy) root.finishEdit(); root.filter = f; root.takeKeys() }
                onGroupSettingsRequested: function (name) { root.openGroup(name) }
                onCredentialRequested: function (id) { root.openCredential(id) }
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
                }

                Column {
                    anchors.centerIn: parent
                    visible: root.shown.length === 0 && Store.connections.length > 0
                    spacing: Theme.gap
                    Text {
                        anchors.horizontalCenter: parent.horizontalCenter
                        text: root.query !== "" ? "No match for “" + root.query + "”" : "Nothing here yet"
                        color: Theme.muted
                        font.family: Theme.font
                        font.pixelSize: Theme.body
                    }
                    Text {
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
                    onFavouriteRequested: root.runAction("favourite")
                    onNewRequested: root.startNew()
                }
                Editor {
                    id: editor
                    anchors.fill: parent
                    visible: root.editing
                    focus: root.editing
                    onSaved: function (c, password, touched) { root.saveEdit(c, password, touched) }
                    onCancelled: root.finishEdit()
                }
                GroupEditor {
                    id: groupEditor
                    anchors.fill: parent
                    visible: root.editingGroup !== ""
                    focus: visible
                    onSaved: function (name, credential, newCredential, settings, apply) {
                        root.saveGroup(name, credential, newCredential, settings, apply)
                    }
                    onCancelled: root.finishEdit()
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
                                text: "Sessions cannot be shown in a tab: the native renderer is not built."
                                color: Theme.urgent
                                font.family: Theme.font
                                font.pixelSize: Theme.body
                            }
                            Text {
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
            id: statusBar
            Layout.fillWidth: true
            visible: !root.immersive
            notice: root.notice
            noticeIsError: root.noticeIsError
            hints: root.currentTab !== "home" ? [["ctrl+alt+home", "connections"], ["ctrl+alt+pgup/pgdn", "tabs"],
                                                 ["ctrl+alt+end", "ctrl+alt+del"], ["ctrl+alt+⏎", "fullscreen"], ["ctrl+alt+p", root.pinned ? "unpin" : "pin"], ["ctrl+alt+k", "keys"]]
                 : root.logSession ? [["w", "warnings only"], ["j k", "scroll"], ["G", "end"], ["esc", "close"]]
                 : root.busy ? [["tab", "next field"], ["←→", "choose"], ["space", "toggle"], ["ctrl+s", "save"], ["esc", "cancel"], ["f1", "keys"]]
                 : root.focusArea === "sidebar" ? [["j k", "move"], ["⏎", "open"], ["s", "group settings"], ["tab", "list"], ["?", "keys"]]
                 : [["⏎", "connect"], ["n", "new"], ["e", "edit"], ["s", "group"], ["/", "search"], ["tab", "sidebar"], ["?", "keys"]]
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
    onReadyChanged: if (ready && Quickshell.env("OMAREMOTE_OPEN"))
        Qt.callLater(function () { root.openNamed(Quickshell.env("OMAREMOTE_OPEN")) })

    // For `omaremote open` and the Omarchy bar plugin: qs ipc --pid <pid> call omaremote open <name>.
    IpcHandler {
        target: "omaremote"
        function open(name: string): string { return root.openNamed(name) }
        function focus(): void { root.raise() }
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
            return "unknown connection: " + name
        var running = Sessions.activeFor(c.id)
        var ownWindow = running.length > 0 ? !running[0].tab : (c.openIn === "window" && c.protocol !== "vnc")
        selectedId = c.id
        connect(c.id)
        if (!ownWindow)
            raise()
        return "ok"
    }

    // This window, on whichever workspace it is.
    function raise() {
        Quickshell.execDetached([Sessions.bin, "focus", "class", "omaremote"])
    }

    // Gives every live tab session a tab: ones just launched (and switches to them), and on
    // startup the ones still running from before, which reattach.
    function adoptTabs() {
        var pending = pendingTabs.slice()
        var add = []
        var focus = ""
        for (var i = 0; i < Sessions.sessions.length; i++) {
            var s = Sessions.sessions[i]
            if (!s.tab || openTabs.indexOf(s.id) >= 0 || add.indexOf(s.id) >= 0)
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
    // run:<keymap action>, focus (logs which item has the keyboard).
    function debugAction(a) {
        var parts = a.split(":")
        if (a === "new") startNew()
        else if (a === "edit") startEdit()
        else if (a === "down") move(1)
        else if (a === "connect") connect()
        else if (a === "delete") deleteSelected()
        else if (a === "log") showLog()
        else if (a === "keys") keymapSheet.open()
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
        else if (a === "sidebar") runAction("focusSidebar")
        else if (parts[0] === "group") openGroup(parts.slice(1).join(":"))
        else if (parts[0] === "pick") editor.pickCredential(parts[1])
        else if (parts[0] === "set") editor.set(parts[1], parts.slice(2).join(":"))
        else if (a === "save") (editingGroup ? groupEditor : editingCredential ? credentialEditor : editor).save()
        else if (parts[0] === "cred") openCredential(parts[1] === "new" ? "" : parts[1])
        else if (a === "pin") togglePinned()
        else if (parts[0] === "run") runAction(parts[1])
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
        else if (parts[0] === "scroll") editor.children[0].children[1].contentY = parseInt(parts[1])
    }

    Component.onCompleted: root.takeKeys()
}
