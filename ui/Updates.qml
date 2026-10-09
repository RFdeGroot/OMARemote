pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// The version this window runs and whether GitHub has a newer release. Checked once at start, with
// one request to the GitHub releases API (OMAREMOTE_NO_UPDATE_CHECK=1 skips it). A package install
// gets the update button; a checkout only hears that a newer release exists.
Singleton {
    id: root

    readonly property string version: Quickshell.env("OMAREMOTE_VERSION") || ""
    readonly property bool checkout: Quickshell.env("OMAREMOTE_INSTALL") === "checkout"
    property string latest: ""
    property bool newer: false
    readonly property bool canUpdate: newer && !checkout

    // The Omarchy bar plugin (rfdegroot.omaremote): offered when missing, updated when GitHub has a
    // newer release. Omarchy installs and updates plugins; this only starts it in a terminal.
    property bool pluginSupported: false
    property bool pluginInstalled: true
    property bool pluginNewer: false
    // The newest plugin release, once GitHub has said; the checks while a terminal runs compare
    // against it locally instead of asking GitHub every few seconds.
    property string pluginLatest: ""
    readonly property bool pluginMissing: pluginSupported && !pluginInstalled
    // Not wanted: the install offer stays away (Store.ui.pluginDeclined, kept across restarts).
    readonly property bool pluginOffered: pluginMissing && !Store.ui.pluginDeclined

    function declinePlugin(declined) {
        Store.setUi("pluginDeclined", declined)
    }

    readonly property bool offline: Quickshell.env("OMAREMOTE_NO_UPDATE_CHECK") === "1"

    function check() {
        if (Quickshell.env("OMAREMOTE_SNAPSHOT"))
            return
        checkPlugin()
        if (version === "" || offline)
            return
        if (!checker.running)
            checker.running = true
    }

    function checkPlugin() {
        if (!pluginChecker.running)
            pluginChecker.running = true
    }

    function installPlugin() {
        terminal("omarchy plugin add https://github.com/RFdeGroot/omarchy-omaremote.git --enable")
    }

    // Omarchy refuses to update a checkout with local changes (and says so); the hint says how to
    // drop them, but dropping is the user's call, never done here.
    function updatePlugin() {
        terminal("omarchy plugin update rfdegroot.omaremote || { echo; echo 'If it reported local changes in the plugin folder: discard them with'; " +
                 "echo '  git -C ~/.config/omarchy/plugins/rfdegroot.omaremote checkout -- .'; echo 'and click Update bar plugin again.'; }")
    }

    // A floating Omarchy terminal (it can ask where to place the plugin, or show what changes);
    // checks again until it is done, so the button goes away by itself.
    function terminal(command) {
        Quickshell.execDetached(["omarchy", "launch", "floating", "terminal", "with", "presentation", command])
        pluginPoll.restart()
        pluginPollEnd.restart()
    }

    // Installs the newest release in a floating Omarchy terminal (sudo asks there); the updater then
    // restarts this window on the new version.
    function install() {
        if (!canUpdate)
            return
        Quickshell.execDetached(["omarchy", "launch", "floating", "terminal", "with", "presentation",
                                 Sessions.bin.replace(/omaremote-session$/, "omaremote-update")])
    }

    Process {
        id: checker
        command: [Sessions.bin, "update-check", root.version]
        stdout: StdioCollector { id: answer; waitForEnd: true }
        onExited: function (exitCode) {
            if (exitCode !== 0)
                return
            try {
                var result = JSON.parse(answer.text)
                root.latest = result.latest || ""
                root.newer = result.newer === true
            } catch (e) {
            }
        }
    }

    Process {
        id: pluginChecker
        command: [Sessions.bin, "plugin-check"].concat(root.offline || root.pluginLatest !== ""
                     ? ["--offline", "--latest", root.pluginLatest] : [])
        stdout: StdioCollector { id: pluginAnswer; waitForEnd: true }
        onExited: function (exitCode) {
            if (exitCode !== 0)
                return
            try {
                var result = JSON.parse(pluginAnswer.text)
                root.pluginSupported = result.supported === true
                root.pluginInstalled = result.installed === true
                root.pluginNewer = result.newer === true
                if (result.latest)
                    root.pluginLatest = result.latest
                if (root.pluginInstalled && !root.pluginNewer)
                    pluginPoll.stop()
            } catch (e) {
            }
        }
    }

    Timer { id: pluginPoll; interval: 3000; repeat: true; onTriggered: root.checkPlugin() }
    Timer { id: pluginPollEnd; interval: 600000; onTriggered: pluginPoll.stop() }

    Component.onCompleted: check()
}
