import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Ui as Kit
import "js/Format.js" as Format

// Quick connect (o, ctrl+l, the button beside New, `omaremote quick`): an address, its protocol
// (guessed while typing until picked by hand) and how to sign in, connected without saving.
// RDP and VNC sign in with a credential set or ask when connecting; SSH takes a user name and a
// key. A credential set is never picked for the user: it sends that password to the typed server.
// "Also save it" opens the editor on it instead, and saving there connects.
FocusScope {
    id: root
    property bool opened: false
    property string address: ""
    property string protocol: "rdp"
    property bool protocolPicked: false
    property string credential: "custom"
    property string sshUser: ""
    property bool sshUserTyped: false
    property string sshKey: ""
    property bool saveToo: false
    // {protocol, host, port, username, domain, credential, sshKey, save}
    signal connectRequested(var spec)
    signal closed()

    readonly property var parsed: Format.quickSpec(address, true)
    readonly property var defaultPorts: ({ rdp: 3389, vnc: 5900, ssh: 22 })
    readonly property bool isSsh: protocol === "ssh"

    // What gets connected: the address as typed, under the protocol shown.
    readonly property var spec: {
        var p = parsed
        if (!p)
            return null
        return {
            protocol: protocol, host: p.host,
            port: p.portGiven ? p.port : defaultPorts[protocol],
            username: isSsh ? sshUser.trim() : (credential === "custom" ? p.username : ""),
            domain: !isSsh && credential === "custom" ? p.domain : "",
            credential: isSsh ? "custom" : credential,
            sshKey: isSsh ? sshKey : "",
            save: saveToo
        }
    }

    readonly property var credentialOptions: {
        Store.credentials
        var out = [{ value: "custom", label: "Ask when connecting" }]
        for (var i = 0; i < Store.credentials.length; i++)
            out.push({ value: Store.credentials[i].id, label: Store.credentialLabel(Store.credentials[i]) })
        return out
    }
    readonly property var keyOptions: {
        var out = [{ value: "", label: "Default (the agent and ~/.ssh)" }]
        for (var i = 0; i < Sessions.sshKeys.length; i++) {
            var k = Sessions.sshKeys[i]
            out.push({ value: k.path, label: k.name + (k.kind === "agent" ? "  (agent)" : "") })
        }
        return out
    }
    // The newest quick connections, to fill the card in again with one click.
    readonly property var recent: {
        var list = Store.quickConnections.slice().sort(function (a, b) { return (b.used || 0) - (a.used || 0) })
        return list.slice(0, 4)
    }

    function open(text) {
        address = text || ""
        protocol = "rdp"
        protocolPicked = false
        credential = "custom"
        sshUser = ""
        sshUserTyped = false
        sshKey = ""
        saveToo = false
        follow()
        opened = true
        addressField.forceActiveFocus()
        addressField.selectAll()
    }
    function close() {
        opened = false
        closed()
    }
    // The protocol and SSH user follow the address until the user sets them.
    function follow() {
        var p = Format.quickSpec(address, true)
        if (!p)
            return
        if (!protocolPicked || p.schemeGiven)
            protocol = p.protocol
        if (!sshUserTyped)
            sshUser = p.username
    }
    function pickProtocol(v) {
        protocol = v
        protocolPicked = true
    }
    function fill(c) {
        var port = Number(c.port) !== defaultPorts[c.protocol] ? ":" + c.port : ""
        address = (c.username && c.protocol === "ssh" ? c.username + "@" : "") + c.host + port
        protocol = c.protocol
        protocolPicked = true
        credential = c.protocol !== "ssh" && c.credential && c.credential !== "custom" ? c.credential : "custom"
        sshUser = c.protocol === "ssh" ? (c.username || "") : ""
        sshUserTyped = false
        sshKey = c.sshKey || ""
        addressField.forceActiveFocus()
    }
    function submit() {
        if (!spec) {
            addressField.forceActiveFocus()
            return
        }
        var s = spec
        opened = false
        connectRequested(s)
    }

    visible: opened

    Keys.onPressed: function (event) {
        if (event.key === Qt.Key_Escape) {
            root.close()
            event.accepted = true
        } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            root.submit()
            event.accepted = true
        }
    }

    Rectangle {
        anchors.fill: parent
        color: Util.alpha(Theme.background, 0.6)
        MouseArea { anchors.fill: parent; onClicked: root.close() }
    }

    Rectangle {
        anchors.centerIn: parent
        width: Math.min(480, parent.width - 2 * Theme.panelPad)
        height: body.implicitHeight + 2 * Theme.panelPad
        radius: Theme.radius
        color: Theme.surface
        border.width: 1
        border.color: Theme.hairline
        MouseArea { anchors.fill: parent }

        ColumnLayout {
            id: body
            anchors.fill: parent
            anchors.margins: Theme.panelPad
            spacing: Theme.gap * 1.5

            RowLayout {
                spacing: Theme.gap
                Glyph { text: "\u{f0241}"; size: Theme.title; color: Theme.accent }
                Text {
                    textFormat: Text.PlainText
                    Layout.fillWidth: true
                    text: "Quick connect"
                    color: Theme.foreground
                    font.family: Theme.font
                    font.pixelSize: Theme.body
                    font.bold: true
                }
            }

            GridLayout {
                Layout.fillWidth: true
                columns: 2
                columnSpacing: Theme.gap * 2
                rowSpacing: Theme.gap

                Text { textFormat: Text.PlainText; text: "Address"; color: Theme.foreground; font.family: Theme.font; font.pixelSize: Theme.small }
                Input {
                    id: addressField
                    Layout.fillWidth: true
                    placeholderText: "pc.acme.lan, alex@server, vnc://10.0.0.5"
                    text: root.address
                    onTextEdited: { root.address = text; root.follow() }
                    KeyNavigation.tab: protocolPicker
                }

                Text { textFormat: Text.PlainText; text: "Protocol"; color: Theme.foreground; font.family: Theme.font; font.pixelSize: Theme.small }
                Segment {
                    id: protocolPicker
                    Layout.fillWidth: true
                    value: root.protocol
                    options: [{ value: "rdp", label: "RDP" }, { value: "vnc", label: "VNC" }, { value: "ssh", label: "SSH" }]
                    onPicked: function (v) { root.pickProtocol(v) }
                }

                Text { textFormat: Text.PlainText; visible: !root.isSsh; text: "Sign in"; color: Theme.foreground; font.family: Theme.font; font.pixelSize: Theme.small }
                Kit.Dropdown {
                    id: credentialPicker
                    visible: !root.isSsh
                    Layout.fillWidth: true
                    showLabel: false
                    value: root.credential
                    options: root.credentialOptions
                    onChanged: function (v) { root.credential = v }
                }
                // A credential set goes to whatever server was typed: said where it is chosen.
                Item { width: 1; height: 1; visible: credentialNote.visible }
                Text {
                    id: credentialNote
                    textFormat: Text.PlainText
                    Layout.fillWidth: true
                    visible: !root.isSsh && root.credential !== "custom"
                    wrapMode: Text.Wrap
                    text: "Its saved password goes to the server you typed."
                    color: Theme.muted
                    font.family: Theme.font
                    font.pixelSize: Theme.caption
                }

                Text { textFormat: Text.PlainText; visible: root.isSsh; text: "User name"; color: Theme.foreground; font.family: Theme.font; font.pixelSize: Theme.small }
                Input {
                    visible: root.isSsh
                    Layout.fillWidth: true
                    placeholderText: "from ~/.ssh/config, else yours"
                    text: root.sshUser
                    onTextEdited: { root.sshUser = text; root.sshUserTyped = true }
                }
                Text { textFormat: Text.PlainText; visible: root.isSsh; text: "Key"; color: Theme.foreground; font.family: Theme.font; font.pixelSize: Theme.small }
                Kit.Dropdown {
                    visible: root.isSsh
                    Layout.fillWidth: true
                    showLabel: false
                    value: root.sshKey
                    options: root.keyOptions
                    onChanged: function (v) { root.sshKey = v }
                }

                Text { textFormat: Text.PlainText; visible: root.recent.length > 0; text: "Recent"; color: Theme.muted; font.family: Theme.font; font.pixelSize: Theme.small }
                Flow {
                    visible: root.recent.length > 0
                    Layout.fillWidth: true
                    spacing: Theme.gap
                    Repeater {
                        model: root.recent
                        delegate: ActionButton {
                            required property var modelData
                            fontSize: Theme.caption
                            text: (modelData.protocol === "ssh" && modelData.username ? modelData.username + "@" : "") + modelData.host
                            onClicked: root.fill(modelData)
                        }
                    }
                }

                Item { width: 1; height: 1 }
                RowLayout {
                    Layout.fillWidth: true
                    spacing: Theme.gap
                    Check {
                        checked: root.saveToo
                        onToggled: root.saveToo = !root.saveToo
                    }
                    Text {
                        textFormat: Text.PlainText
                        Layout.fillWidth: true
                        text: "Also save it as a connection"
                        color: Theme.foreground
                        font.family: Theme.font
                        font.pixelSize: Theme.small
                        MouseArea { anchors.fill: parent; onClicked: root.saveToo = !root.saveToo }
                    }
                }
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: Theme.gap
                Text {
                    textFormat: Text.PlainText
                    Layout.fillWidth: true
                    visible: root.address.trim() !== "" && !root.parsed
                    elide: Text.ElideRight
                    text: "Not an address"
                    color: Theme.urgent
                    font.family: Theme.font
                    font.pixelSize: Theme.caption
                }
                Item { Layout.fillWidth: true; visible: !(root.address.trim() !== "" && !root.parsed) }
                ActionButton { text: "Cancel"; hint: "esc"; onClicked: root.close() }
                ActionButton {
                    primary: true
                    enabled: !!root.spec
                    text: root.saveToo ? "Next: name it" : "Connect"
                    hint: "⏎"
                    onClicked: root.submit()
                }
            }
        }
    }
}
