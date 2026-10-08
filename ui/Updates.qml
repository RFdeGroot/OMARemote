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

    function check() {
        if (version === "" || Quickshell.env("OMAREMOTE_NO_UPDATE_CHECK") === "1" || Quickshell.env("OMAREMOTE_SNAPSHOT"))
            return
        if (!checker.running)
            checker.running = true
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

    Component.onCompleted: check()
}
