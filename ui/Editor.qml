import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Ui as Kit

// Create or edit one connection. Works on a copy (`d`); nothing is stored until save.
Rectangle {
    id: root
    property var d: ({})
    property string password: ""
    property bool passwordTouched: false
    property string error: ""
    signal saved(var connection, string password, bool passwordTouched)
    signal cancelled()

    color: Theme.surface

    readonly property bool isNew: !d.id
    // Fields for user, domain and password show for these two; the rest name a credential set.
    readonly property bool ownCredentials: d.credential === "custom" || d.credential === "new"
    readonly property bool hasStoredPassword: d.credential === "custom" && !!d.id && Sessions.secrets["connection:" + d.id] === true
    readonly property var groupInfo: { Store.groupSettings; Store.credentials; return Store.group(d.group) }

    readonly property var credentialOptions: {
        Store.credentials
        var out = []
        var groupCred = Store.credential(groupInfo.credential)
        if (groupCred || d.credential === "inherit")
            out.push({ value: "inherit", label: "Inherited from group" + (groupCred ? " (" + Store.credentialLabel(groupCred) + ")" : " (none set)") })
        for (var i = 0; i < Store.credentials.length; i++)
            out.push({ value: Store.credentials[i].id, label: Store.credentialLabel(Store.credentials[i]) })
        out.push({ value: "custom", label: "Specify below" })
        out.push({ value: "new", label: "+ New credential set…" })
        return out
    }

    // True when a setting is the group's value rather than the connection's own.
    function fromGroup(key) {
        var settings = groupInfo.settings
        return settings[key] !== undefined && String(settings[key]) === String(d[key])
    }

    function pickCredential(value) {
        var next = Object.assign({}, d)
        next.credential = value
        if (value === "new") {
            next.username = ""
            next.domain = ""
            next.savePassword = true
        } else if (value === "custom") {
            var own = Store.storedGet(d.id)
            next.username = own && own.username !== undefined ? own.username : ""
            next.domain = own && own.domain !== undefined ? own.domain : ""
            next.savePassword = !!(own && own.savePassword)
        }
        password = ""
        passwordTouched = false
        d = next
    }

    // Moving into a group that has credentials follows them, unless this connection has its own.
    function changeGroup(name) {
        var next = Object.assign({}, d)
        next.group = name
        var g = Store.group(name)
        if (g.credential && d.credential === "custom" && !d.username)
            next.credential = "inherit"
        d = next
    }

    function load(connection) {
        d = JSON.parse(JSON.stringify(connection))
        password = ""
        passwordTouched = false
        error = ""
        flick.contentY = 0
        nameField.forceActiveFocus()
    }

    function set(key, value) {
        var next = Object.assign({}, d)
        next[key] = value
        d = next
    }

    function save() {
        var c = Object.assign({}, d)
        c.host = String(c.host || "").trim()
        if (!c.host) {
            error = "A host name or address is required."
            hostField.forceActiveFocus()
            return
        }
        if (!c.name.trim())
            c.name = c.host
        var port = parseInt(c.port)
        c.port = port > 0 && port < 65536 ? port : 3389
        if (c.credential === "new" && !String(c.username || "").trim()) {
            error = "A credential set needs a user name."
            userField.forceActiveFocus()
            return
        }
        c.width = Math.max(640, parseInt(c.width) || 1920)
        c.height = Math.max(480, parseInt(c.height) || 1080)
        saved(c, password, passwordTouched)
    }

    Keys.onPressed: function (event) {
        if (event.key === Qt.Key_Escape) {
            root.cancelled()
            event.accepted = true
        } else if (event.key === Qt.Key_S && (event.modifiers & Qt.ControlModifier)) {
            root.save()
            event.accepted = true
        } else if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter) && (event.modifiers & Qt.ControlModifier)) {
            root.save()
            event.accepted = true
        }
    }

    component Section: Text {
        Layout.fillWidth: true
        Layout.topMargin: Theme.gap
        color: Theme.muted
        font.family: Theme.font
        font.pixelSize: Theme.caption
        font.bold: true
        font.letterSpacing: 1
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        Text {
            Layout.fillWidth: true
            Layout.margins: Theme.panelPad
            Layout.bottomMargin: Theme.gap
            text: root.isNew ? "New connection" : "Edit " + (root.d.name || root.d.host || "")
            elide: Text.ElideRight
            color: Theme.foreground
            font.family: Theme.font
            font.pixelSize: Theme.heading
            font.bold: true
        }

        Flickable {
            id: flick
            Layout.fillWidth: true
            Layout.fillHeight: true
            contentHeight: form.implicitHeight + Theme.panelPad
            clip: true
            boundsBehavior: Flickable.StopAtBounds

            ColumnLayout {
                id: form
                x: Theme.panelPad
                width: flick.width - 2 * Theme.panelPad
                spacing: Theme.gap

                Section { text: "GENERAL"; Layout.topMargin: 0 }
                FormRow {
                    label: "Name"
                    Input {
                        id: nameField
                        placeholderText: "Work PC"
                        text: root.d.name || ""
                        onTextEdited: root.set("name", text)
                        KeyNavigation.tab: hostField
                    }
                }
                FormRow {
                    label: "Host"
                    RowLayout {
                        width: parent.width
                        spacing: Theme.gap
                        Input {
                            id: hostField
                            Layout.fillWidth: true
                            placeholderText: "pc.example.com"
                            text: root.d.host || ""
                            onTextEdited: { root.set("host", text); root.error = "" }
                            KeyNavigation.tab: portField
                        }
                        Input {
                            id: portField
                            Layout.preferredWidth: 72
                            width: 72
                            placeholderText: "3389"
                            text: String(root.d.port || 3389)
                            validator: IntValidator { bottom: 1; top: 65535 }
                            onTextEdited: root.set("port", text)
                            KeyNavigation.tab: groupField
                        }
                    }
                }
                FormRow {
                    label: "Group"
                    help: "Shown in the sidebar"
                    Input {
                        id: groupField
                        placeholderText: "optional"
                        text: root.d.group || ""
                        onTextEdited: root.changeGroup(text.trim())
                        KeyNavigation.tab: userField
                    }
                }

                Section { text: "SIGN IN" }
                FormRow {
                    label: "Credentials"
                    Kit.Dropdown {
                        id: credentialPicker
                        width: parent.width
                        showLabel: false
                        value: root.d.credential || "custom"
                        options: root.credentialOptions
                        onChanged: function (v) { root.pickCredential(v) }
                        KeyNavigation.tab: root.ownCredentials ? userField : null
                    }
                }
                FormRow {
                    label: "User name"
                    visible: root.ownCredentials
                    Input {
                        id: userField
                        placeholderText: root.d.credential === "new" ? "administrator" : "asks when connecting"
                        text: root.d.username || ""
                        onTextEdited: root.set("username", text)
                        KeyNavigation.tab: domainField
                    }
                }
                FormRow {
                    label: "Domain"
                    visible: root.ownCredentials
                    Input {
                        id: domainField
                        placeholderText: "optional, e.g. corp.lan"
                        text: root.d.domain || ""
                        onTextEdited: root.set("domain", text)
                        KeyNavigation.tab: passwordField
                    }
                }
                FormRow {
                    label: "Password"
                    visible: root.ownCredentials
                    Input {
                        id: passwordField
                        password: true
                        placeholderText: root.hasStoredPassword ? "•••••• stored — type to replace"
                                       : root.d.savePassword ? "password" : "asked when connecting"
                        text: root.password
                        onTextEdited: {
                            root.password = text
                            root.passwordTouched = true
                            // Typing a password means keeping it.
                            if (text !== "" && !root.d.savePassword)
                                root.set("savePassword", true)
                        }
                    }
                }
                FormRow {
                    label: "Save credentials"
                    help: root.d.credential === "new" ? "As a set others can use" : "Password in your keyring"
                    visible: root.ownCredentials
                    Check {
                        checked: !!root.d.savePassword
                        onToggled: root.set("savePassword", !checked)
                    }
                }
                FormRow {
                    label: "Password"
                    visible: !root.ownCredentials
                    Text {
                        width: parent.width
                        topPadding: 6
                        wrapMode: Text.Wrap
                        text: {
                            var c = Store.resolve(root.d)
                            if (!c.secretId)
                                return "No credential set: asks when connecting"
                            if (!c.savePassword)
                                return "Asked when connecting (the set keeps no password)"
                            var stored = Sessions.passwordStored(c)
                            return stored === false ? "The set has no stored password yet" : "Stored in keyring with the set"
                        }
                        color: Theme.muted
                        font.family: Theme.font
                        font.pixelSize: Theme.small
                    }
                }

                Section { text: "DISPLAY" }
                FormRow {
                    inherited: root.fromGroup("openIn")
                    label: "Open in"
                    help: "Window for multi-monitor"
                    Segment {
                        value: root.d.openIn || "tab"
                        options: [{ value: "tab", label: "Tab" }, { value: "window", label: "Own window" }]
                        onPicked: function (v) { root.set("openIn", v) }
                    }
                }
                FormRow {
                    inherited: root.fromGroup("display")
                    label: "Resolution"
                    Segment {
                        value: root.d.display || "fit"
                        options: [{ value: "fit", label: "Fit window" }, { value: "fullscreen", label: "Fullscreen" }, { value: "fixed", label: "Fixed" }]
                        onPicked: function (v) { root.set("display", v) }
                    }
                }
                FormRow {
                    inherited: root.fromGroup("width") && root.fromGroup("height")
                    label: "Size"
                    help: "Scaled to the window"
                    visible: root.d.display === "fixed"
                    RowLayout {
                        width: parent.width
                        spacing: Theme.gap
                        Input {
                            Layout.preferredWidth: 80
                            width: 80
                            text: String(root.d.width || 1920)
                            validator: IntValidator { bottom: 640; top: 8192 }
                            onTextEdited: root.set("width", text)
                        }
                        Text { text: "×"; color: Theme.muted; font.family: Theme.font; font.pixelSize: Theme.body }
                        Input {
                            Layout.preferredWidth: 80
                            width: 80
                            text: String(root.d.height || 1080)
                            validator: IntValidator { bottom: 480; top: 8192 }
                            onTextEdited: root.set("height", text)
                        }
                        Item { Layout.fillWidth: true }
                    }
                }
                FormRow {
                    inherited: root.fromGroup("scale")
                    label: "Scale"
                    help: "Auto follows Hyprland, now " + Sessions.monitorScale + "%"
                    Segment {
                        value: String(root.d.scale || "auto")
                        options: [{ value: "auto", label: "Auto" }, { value: "100", label: "100" }, { value: "125", label: "125" },
                                  { value: "150", label: "150" }, { value: "175", label: "175" }, { value: "200", label: "200" }]
                        onPicked: function (v) { root.set("scale", v) }
                    }
                }
                FormRow {
                    inherited: root.fromGroup("multimon")
                    label: "All monitors"
                    Check {
                        checked: !!root.d.multimon
                        onToggled: root.set("multimon", !checked)
                    }
                }

                Section { text: "DEVICES" }
                FormRow {
                    inherited: root.fromGroup("clipboard")
                    label: "Clipboard"
                    Check {
                        checked: !!root.d.clipboard
                        onToggled: root.set("clipboard", !checked)
                    }
                }
                FormRow {
                    inherited: root.fromGroup("audio")
                    label: "Sound"
                    Segment {
                        value: root.d.audio || "local"
                        options: [{ value: "local", label: "Here" }, { value: "remote", label: "On remote" }, { value: "off", label: "Off" }]
                        onPicked: function (v) { root.set("audio", v) }
                    }
                }
                FormRow {
                    inherited: root.fromGroup("microphone")
                    label: "Microphone"
                    Check {
                        checked: !!root.d.microphone
                        onToggled: root.set("microphone", !checked)
                    }
                }
                FormRow {
                    inherited: root.fromGroup("homeDrive")
                    label: "Home folder"
                    help: "Shared as a drive"
                    Check {
                        checked: !!root.d.homeDrive
                        onToggled: root.set("homeDrive", !checked)
                    }
                }
                FormRow {
                    inherited: root.fromGroup("grabKeyboard")
                    label: "Super key"
                    help: "Send to remote instead of Hyprland"
                    Check {
                        checked: !!root.d.grabKeyboard
                        onToggled: root.set("grabKeyboard", !checked)
                    }
                }

                Section { text: "CONNECTION" }
                FormRow {
                    inherited: root.fromGroup("security")
                    label: "Security"
                    Segment {
                        value: root.d.security || "auto"
                        options: [{ value: "auto", label: "Auto" }, { value: "nla", label: "NLA" }, { value: "tls", label: "TLS" }, { value: "rdp", label: "RDP" }]
                        onPicked: function (v) { root.set("security", v) }
                    }
                }
                FormRow {
                    inherited: root.fromGroup("network")
                    label: "Network"
                    Segment {
                        value: root.d.network || "auto"
                        options: [{ value: "auto", label: "Auto" }, { value: "lan", label: "LAN" }, { value: "broadband", label: "Broadband" }, { value: "modem", label: "Slow" }]
                        onPicked: function (v) { root.set("network", v) }
                    }
                }
                FormRow {
                    inherited: root.fromGroup("ignoreCert")
                    label: "Ignore certificate"
                    help: "Skip the server identity check"
                    Check {
                        checked: !!root.d.ignoreCert
                        onToggled: root.set("ignoreCert", !checked)
                    }
                }
                FormRow {
                    inherited: root.fromGroup("gateway")
                    label: "Gateway"
                    help: "RD Gateway, optional"
                    Input {
                        placeholderText: "gateway.example.com"
                        text: root.d.gateway || ""
                        onTextEdited: root.set("gateway", text)
                    }
                }
                FormRow {
                    inherited: root.fromGroup("gatewayUser")
                    label: "Gateway user"
                    visible: !!(root.d.gateway || "").trim()
                    Input {
                        placeholderText: "same as above"
                        text: root.d.gatewayUser || ""
                        onTextEdited: root.set("gatewayUser", text)
                    }
                }
                FormRow {
                    inherited: root.fromGroup("kdc")
                    label: "Kerberos KDC"
                    help: "Found automatically; list DCs to pin them"
                    Input {
                        placeholderText: "auto  (dc1.corp.lan, dc2.corp.lan)"
                        text: root.d.kdc || ""
                        onTextEdited: root.set("kdc", text)
                    }
                }
                FormRow {
                    inherited: root.fromGroup("extraArgs")
                    label: "Extra arguments"
                    help: "Passed to FreeRDP as-is"
                    Input {
                        placeholderText: "/kbd:layout:0x409"
                        text: root.d.extraArgs || ""
                        onTextEdited: root.set("extraArgs", text)
                    }
                }
            }
        }

        Rectangle { Layout.fillWidth: true; height: 1; color: Theme.hairline }

        RowLayout {
            Layout.fillWidth: true
            Layout.margins: Theme.gap * 1.5
            Layout.leftMargin: Theme.panelPad
            Layout.rightMargin: Theme.panelPad
            spacing: Theme.gap
            Text {
                Layout.fillWidth: true
                text: root.error
                wrapMode: Text.WordWrap
                color: Theme.urgent
                font.family: Theme.font
                font.pixelSize: Theme.small
            }
            ActionButton { text: "Cancel"; hint: "esc"; onClicked: root.cancelled() }
            ActionButton { primary: true; text: "Save"; hint: "ctrl+s"; onClicked: root.save() }
        }
    }
}
