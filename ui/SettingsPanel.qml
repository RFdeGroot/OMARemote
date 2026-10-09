import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.Commons
import "js/Format.js" as Format

// The settings, Flea's panel in shape: one floating card over the window, a rail of sections and
// a pane beside it. Opened with "," or the sliders button in the top bar; esc closes it.
FocusScope {
    id: root
    property bool opened: false
    property string section: "sync"
    signal closed()

    readonly property var sections: [
        { id: "sync", label: "Sync", icon: "" },
        { id: "updates", label: "Updates", icon: "" },
        { id: "about", label: "About", icon: "" }
    ]

    function open(which) {
        if (which)
            section = which
        opened = true
        rail.forceActiveFocus()
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
        width: Math.min(680, parent.width - 2 * Theme.panelPad)
        height: Math.min(560, parent.height - 2 * Theme.panelPad)
        radius: Theme.radius
        color: Theme.surface
        border.width: 1
        border.color: Theme.hairline
        MouseArea { anchors.fill: parent } // clicks on the card stay on it

        ColumnLayout {
            anchors.fill: parent
            spacing: 0

            RowLayout {
                Layout.fillWidth: true
                Layout.margins: Theme.panelPad
                Layout.bottomMargin: Theme.gap
                SettingsGlyph { size: Theme.title; color: Theme.accent }
                Text {
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
                                width: parent.width
                                placeholderText: Sync.systemName
                                text: Store.ui.sync && Store.ui.sync.system || ""
                                onEditingFinished: Sync.set("system", text.trim())
                            }
                        }
                        FormRow {
                            visible: root.section === "sync"
                            label: "Sync every"
                            help: "And after every change here"
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
                                + "out. Importing adds new connections and updates changed ones; it never removes any."
                        }
                        FormRow {
                            visible: root.section === "sync"
                            label: "File"
                            help: "The last one used; the buttons open the file chooser"
                            Input {
                                id: exportPath
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
                                onClicked: Sync.exportVia(exportPath.text || "~/omaremote-connections.json")
                            }
                            ActionButton {
                                text: "Import…"
                                icon: ""
                                onClicked: Sync.importVia(exportPath.text || "~/omaremote-connections.json")
                            }
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

                        // ------------------------------------------------ About
                        Heading { visible: root.section === "about"; text: "OMAREMOTE" }
                        Fact { visible: root.section === "about"; label: "Version"; value: (Updates.version || "dev") + (Updates.checkout ? " (a checkout)" : " (package)") }
                        Fact { visible: root.section === "about"; label: "Connections"; value: Store.path }
                        Fact { visible: root.section === "about"; label: "Sessions and logs"; value: (Quickshell.env("XDG_RUNTIME_DIR") || "/run/user/…") + "/omaremote/sessions" }
                        Fact {
                            visible: root.section === "about"
                            label: "Sync file"
                            value: Sync.enabled ? Sync.folder + "/" + (Store.ui.sync && Store.ui.sync.system || Sync.systemName) + ".omaremote.json" : "no sync folder set"
                        }
                        RowLayout {
                            visible: root.section === "about"
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
        Layout.fillWidth: true
        Layout.topMargin: Theme.gap
        color: Theme.muted
        font.family: Theme.font
        font.pixelSize: Theme.caption
        font.bold: true
        font.letterSpacing: 1
    }
    component Note: Text {
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
        Text { text: parent.label; color: Theme.muted; font.family: Theme.font; font.pixelSize: Theme.caption }
        Text {
            text: parent.value
            width: parent.width
            wrapMode: Text.WrapAnywhere
            color: Theme.foreground
            font.family: Theme.font
            font.pixelSize: Theme.small
        }
    }
}
