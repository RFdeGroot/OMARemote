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
    signal newRequested()

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
            text: parent.label
            color: Theme.muted
            font.family: Theme.font
            font.pixelSize: Theme.caption
        }
        Text {
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
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            text: Store.connections.length === 0 ? "No connections yet" : "Nothing selected"
            color: Theme.foreground
            font.family: Theme.font
            font.pixelSize: Theme.title
        }
        Text {
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
        visible: root.connection !== null
        anchors.fill: parent
        anchors.margins: Theme.panelPad
        contentHeight: body.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds

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
                        text: ""
                        size: Theme.display
                        color: Theme.accent
                    }
                }
                Column {
                    Layout.fillWidth: true
                    spacing: 2
                    Text {
                        width: parent.width
                        elide: Text.ElideRight
                        text: root.connection ? (root.connection.name || root.connection.host) : ""
                        color: Theme.foreground
                        font.family: Theme.font
                        font.pixelSize: Theme.heading
                        font.bold: true
                    }
                    Text {
                        width: parent.width
                        elide: Text.ElideRight
                        text: root.connection ? "RDP · " + Format.address(root.connection) : ""
                        color: Theme.muted
                        font.family: Theme.font
                        font.pixelSize: Theme.small
                    }
                }
            }

            ActionButton {
                Layout.fillWidth: true
                implicitHeight: Theme.control * 1.3
                primary: true
                icon: root.running ? "\uf2d0" : "\uf04b"
                text: root.running ? "Show session" : "Connect"
                hint: "⏎"
                onClicked: root.connectRequested()
            }

            Flow {
                Layout.fillWidth: true
                spacing: Theme.gap
                ActionButton { icon: ""; text: "Edit"; hint: "e"; onClicked: root.editRequested() }
                ActionButton { icon: ""; text: "Duplicate"; hint: "d"; onClicked: root.duplicateRequested() }
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
                        var who = Format.account(c) || "asks when connecting"
                        if (c.credentialSource === "group")
                            return c.secretId ? who + "  (from group " + c.group + ")" : "asks when connecting (group " + c.group + " has no credentials)"
                        if (c.credentialSource === "set")
                            return who + "  (credential set)"
                        return who
                    }
                }
                Fact {
                    label: "Password"
                    value: !root.connection ? "" : !root.connection.savePassword ? "asks when connecting"
                         : Sessions.passwordStored(root.connection) === false ? "not stored yet" : "stored in keyring"
                }
                Fact { label: "Display"; value: root.connection ? Format.displayLabel(root.connection, Sessions.monitorScale) : "" }
                Fact { label: "Devices"; value: root.connection ? Format.devicesLabel(root.connection) : "" }
                Fact { label: "Gateway"; value: root.connection ? root.connection.gateway : "" }
                Fact { label: "Group"; value: root.connection ? root.connection.group : "" }
                Fact { label: "Last connected"; value: root.connection ? Format.ago(root.connection.lastConnected) : "" }
            }
        }
    }
}
