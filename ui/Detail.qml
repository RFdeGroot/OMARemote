import QtQuick
import QtQuick.Layouts
import qs.Commons
import "js/Format.js" as Format

// The selected connection: what it will do, how to start it, and its sessions.
Rectangle {
    id: root
    property var connection: null
    property bool deleteArmed: false
    signal connectRequested()
    signal editRequested()
    signal duplicateRequested()
    signal deleteRequested()
    signal restoreRequested()
    // A connection in Recently deleted: it can come back or go for good, nothing else.
    readonly property bool inTrash: !!connection && !!connection.trashedAt
    // A quick connection (typed in search, not saved) and the "Connect to …" row before it exists.
    readonly property bool quick: !!connection && !!connection.quick
    readonly property bool quickRow: !!connection && !!connection.quickRow
    signal favouriteRequested()
    signal newRequested()
    signal saveQuickRequested()

    color: Theme.surface

    readonly property var sessions: { Sessions.sessions; return connection ? Sessions.forConnection(connection.id) : [] }
    readonly property bool running: sessions.some(Sessions.isActive)

    component Fact: Column {
        property string label: ""
        property string value: ""
        visible: value !== ""
        width: parent ? parent.width : 0
        spacing: 1
        Text {
            textFormat: Text.PlainText
            text: parent.label
            color: Theme.muted
            font.family: Theme.font
            font.pixelSize: Theme.caption
        }
        Text {
            textFormat: Text.PlainText
            text: parent.value
            width: parent.width
            wrapMode: Text.Wrap
            color: Theme.foreground
            font.family: Theme.font
            font.pixelSize: Theme.small
        }
    }

    // Nothing to show: either the library is empty or the filter hides everything.
    Column {
        visible: root.connection === null
        anchors.centerIn: parent
        width: parent.width - 2 * Theme.panelPad
        spacing: Theme.gap
        Glyph {
            anchors.horizontalCenter: parent.horizontalCenter
            text: ""
            size: Theme.display * 1.6
            color: Theme.hairline
        }
        Text {
            textFormat: Text.PlainText
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            text: Store.connections.length === 0 ? "No connections yet" : "Nothing selected"
            color: Theme.foreground
            font.family: Theme.font
            font.pixelSize: Theme.title
        }
        Text {
            textFormat: Text.PlainText
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            text: Store.connections.length === 0 ? "Add a Windows PC or server to get started." : "Pick a connection from the list."
            color: Theme.muted
            font.family: Theme.font
            font.pixelSize: Theme.small
        }
        Item { width: 1; height: Theme.gap }
        ActionButton {
            anchors.horizontalCenter: parent.horizontalCenter
            primary: true
            icon: ""
            text: "New connection"
            hint: "n"
            onClicked: root.newRequested()
        }
    }

    Flickable {
        id: scrollPane
        visible: root.connection !== null
        anchors.fill: parent
        anchors.margins: Theme.panelPad
        contentHeight: body.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        ScrollHint { flickable: scrollPane }

        ColumnLayout {
            id: body
            width: parent.width
            spacing: Theme.gap * 1.5

            RowLayout {
                spacing: Theme.gap * 1.5
                Layout.fillWidth: true
                Rectangle {
                    implicitWidth: Theme.display * 2
                    implicitHeight: Theme.display * 2
                    radius: Theme.radius
                    color: Theme.selection
                    Glyph {
                        anchors.centerIn: parent
                        text: root.connection && root.connection.protocol === "ssh" ? "" : root.connection && root.connection.protocol === "gliff" ? "" : ""
                        size: Theme.display
                        color: Theme.accent
                    }
                }
                Column {
                    Layout.fillWidth: true
                    spacing: 2
                    Text {
                        textFormat: Text.PlainText
                        width: parent.width
                        elide: Text.ElideRight
                        text: root.connection ? (root.connection.name || root.connection.host) : ""
                        color: Theme.foreground
                        font.family: Theme.font
                        font.pixelSize: Theme.heading
                        font.bold: true
                    }
                    Text {
                        textFormat: Text.PlainText
                        width: parent.width
                        elide: Text.ElideRight
                        text: root.connection ? String(root.connection.protocol || "rdp").toUpperCase() + " · " + Format.address(root.connection) : ""
                        color: Theme.muted
                        font.family: Theme.font
                        font.pixelSize: Theme.small
                    }
                }
                // Favourite: hollow until it is one, then filled like the star in the list.
                Rectangle {
                    id: star
                    visible: !root.inTrash && !root.quick && !root.quickRow
                    readonly property bool on: !!root.connection && !!root.connection.favourite
                    Layout.alignment: Qt.AlignTop
                    implicitWidth: starRow.implicitWidth + 2 * Theme.gap
                    implicitHeight: Theme.hitMin + Theme.gap
                    radius: Theme.radius
                    color: starMouse.containsMouse ? Theme.hover : "transparent"
                    Row {
                        id: starRow
                        anchors.centerIn: parent
                        spacing: Theme.gap
                        Text {
                            textFormat: Text.PlainText
                            visible: starMouse.containsMouse
                            anchors.verticalCenter: parent.verticalCenter
                            text: "f"
                            color: Theme.muted
                            font.family: Theme.font
                            font.pixelSize: Theme.caption
                        }
                        Glyph {
                            anchors.verticalCenter: parent.verticalCenter
                            text: star.on ? "\uf005" : "\uf006"
                            size: Theme.title
                            color: star.on ? Theme.accent : (starMouse.containsMouse ? Theme.foreground : Theme.muted)
                        }
                    }
                    MouseArea {
                        id: starMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.favouriteRequested()
                    }
                }
            }

            Text {
                textFormat: Text.PlainText
                Layout.fillWidth: true
                visible: root.inTrash
                wrapMode: Text.Wrap
                text: !root.inTrash ? "" : "Deleted " + Format.ago(Math.floor(root.connection.trashedAt / 1000))
                      + (root.connection.trashedFrom !== "local" ? " on " + root.connection.trashedFrom : "")
                      + ". Kept for 30 days, with its user name and password, then deleted for good."
                color: Theme.muted
                font.family: Theme.font
                font.pixelSize: Theme.small
            }

            ActionButton {
                Layout.fillWidth: true
                implicitHeight: Theme.control * 1.3
                primary: true
                icon: root.inTrash ? "" : root.running ? "\uf2d0" : "\uf04b"
                text: root.inTrash ? "Restore" : root.running ? "Show session" : "Connect"
                hint: root.inTrash ? "r" : "⏎"
                onClicked: root.inTrash ? root.restoreRequested() : root.connectRequested()
            }

            Flow {
                Layout.fillWidth: true
                visible: root.inTrash
                spacing: Theme.gap
                ActionButton {
                    icon: ""
                    danger: true
                    text: root.deleteArmed ? "Press again: gone for good" : "Delete now"
                    hint: "del"
                    onClicked: root.deleteRequested()
                }
            }

            Text {
                textFormat: Text.PlainText
                Layout.fillWidth: true
                visible: root.quick || root.quickRow
                wrapMode: Text.Wrap
                text: root.quickRow ? "Not saved: connects with what you typed, and asks for the password."
                                    : "A quick connection: kept on this system only, not synced. Save it to keep it in your list."
                color: Theme.muted
                font.family: Theme.font
                font.pixelSize: Theme.small
            }

            Flow {
                Layout.fillWidth: true
                visible: root.quick
                spacing: Theme.gap
                ActionButton { icon: "\uf0c7"; text: "Save as connection"; hint: "s"; onClicked: root.saveQuickRequested() }
                ActionButton {
                    visible: !!root.connection && root.connection.protocol === "ssh"
                    icon: "\uf07c"
                    text: "Browse files"
                    hint: "b"
                    onClicked: Sessions.browse(root.connection.id)
                }
                ActionButton { icon: ""; danger: true; text: "Forget"; hint: "del"; onClicked: root.deleteRequested() }
            }

            Flow {
                Layout.fillWidth: true
                visible: !root.inTrash && !root.quick && !root.quickRow
                spacing: Theme.gap
                ActionButton { icon: ""; text: "Edit"; hint: "e"; onClicked: root.editRequested() }
                ActionButton { icon: ""; text: "Duplicate"; hint: "d"; onClicked: root.duplicateRequested() }
                ActionButton {
                    visible: !!root.connection && root.connection.protocol === "ssh"
                    icon: "\uf07c"
                    text: "Browse files"
                    hint: "b"
                    onClicked: Sessions.browse(root.connection.id)
                }
                ActionButton {
                    visible: !!root.connection && root.connection.protocol === "ssh"
                             && (Sessions.mountedFiles, Sessions.isMounted(root.connection.id))
                    icon: "\uf052"
                    text: "Unmount files"
                    hint: "u"
                    onClicked: Sessions.unmountFiles(root.connection.id)
                }
                ActionButton {
                    icon: ""
                    danger: true
                    text: root.deleteArmed ? "Press again to delete" : "Delete"
                    hint: "del"
                    onClicked: root.deleteRequested()
                }
            }

            // Sessions of this connection, newest first.
            Column {
                Layout.fillWidth: true
                visible: root.sessions.length > 0
                spacing: Theme.gap * 0.75
                Text {
                    textFormat: Text.PlainText
                    text: "SESSIONS"
                    color: Theme.muted
                    font.family: Theme.font
                    font.pixelSize: Theme.caption
                    font.bold: true
                    font.letterSpacing: 1
                }
                Repeater {
                    model: root.sessions
                    delegate: Rectangle {
                        required property var modelData
                        readonly property bool live: Sessions.isActive(modelData)
                        readonly property color tone: modelData.state === "connected" ? Theme.success
                                                    : modelData.state === "connecting" ? Theme.warning
                                                    : modelData.state === "failed" ? Theme.urgent : Theme.muted
                        width: parent.width
                        height: sessionBody.implicitHeight + 2 * Theme.gap
                        radius: Theme.radius
                        color: Theme.raised
                        border.width: 1
                        border.color: Util.alpha(tone, 0.4)
                        Column {
                            id: sessionBody
                            x: Theme.gap
                            y: Theme.gap
                            width: parent.width - 2 * Theme.gap
                            spacing: Theme.gap * 0.5
                            Row {
                                spacing: 6
                                Glyph { text: ""; size: Theme.caption - 2; color: tone; anchors.verticalCenter: parent.verticalCenter }
                                Text {
                                    textFormat: Text.PlainText
                                    text: (modelData.state === "connected" ? "Connected" : modelData.state === "connecting" ? (modelData.stage || "Connecting") + "…"
                                          : modelData.state === "failed" ? "Failed" : "Ended")
                                          + (modelData.auth ? " · " + modelData.auth : "")
                                          + " · " + Format.clock(modelData.started)
                                          + (modelData.ended ? "–" + Format.clock(modelData.ended) : "")
                                    color: Theme.foreground
                                    font.family: Theme.font
                                    font.pixelSize: Theme.small
                                }
                            }
                            Text {
                                textFormat: Text.PlainText
                                visible: !!modelData.error
                                width: parent.width
                                wrapMode: Text.Wrap
                                text: modelData.error || ""
                                color: Theme.urgent
                                font.family: Theme.font
                                font.pixelSize: Theme.small
                            }
                            Row {
                                spacing: Theme.gap
                                ActionButton {
                                    visible: live
                                    text: "Disconnect"
                                    danger: true
                                    implicitHeight: Theme.control * 0.85
                                    onClicked: Sessions.stop(modelData.id)
                                }
                                ActionButton {
                                    text: "Log"
                                    implicitHeight: Theme.control * 0.85
                                    onClicked: Sessions.openLog(modelData)
                                }
                                ActionButton {
                                    visible: !live
                                    text: "Dismiss"
                                    implicitHeight: Theme.control * 0.85
                                    onClicked: Sessions.forget(modelData.id)
                                }
                            }
                        }
                    }
                }
            }

            Rectangle { Layout.fillWidth: true; height: 1; color: Theme.hairline }

            Column {
                Layout.fillWidth: true
                spacing: Theme.gap
                Fact {
                    label: "Account"
                    value: {
                        var c = root.connection
                        if (!c)
                            return ""
                        if (c.protocol === "ssh" || c.protocol === "gliff")
                            return c.username ? c.username : "from ~/.ssh/config, else yours"
                        var who = Format.account(c) || "asks when connecting"
                        if (c.credentialSource === "group")
                            return c.secretId ? who + "  (from group " + c.group + ")" : "asks when connecting (group " + c.group + " has no credentials)"
                        if (c.credentialSource === "set")
                            return who + "  (credential set)"
                        return who
                    }
                }
                readonly property bool ssh: !!root.connection && (root.connection.protocol === "ssh" || root.connection.protocol === "gliff")
                Fact {
                    label: parent.ssh ? "Sign in" : "Password"
                    value: !root.connection ? "" : parent.ssh ? "keys and ssh-agent; ssh asks for anything else"
                         : !root.connection.savePassword ? "asks when connecting"
                         : Sessions.passwordStored(root.connection) === false ? "not stored yet" : "stored in keyring"
                }
                Fact {
                    readonly property bool terminal: parent.ssh && root.connection.protocol === "ssh"
                    label: terminal ? "Opens in" : "Display"
                    value: !root.connection ? "" : terminal ? Format.openInLabel(root.connection)
                         : Format.displayLabel(root.connection, Sessions.monitorScale)
                }
                Fact { label: "Devices"; value: root.connection && (!parent.ssh || root.connection.protocol === "gliff") ? Format.devicesLabel(root.connection) : "" }
                Fact { label: "Key"; value: parent.ssh ? (root.connection.sshKey || "default (agent and ~/.ssh)") : "" }
                Fact { label: "ssh options"; value: parent.ssh ? (root.connection.sshArgs || "") : "" }
                Fact { label: "Gateway"; value: root.connection && !parent.ssh ? root.connection.gateway : "" }
                Fact { label: "Group"; value: root.connection ? root.connection.group : "" }
                Fact { label: "Last connected"; value: root.connection ? Format.ago(root.connection.lastConnected) : "" }
            }
        }
    }
}
