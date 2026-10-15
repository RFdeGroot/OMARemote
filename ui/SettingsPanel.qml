import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.Commons
import "js/Format.js" as Format
import "js/Limits.js" as Limits

// The settings, Flea's panel in shape: one floating card over the window, a rail of sections and
// a pane beside it. Opened with "," or the sliders button in the top bar; esc closes it.
FocusScope {
    id: root
    property bool opened: false
    property string section: "sync"
    signal closed()

    readonly property var sections: [
        { id: "sync", label: "Sync", icon: "" },
        { id: "ssh", label: "SSH", icon: "" },
        { id: "keyboard", label: "Keyboard", icon: "\uf084" },
        { id: "hotkeys", label: "Hotkeys", icon: "\uf11c" },
        { id: "updates", label: "Updates", icon: "" },
        { id: "files", label: "Files", icon: "\uf07b" }
    ]

    // Opens on the section asked for, else on the first one: never where it was last left.
    function open(which) {
        measure()
        section = which || sections[0].id
        opened = true
        rail.forceActiveFocus()
    }
    // The tallest section's form, measured once on opening: the card keeps that height whichever
    // section is shown, so switching never resizes it.
    property real tallest: 0
    function measure() {
        var was = section
        var most = 0
        for (var i = 0; i < sections.length; i++) {
            section = sections[i].id
            most = Math.max(most, form.implicitHeight)
        }
        section = was
        tallest = most
    }

    // Snapshots (Body.debugAction settingsend): the bottom of the section.
    function scrollToEnd() {
        pane.contentY = Math.max(0, pane.contentHeight - pane.height)
    }
    function close() {
        opened = false
        closed()
    }

    visible: opened

    Keys.onPressed: function (event) {
        if (event.key === Qt.Key_Escape) {
            root.close()
            event.accepted = true
        }
    }

    // The window behind, dimmed; a click there closes.
    Rectangle {
        anchors.fill: parent
        color: Util.alpha(Theme.background, 0.6)
        MouseArea { anchors.fill: parent; onClicked: root.close() }
    }

    Rectangle {
        id: card
        anchors.centerIn: parent
        // As tall as the tallest section needs (measure), never more than the window has: a big
        // screen gets no empty card, a small one scrolls (ScrollHint shows it). The same height for
        // every section.
        width: Math.min(760, parent.width - 2 * Theme.panelPad)
        height: Math.min(parent.height - 2 * Theme.panelPad,
                         header.implicitHeight + Theme.panelPad + Theme.gap + 1
                         + Math.max(railColumn.implicitHeight + 2 * Theme.gap, root.tallest + 2 * Theme.panelPad))
        // A new width rewraps the notes: measured again.
        onWidthChanged: if (root.opened) root.measure()
        radius: Theme.radius
        color: Theme.surface
        border.width: 1
        border.color: Theme.hairline
        MouseArea { anchors.fill: parent } // clicks on the card stay on it

        ColumnLayout {
            anchors.fill: parent
            spacing: 0

            RowLayout {
                id: header
                Layout.fillWidth: true
                Layout.margins: Theme.panelPad
                Layout.bottomMargin: Theme.gap
                SettingsGlyph { size: Theme.title; color: Theme.accent }
                Text {
                    textFormat: Text.PlainText
                    Layout.fillWidth: true
                    text: "Settings"
                    color: Theme.foreground
                    font.family: Theme.font
                    font.pixelSize: Theme.heading
                    font.bold: true
                }
                ActionButton { text: "Close"; hint: "esc"; fontSize: Theme.caption; onClicked: root.close() }
            }
            Rectangle { Layout.fillWidth: true; height: 1; color: Theme.hairline }

            RowLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true
                spacing: 0

                // Sections: j/k or the arrows move, tab goes into the pane.
                FocusScope {
                    id: rail
                    Layout.preferredWidth: 150
                    Layout.fillHeight: true
                    Keys.onPressed: function (event) {
                        var at = 0
                        for (var i = 0; i < root.sections.length; i++)
                            if (root.sections[i].id === root.section)
                                at = i
                        if (event.key === Qt.Key_J || event.key === Qt.Key_Down)
                            root.section = root.sections[Math.min(root.sections.length - 1, at + 1)].id
                        else if (event.key === Qt.Key_K || event.key === Qt.Key_Up)
                            root.section = root.sections[Math.max(0, at - 1)].id
                        else
                            return
                        event.accepted = true
                    }
                    Column {
                        id: railColumn
                        anchors.fill: parent
                        anchors.topMargin: Theme.gap
                        spacing: 2
                        Repeater {
                            model: root.sections
                            delegate: SidebarRow {
                                required property var modelData
                                width: parent.width
                                icon: modelData.icon
                                label: modelData.label
                                current: root.section === modelData.id
                                cursor: rail.activeFocus && root.section === modelData.id
                                onClicked: { root.section = modelData.id; rail.forceActiveFocus() }
                            }
                        }
                    }
                }
                Rectangle { Layout.fillHeight: true; width: 1; color: Theme.hairline }

                Flickable {
                    id: pane
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    contentHeight: form.implicitHeight + 2 * Theme.panelPad
                    clip: true
                    boundsBehavior: Flickable.StopAtBounds
                    ScrollHint { flickable: pane }

                    ColumnLayout {
                        id: form
                        x: Theme.panelPad
                        y: Theme.panelPad
                        width: pane.width - 2 * Theme.panelPad
                        spacing: Theme.gap

                        // ------------------------------------------------ Sync
                        Heading { visible: root.section === "sync"; text: "SYNC BETWEEN SYSTEMS" }
                        Note {
                            visible: root.section === "sync"
                            text: "Connections and groups go to a folder that something else keeps in step "
                                + "(Nextcloud, Syncthing, Dropbox…). Each system writes its own file there and "
                                + "merges the others; the newest change wins. User names, credential sets, "
                                + "passwords and extra arguments stay on this system. Deletions arrive in "
                                + "Recently deleted, never straight out."
                        }
                        FormRow {
                            visible: root.section === "sync"
                            label: "Folder"
                            help: "Empty: no sync"
                            RowLayout {
                                width: parent.width
                                spacing: Theme.gap
                                Input {
                                    maximumLength: Limits.path
                                    Layout.fillWidth: true
                                    placeholderText: "~/Nextcloud/OMARemote"
                                    text: Sync.folder
                                    onEditingFinished: if (text.trim() !== Sync.folder) Sync.set("folder", text.trim())
                                }
                                ActionButton { text: "Browse…"; icon: ""; fontSize: Theme.small; onClicked: Sync.browseFolder() }
                            }
                        }
                        FormRow {
                            visible: root.section === "sync"
                            label: "This system"
                            help: "Its file: " + (Store.ui.sync && Store.ui.sync.system || Sync.systemName) + ".omaremote.json"
                            Input {
                                maximumLength: Limits.name
                                width: parent.width
                                placeholderText: Sync.systemName
                                text: Store.ui.sync && Store.ui.sync.system || ""
                                onEditingFinished: Sync.set("system", text.trim())
                            }
                        }
                        FormRow {
                            visible: root.section === "sync"
                            label: "Watch the folder"
                            help: "Another system's changes show within seconds of arriving"
                            Check {
                                checked: Sync.watch
                                onToggled: Sync.set("watch", !checked)
                            }
                        }
                        FormRow {
                            visible: root.section === "sync"
                            label: "Sync every"
                            help: Sync.watch ? "A fallback: arriving files and changes here sync at once" : "And after every change here"
                            Segment {
                                value: String(Sync.interval)
                                options: [{ value: "0", label: "Off" }, { value: "5", label: "5 min" },
                                          { value: "15", label: "15 min" }, { value: "60", label: "1 hour" }]
                                onPicked: function (v) { Sync.set("interval", parseInt(v)) }
                            }
                        }
                        RowLayout {
                            visible: root.section === "sync"
                            Layout.fillWidth: true
                            spacing: Theme.gap
                            ActionButton {
                                text: Sync.busy ? "Syncing…" : "Sync now"
                                icon: ""
                                enabled_: Sync.enabled && !Sync.busy
                                onClicked: Sync.syncNow()
                            }
                            Text {
                                textFormat: Text.PlainText
                                Layout.fillWidth: true
                                wrapMode: Text.Wrap
                                text: !Sync.enabled ? "Set a folder to start"
                                    : Sync.lastError !== "" ? Sync.lastError
                                    : Sync.lastSync > 0 ? "Synced " + Format.ago(Math.floor(Sync.lastSync / 1000))
                                                          + (Sync.lastReport && Sync.summary(Sync.lastReport) ? ": " + Sync.summary(Sync.lastReport) : ", nothing new")
                                    : "Not synced yet"
                                color: Sync.lastError !== "" ? Theme.urgent : Theme.muted
                                font.family: Theme.font
                                font.pixelSize: Theme.small
                            }
                        }

                        Heading { visible: root.section === "sync"; text: "EXPORT AND IMPORT" }
                        Note {
                            visible: root.section === "sync"
                            text: "One file to carry connections and groups by hand, with the same things left "
                                + "out. Importing adds new connections and updates changed ones; it never removes any. "
                                + "Import… also takes .rdp files and Remmina profiles: those, Remmina and ~/.ssh/config "
                                + "only add what is not here yet, after showing you the list."
                        }
                        // Only without a file chooser (no xdg-desktop-portal): the path to export to or import.
                        FormRow {
                            visible: root.section === "sync" && Sync.noChooser
                            label: "File"
                            help: "No file chooser here: type the path, then Export or Import"
                            Input {
                                id: exportPath
                                maximumLength: Limits.path
                                width: parent.width
                                placeholderText: "~/omaremote-connections.json"
                                text: Store.ui.exportPath || ""
                                onEditingFinished: if (text.trim() !== (Store.ui.exportPath || "")) Store.setUi("exportPath", text.trim())
                            }
                        }
                        RowLayout {
                            visible: root.section === "sync"
                            spacing: Theme.gap
                            ActionButton {
                                text: "Export…"
                                icon: ""
                                onClicked: Sync.exportVia(exportPath.text)
                            }
                            ActionButton {
                                text: "Import…"
                                icon: ""
                                onClicked: Sync.importVia(exportPath.text)
                            }
                            ActionButton {
                                visible: Sync.remminaFolders.length > 0
                                text: "From Remmina"
                                icon: ""
                                onClicked: Sync.importRemmina()
                            }
                            ActionButton {
                                visible: Sync.sshConfigFound
                                text: "Hosts from ~/.ssh/config"
                                icon: ""
                                onClicked: Sync.importSshConfig()
                            }
                        }
                        // What happened last: whether the backup is recent, and what came in.
                        Note {
                            readonly property var ex: Store.ui.lastExport || null
                            readonly property var im: Store.ui.lastImport || null
                            visible: root.section === "sync" && (ex !== null || im !== null)
                            text: {
                                var home = Quickshell.env("HOME") || ""
                                var lines = []
                                if (ex)
                                    lines.push("Last export: " + (home && ex.file.indexOf(home + "/") === 0 ? "~" + ex.file.slice(home.length) : ex.file)
                                               + " · " + Format.ago(ex.at) + " (" + ex.connections + " connections)")
                                if (im)
                                    lines.push("Last import: " + im.what + " · " + Format.ago(im.at) + " · "
                                               + (im.added || im.updated ? im.added + " added" + (im.updated ? ", " + im.updated + " updated" : "")
                                                                         : "nothing new"))
                                return lines.join("\n")
                            }
                        }

                        // ------------------------------------------------ SSH
                        Heading { visible: root.section === "ssh"; text: "KEYS IN THE TERMINAL" }
                        Note {
                            visible: root.section === "ssh"
                            text: "OMARemote always signs in with the key chosen for a connection. To have a plain "
                                + "`ssh host` in a terminal use it too, OMARemote can keep ~/.ssh/omaremote.conf "
                                + "(one entry per connection with a key: the key, IdentitiesOnly, user and port) "
                                + "and include it from ~/.ssh/config."
                        }
                        FormRow {
                            visible: root.section === "ssh"
                            label: "Use in a terminal"
                            help: "Adds one line at the top of ~/.ssh/config (backed up first); off takes it out again"
                            Check {
                                checked: Sync.sshTerminalKeys
                                onToggled: Store.setUi("sshTerminalKeys", !checked)
                            }
                        }
                        Note {
                            visible: root.section === "ssh"
                            text: Sync.sshConfigMode === "readonly" ? "~/.ssh/config is read-only (generated or managed elsewhere), so OMARemote "
                                                                      + "leaves it alone. Add this line at its top yourself (before any Host line):\n\n    Include omaremote.conf"
                                : Sync.sshConfigMode === "auto" ? "On: ~/.ssh/config includes OMARemote's file."
                                : Sync.sshConfigMode === "manual" ? "Your ~/.ssh/config includes ~/.ssh/omaremote.conf itself: OMARemote keeps "
                                                                    + "that file current and leaves your config alone."
                                : "Off: nothing in ~/.ssh is written. To keep ~/.ssh/config to yourself and still use "
                                  + "these keys in a terminal, add this line at its top yourself (before any Host line):\n\n    Include omaremote.conf"
                            color: Theme.foreground
                        }

                        Heading { visible: root.section === "ssh"; text: "FILES" }
                        FormRow {
                            visible: root.section === "ssh"
                            label: "After a session"
                            help: "Its files still mounted when the last session to it ends"
                            Segment {
                                value: Store.ui.sftpOnEnd || "ask"
                                options: [{ value: "ask", label: "Ask" }, { value: "unmount", label: "Unmount" }, { value: "keep", label: "Keep" }]
                                onPicked: function (v) { Store.setUi("sftpOnEnd", v) }
                            }
                        }

                        // ------------------------------------------------ Keyboard
                        Heading { visible: root.section === "keyboard"; text: "SESSION KEYS" }
                        Note {
                            visible: root.section === "keyboard"
                            text: "Inside a session every key goes to the remote side, except OMARemote's own: "
                                + "the session keys with a second key (Home: back to connections, PgUp/PgDn: tabs, "
                                + "K: the keymap, …). Ctrl+Alt suits most. Where Windows reads Ctrl+Alt as AltGr "
                                + "(Polish, and German on Windows) or an app needs its Ctrl+Alt shortcuts, take "
                                + "Right Ctrl: it then never reaches the remote side, as VirtualBox's host key. "
                                + "Without a Right Ctrl (a MacBook), Ctrl+Alt+Shift."
                        }
                        FormRow {
                            visible: root.section === "keyboard"
                            label: "Session keys"
                            help: "Now: " + Keymap.cap("ctrl+alt+home") + " goes back to connections"
                            Segment {
                                value: Keymap.sessionKeys
                                options: [{ value: "ctrlalt", label: "Ctrl+Alt" }, { value: "rctrl", label: "Right Ctrl" },
                                          { value: "ctrlaltshift", label: "Ctrl+Alt+Shift" }]
                                onPicked: function (v) { Store.setUi("sessionKeys", v) }
                            }
                        }

                        // ------------------------------------------------ Hotkeys
                        Heading { visible: root.section === "hotkeys"; text: "HOTKEY WINDOWS" }
                        Note {
                            visible: root.section === "hotkeys"
                            text: "A connection that opens in a Hotkey window (Open in, in its editor) slides in on its "
                                + "shortcut, on the screen you are on, and out again on the same shortcut or " + Keymap.session("ctrl+alt+h") + ". "
                                + "It stays connected in between. Up to " + Hotkeys.limit + " connections."
                        }
                        Repeater {
                            model: root.section === "hotkeys" ? Hotkeys.hotkeyConnections : []
                            delegate: Fact {
                                required property var modelData
                                label: modelData.name || modelData.host
                                value: (modelData.hotkey || "no shortcut") + "   ·   omaremote toggle " + modelData.id
                            }
                        }
                        FormRow {
                            visible: root.section === "hotkeys"
                            label: "Write into Hyprland"
                            help: "Its own file, loaded from hyprland.lua (backed up first); off removes both"
                            Check {
                                checked: Hotkeys.writeConfig
                                onToggled: Store.setUi("hyprHotkeys", !checked)
                            }
                        }
                        Note {
                            visible: root.section === "hotkeys"
                            color: Theme.foreground
                            text: (Hotkeys.mode === "readonly"
                                   ? "hyprland.lua is read-only (generated or managed elsewhere), so OMARemote leaves it alone. "
                                     + "To use OMARemote's shortcuts file, add this line at its end yourself:\n\n    " + Hotkeys.loaderLine + "\n\n"
                                   : Hotkeys.mode === "unsupported"
                                   ? "There is no ~/.config/hypr/hyprland.lua here (an older Hyprland config), so OMARemote cannot add them. "
                                   : Hotkeys.writeConfig ? "On: Hyprland's config loads OMARemote's shortcuts. " : "Off: Hyprland's config is not touched. ")
                                + "To bind a shortcut yourself, add a line like this to ~/.config/hypr/bindings.lua, with the "
                                + "command shown above (by id: a name would show up in the list of running programs):\n\n"
                                + "    o.bind(\"SUPER + ALT + W\", \"Work PC\", \"omaremote toggle c-…\")"
                        }

                        // ------------------------------------------------ Updates
                        Heading { visible: root.section === "updates"; text: "UPDATES" }
                        FormRow {
                            visible: root.section === "updates"
                            label: "Check at start"
                            help: Updates.forcedOffline ? "Off: OMAREMOTE_NO_UPDATE_CHECK=1 is set" : "One request to GitHub"
                            Check {
                                checked: Store.ui.updateCheck !== false && !Updates.forcedOffline
                                onToggled: if (!Updates.forcedOffline) Store.setUi("updateCheck", !checked)
                            }
                        }
                        FormRow {
                            visible: root.section === "updates"
                            label: "Offer the bar plugin"
                            help: "Shown in the sidebar when it is not installed"
                            Check {
                                checked: !Store.ui.pluginDeclined
                                onToggled: Updates.declinePlugin(checked)
                            }
                        }
                        RowLayout {
                            visible: root.section === "updates"
                            spacing: Theme.gap
                            ActionButton { text: "Check now"; icon: ""; onClicked: Updates.check(true) }
                            Text {
                                textFormat: Text.PlainText
                                Layout.fillWidth: true
                                wrapMode: Text.Wrap
                                text: Updates.newer ? Updates.latest + " is available" + (Updates.checkout ? " (a checkout: git pull)" : ": the button in the sidebar installs it")
                                    : Updates.latest !== "" ? "Up to date (" + Updates.latest + " is the newest)"
                                    : "Not checked yet"
                                color: Theme.muted
                                font.family: Theme.font
                                font.pixelSize: Theme.small
                            }
                        }

                        // ------------------------------------------------ Files (About itself is AboutCard)
                        Heading { visible: root.section === "files"; text: "WHERE OMAREMOTE KEEPS THINGS" }
                        Fact { visible: root.section === "files"; label: "Connections"; value: Store.path }
                        Fact { visible: root.section === "files"; label: "Sessions and logs"; value: (Quickshell.env("XDG_RUNTIME_DIR") || "/run/user/…") + "/omaremote/sessions" }
                        Fact {
                            visible: root.section === "files"
                            label: "Sync file"
                            value: Sync.enabled ? Sync.folder + "/" + (Store.ui.sync && Store.ui.sync.system || Sync.systemName) + ".omaremote.json" : "no sync folder set"
                        }
                        RowLayout {
                            visible: root.section === "files"
                            spacing: Theme.gap
                            ActionButton { text: "GitHub"; icon: ""; onClicked: Quickshell.execDetached(["xdg-open", "https://github.com/RFdeGroot/OMARemote"]) }
                            ActionButton { text: "Report a problem"; icon: ""; onClicked: Quickshell.execDetached(["xdg-open", "https://github.com/RFdeGroot/OMARemote/issues"]) }
                        }
                    }
                }
            }
        }
    }

    component Heading: Text {
        textFormat: Text.PlainText
        Layout.fillWidth: true
        Layout.topMargin: Theme.gap
        color: Theme.muted
        font.family: Theme.font
        font.pixelSize: Theme.caption
        font.bold: true
        font.letterSpacing: 1
    }
    component Note: Text {
        textFormat: Text.PlainText
        Layout.fillWidth: true
        wrapMode: Text.Wrap
        color: Theme.muted
        font.family: Theme.font
        font.pixelSize: Theme.small
        lineHeight: 1.15
    }
    component Fact: Column {
        property string label: ""
        property string value: ""
        Layout.fillWidth: true
        spacing: 1
        Text { textFormat: Text.PlainText; text: parent.label; color: Theme.muted; font.family: Theme.font; font.pixelSize: Theme.caption }
        Text {
            textFormat: Text.PlainText
            text: parent.value
            width: parent.width
            wrapMode: Text.WrapAnywhere
            color: Theme.foreground
            font.family: Theme.font
            font.pixelSize: Theme.small
        }
    }
}
