import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Ui as Kit
import "js/Limits.js" as Limits
import "js/Format.js" as Format

// Create or edit one connection. Works on a copy (`d`); nothing is stored until save.
Rectangle {
    id: root
    property var d: ({})
    property string password: ""
    property bool passwordTouched: false
    property string gatewayPassword: ""
    property bool gatewayPasswordTouched: false
    property string error: ""
    signal saved(var connection, string password, bool passwordTouched, string gatewayPassword, bool gatewayPasswordTouched)
    signal cancelled()

    color: Theme.surface

    readonly property bool isNew: !d.id
    readonly property bool isVnc: d.protocol === "vnc"
    readonly property bool isSsh: d.protocol === "ssh"
    readonly property bool isGliff: d.protocol === "gliff"
    // SSH and Gliff both sign in through ssh: a user, a key, extra options, no passwords.
    readonly property bool viaSsh: isSsh || isGliff
    readonly property bool isRdp: !isVnc && !viaSsh

    // Switching protocol moves the port along when it is still the old protocol's default.
    function pickProtocol(value) {
        var next = Object.assign({}, d)
        if (!next.port || Number(next.port) === Format.defaultPort(next.protocol))
            next.port = Format.defaultPort(value)
        next.protocol = value
        d = next
    }
    // Fields for user, domain and password show for these two; the rest name a credential set.
    readonly property bool ownCredentials: d.credential === "custom" || d.credential === "new"
    readonly property bool hasStoredPassword: d.credential === "custom" && !!d.id && Sessions.secrets["connection:" + d.id] === true
    readonly property bool hasGateway: isRdp && !!String(d.gateway || "").trim()
    readonly property bool hasStoredGatewayPassword: !!d.gatewaySavePassword && !!d.id && Sessions.secrets["gateway:" + d.id] === true
    readonly property var groupInfo: { Store.groupSettings; Store.credentials; return Store.group(d.group) }

    // The SSH key picker: ssh's own choice, the keys in ~/.ssh, the one set (wherever it is), Browse.
    readonly property var keyOptions: {
        var out = [{ value: "", label: "Default (the agent and ~/.ssh)" }]
        var listed = false
        for (var i = 0; i < Sessions.sshKeys.length; i++) {
            var k = Sessions.sshKeys[i]
            listed = listed || k.path === d.sshKey
            out.push({ value: k.path, label: k.name + (k.kind === "agent" ? "  (agent)" : "")
                                              + (k.type ? "  ·  " + k.type : "") + (k.comment ? "  ·  " + k.comment : "") })
        }
        if (d.sshKey && !listed)
            out.push({ value: d.sshKey, label: d.sshKey })
        out.push({ value: "__browse__", label: "Browse…" })
        return out
    }
    Connections {
        target: Sync
        function onKeyPicked(path) { if (root.visible) root.set("sshKey", path) }
    }

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

    // Moving into a group follows its credentials, as dragging does (Store.credentialAfterMove).
    function changeGroup(name) {
        var next = Object.assign({}, d)
        next.credential = Store.credentialAfterMove(d, name)
        next.group = name
        d = next
    }

    function load(connection) {
        d = JSON.parse(JSON.stringify(connection))
        Sessions.refreshSshKeys()
        if (d.openIn === "hotkey")
            Hotkeys.refresh()
        password = ""
        passwordTouched = false
        gatewayPassword = ""
        gatewayPasswordTouched = false
        error = ""
        flick.contentY = 0
        nameField.forceActiveFocus()
    }

    function set(key, value) {
        var next = Object.assign({}, d)
        next[key] = value
        d = next
    }

    // Hotkey windows are limited (Hotkeys.limit), and refresh what Hyprland binds for the check.
    function pickOpenIn(v) {
        if (v === "hotkey" && d.openIn !== "hotkey" && Hotkeys.countOthers(d.id) >= Hotkeys.limit) {
            error = "Up to " + Hotkeys.limit + " hotkey windows: make one of the others a tab or own window first."
            return
        }
        error = ""
        if (v === "hotkey")
            Hotkeys.refresh()
        set("openIn", v)
    }
    // Fullscreen (RDP) opens in its own window (Format.fullscreenMode), so Open in is that.
    readonly property bool fullscreen: isRdp && d.display === "fullscreen" && d.openIn !== "hotkey"
    function pickDisplay(v) {
        set("display", v)
        if (v === "fullscreen" && d.openIn !== "window")
            set("openIn", "window")
    }
    readonly property string shortcutProblem: d.openIn === "hotkey" ? Hotkeys.conflict(d.hotkey, d.id) : ""

    function save() {
        var c = Object.assign({}, d)
        if (c.openIn === "hotkey" && shortcutProblem !== "") {
            error = "Shortcut: " + shortcutProblem
            return
        }
        if (c.openIn === "hotkey" && c.hotkey)
            c.hotkey = Hotkeys.parse(c.hotkey).text
        c.host = String(c.host || "").trim()
        if (!c.host) {
            error = "A host name or address is required."
            hostField.forceActiveFocus()
            return
        }
        if (!c.name.trim())
            c.name = c.host
        var port = parseInt(c.port)
        c.port = port > 0 && port < 65536 ? port : Format.defaultPort(c.protocol)
        // SSH signs in with keys and the agent (ssh asks for anything else): no credential sets.
        if (c.protocol === "ssh" || c.protocol === "gliff")
            c.credential = "custom"
        // Gliff: these reach the remote shell, so only plain names (bin/omaremote-session checks
        // the same: GLIFF_OUTPUT_RE, GLIFF_SERVER_RE).
        if (c.protocol === "gliff" && c.gliffOutput && !/^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$/.test(c.gliffOutput)) {
            error = "A screen name has letters, digits, dots, dashes and underscores only (DP-1)."
            return
        }
        if (c.protocol === "gliff" && c.gliffServer && !/^[A-Za-z0-9_.~\/][A-Za-z0-9_.~\/+-]{0,255}$/.test(c.gliffServer)) {
            error = "The server path has no spaces or shell characters (~/bin/gliff-server)."
            return
        }
        if (c.credential === "new" && !String(c.username || "").trim()) {
            error = "A credential set needs a user name."
            userField.forceActiveFocus()
            return
        }
        c.width = Math.max(640, parseInt(c.width) || 1920)
        c.height = Math.max(480, parseInt(c.height) || 1080)
        saved(c, password, passwordTouched, gatewayPassword, gatewayPasswordTouched)
        // Handed over: the typed passwords do not stay in the editor's memory.
        password = ""
        gatewayPassword = ""
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
        textFormat: Text.PlainText
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
            textFormat: Text.PlainText
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

        FollowFocus { flickable: flick }

        Flickable {
            id: flick
            Layout.fillWidth: true
            Layout.fillHeight: true
            contentHeight: form.implicitHeight + Theme.panelPad
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            ScrollHint { flickable: flick }

            ColumnLayout {
                id: form
                x: Theme.panelPad
                width: flick.width - 2 * Theme.panelPad
                spacing: Theme.gap

                Section { text: "GENERAL"; Layout.topMargin: 0 }
                FormRow {
                    label: "Protocol"
                    Segment {
                        value: root.d.protocol || "rdp"
                        options: [{ value: "rdp", label: "RDP" }, { value: "vnc", label: "VNC" }, { value: "ssh", label: "SSH" },
                                  { value: "gliff", label: "Gliff" }]
                        onPicked: function (v) { root.pickProtocol(v) }
                    }
                }
                FormRow {
                    label: "Name"
                    Input {
                        id: nameField
                        maximumLength: Limits.name
                        placeholderText: "Work PC"
                        text: root.d.name || ""
                        onTextEdited: root.set("name", text)
                    }
                }
                FormRow {
                    label: "Host"
                    RowLayout {
                        width: parent.width
                        spacing: Theme.gap
                        Input {
                            id: hostField
                            maximumLength: Limits.host
                            Layout.fillWidth: true
                            placeholderText: root.viaSsh ? "server.example.com or a Host from ~/.ssh/config" : "pc.example.com"
                            text: root.d.host || ""
                            onTextEdited: { root.set("host", text); root.error = "" }
                        }
                        Input {
                            id: portField
                            maximumLength: Limits.port
                            Layout.preferredWidth: 72
                            width: 72
                            placeholderText: String(Format.defaultPort(root.d.protocol))
                            text: root.d.port ? String(root.d.port) : ""
                            validator: IntValidator { bottom: 1; top: 65535 }
                            onTextEdited: root.set("port", text)
                        }
                    }
                }
                FormRow {
                    label: "Group"
                    help: "Shown in the sidebar"
                    Input {
                        id: groupField
                        maximumLength: Limits.name
                        placeholderText: "optional"
                        text: root.d.group || ""
                        onTextEdited: root.changeGroup(text.trim())
                    }
                }

                Section { text: "SIGN IN" }
                FormRow {
                    label: "Credentials"
                    visible: !root.viaSsh
                    Kit.Dropdown {
                        id: credentialPicker
                        width: parent.width
                        showLabel: false
                        value: root.d.credential || "custom"
                        options: root.credentialOptions
                        onChanged: function (v) { root.pickCredential(v) }
                    }
                }
                FormRow {
                    label: "User name"
                    visible: root.ownCredentials || root.viaSsh
                    help: root.isSsh ? "Keys and ssh-agent sign in; ssh asks for anything else"
                        : root.isGliff ? "Keys and ssh-agent sign in" : ""
                    Input {
                        id: userField
                        maximumLength: Limits.user
                        placeholderText: root.viaSsh ? "from ~/.ssh/config, else yours"
                                       : root.d.credential === "new" ? "administrator" : "asks when connecting"
                        text: root.d.username || ""
                        onTextEdited: root.set("username", text)
                    }
                }
                FormRow {
                    label: "Key"
                    visible: root.viaSsh
                    help: root.isGliff ? "Used by OMARemote"
                        : Sync.sshConfigMode === "off" ? "Used by OMARemote; Settings › SSH can make a terminal use it too"
                                                       : "Also in ~/.ssh/omaremote.conf: a terminal uses it too"
                    Kit.Dropdown {
                        id: keyPicker
                        width: parent.width
                        showLabel: false
                        value: root.d.sshKey || ""
                        options: root.keyOptions
                        onChanged: function (v) {
                            if (v === "__browse__")
                                Sync.browse("sshKey", "key", "Choose an SSH key", root.d.sshKey || "~/.ssh", "")
                            else
                                root.set("sshKey", v)
                            // The dropdown wrote its pick over the binding: follow the connection again.
                            keyPicker.value = Qt.binding(function () { return root.d.sshKey || "" })
                        }
                    }
                }
                FormRow {
                    label: "Domain"
                    visible: root.isRdp && (root.ownCredentials)
                    Input {
                        id: domainField
                        maximumLength: Limits.domain
                        placeholderText: "optional, e.g. corp.lan"
                        text: root.d.domain || ""
                        onTextEdited: root.set("domain", text)
                    }
                }
                FormRow {
                    label: "Password"
                    visible: root.ownCredentials && !root.viaSsh
                    Input {
                        id: passwordField
                        maximumLength: Limits.password
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
                    visible: root.ownCredentials && !root.viaSsh
                    Check {
                        checked: !!root.d.savePassword
                        onToggled: root.set("savePassword", !checked)
                    }
                }
                FormRow {
                    label: "Password"
                    visible: !root.ownCredentials && !root.viaSsh
                    Text {
                        textFormat: Text.PlainText
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
                    label: "Screen"
                    visible: root.isGliff
                    help: root.d.gliffScreen === "private"
                          ? "A screen of its own on the remote, following this tab" : "The remote's main screen, as it is"
                    Segment {
                        value: root.d.gliffScreen || "mirror"
                        options: [{ value: "mirror", label: "Mirror" }, { value: "private", label: "Private screen" }]
                        onPicked: function (v) { root.set("gliffScreen", v) }
                    }
                }
                FormRow {
                    label: "Screen name"
                    visible: root.isGliff && root.d.gliffScreen !== "private"
                    help: "Which remote screen to mirror; empty: the focused one"
                    Input {
                        maximumLength: Limits.standard
                        placeholderText: "focused screen  (DP-1, HDMI-A-1)"
                        text: root.d.gliffOutput || ""
                        onTextEdited: { root.set("gliffOutput", text.trim()); root.error = "" }
                    }
                }
                FormRow {
                    label: "Colour"
                    visible: root.isGliff
                    help: root.d.gliffColour === "low" ? "4:2:0 from the start: less bandwidth, softer text"
                        : root.d.gliffColour === "full" ? "4:4:4 even when the remote encodes on the CPU"
                        : "Sharp 4:4:4 text when both ends can; less on a slow link"
                    Segment {
                        value: root.d.gliffColour || "auto"
                        options: [{ value: "auto", label: "Auto" }, { value: "low", label: "Low bandwidth" }, { value: "full", label: "Full 4:4:4" }]
                        onPicked: function (v) { root.set("gliffColour", v) }
                    }
                }
                FormRow {
                    label: "Decoding"
                    visible: root.isGliff
                    help: root.d.gliffVideo === "cpu" ? "On the CPU here, for a GPU driver that misbehaves" : "The GPU (VA-API) when it works, else the CPU"
                    Segment {
                        value: root.d.gliffVideo || "auto"
                        options: [{ value: "auto", label: "Auto" }, { value: "cpu", label: "CPU" }]
                        onPicked: function (v) { root.set("gliffVideo", v) }
                    }
                }
                FormRow {
                    inherited: root.fromGroup("vncScaling")
                    label: "Scaling"
                    help: "Resize needs server support"
                    visible: root.isVnc
                    Segment {
                        value: root.d.vncScaling || "fit"
                        options: [{ value: "fit", label: "Fit window" }, { value: "native", label: "Native pixels" }, { value: "resize", label: "Resize remote" }]
                        onPicked: function (v) { root.set("vncScaling", v) }
                    }
                }
                FormRow {
                    inherited: root.fromGroup("vncQuality")
                    label: "Quality"
                    help: "Low saves bandwidth"
                    visible: root.isVnc
                    Segment {
                        value: root.d.vncQuality || "auto"
                        options: [{ value: "auto", label: "Auto" }, { value: "high", label: "High" }, { value: "low", label: "Low" }]
                        onPicked: function (v) { root.set("vncQuality", v) }
                    }
                }
                FormRow {
                    inherited: root.fromGroup("viewOnly")
                    label: "View only"
                    help: "Watch without sending input"
                    visible: root.isVnc
                    Check {
                        checked: !!root.d.viewOnly
                        onToggled: root.set("viewOnly", !checked)
                    }
                }
                FormRow {
                    inherited: root.fromGroup("openIn")
                    label: "Open in"
                    visible: !root.isVnc
                    help: root.fullscreen ? "Fullscreen opens in a window of its own"
                        : root.d.openIn === "hotkey" ? "Slides in and out on its shortcut, kept connected"
                        : "A window of its own"
                    Segment {
                        value: root.fullscreen ? "window" : (root.d.openIn || "tab")
                        // Fullscreen is a window of its own: neither a tab nor a hotkey window.
                        options: root.fullscreen ? [{ value: "window", label: "Own window" }]
                               : [{ value: "tab", label: "Tab" }, { value: "window", label: "Own window" }, { value: "hotkey", label: "Hotkey window" }]
                        onPicked: function (v) { root.pickOpenIn(v) }
                    }
                }
                FormRow {
                    label: "Shortcut"
                    visible: !root.isVnc && root.d.openIn === "hotkey"
                    help: root.shortcutProblem !== "" ? root.shortcutProblem
                        : !root.d.hotkey ? "Optional: or bind omaremote toggle yourself"
                        : Hotkeys.writeConfig ? "Written into Hyprland's config"
                        : "Settings › Hotkeys writes it into Hyprland's config"
                    ShortcutField {
                        text: root.d.hotkey || ""
                        onTextEdited: root.set("hotkey", text.trim())
                        onRecorded: function (t) { root.set("hotkey", t) }
                    }
                }
                FormRow {
                    inherited: root.fromGroup("display")
                    label: "Resolution"
                    visible: root.isRdp
                    help: root.d.openIn === "hotkey" ? "A hotkey window: " + Keymap.session("ctrl+alt+⏎") + " makes it fullscreen while it is open" : ""
                    Segment {
                        value: root.d.openIn === "hotkey" && root.d.display === "fullscreen" ? "fit" : (root.d.display || "fit")
                        // A hotkey window slides in at 90%: Fullscreen is not one of its choices.
                        options: [{ value: "fit", label: "Fit window" }]
                                 .concat(root.d.openIn === "hotkey" ? [] : [{ value: "fullscreen", label: "Fullscreen" }])
                                 .concat([{ value: "fixed", label: "Fixed" }])
                        onPicked: function (v) { root.pickDisplay(v) }
                    }
                }
                FormRow {
                    inherited: root.fromGroup("fullscreen")
                    label: "Fullscreen"
                    visible: root.fullscreen
                    help: root.d.fullscreen === "window" ? "Maximised: the bar stays"
                        : "The bar hidden; the top edge slides in a bar to leave fullscreen"
                    Segment {
                        value: root.d.fullscreen === "window" ? "window" : "screen"
                        options: [{ value: "screen", label: "Whole screen" }, { value: "window", label: "In a window" }]
                        onPicked: function (v) { root.set("fullscreen", v) }
                    }
                }
                FormRow {
                    inherited: root.fromGroup("width") && root.fromGroup("height")
                    label: "Size"
                    help: "Scaled to the window"
                    visible: root.isRdp && (root.d.display === "fixed")
                    RowLayout {
                        width: parent.width
                        spacing: Theme.gap
                        Input {
                            maximumLength: Limits.size
                            Layout.preferredWidth: 80
                            width: 80
                            placeholderText: "1920"
                            text: root.d.width ? String(root.d.width) : ""
                            validator: IntValidator { bottom: 640; top: 8192 }
                            onTextEdited: root.set("width", text)
                        }
                        Text { textFormat: Text.PlainText; text: "×"; color: Theme.muted; font.family: Theme.font; font.pixelSize: Theme.body }
                        Input {
                            maximumLength: Limits.size
                            Layout.preferredWidth: 80
                            width: 80
                            placeholderText: "1080"
                            text: root.d.height ? String(root.d.height) : ""
                            validator: IntValidator { bottom: 480; top: 8192 }
                            onTextEdited: root.set("height", text)
                        }
                        Item { Layout.fillWidth: true }
                    }
                }
                FormRow {
                    inherited: root.fromGroup("scale")
                    label: "Scale"
                    visible: root.isRdp
                    help: "Auto follows Hyprland, now " + Sessions.monitorScale + "%"
                    Segment {
                        value: String(root.d.scale || "auto")
                        options: [{ value: "auto", label: "Auto" }, { value: "100", label: "100" }, { value: "125", label: "125" },
                                  { value: "150", label: "150" }, { value: "175", label: "175" }, { value: "200", label: "200" }]
                        onPicked: function (v) { root.set("scale", v) }
                    }
                }

                Section { text: "DEVICES" }
                FormRow {
                    inherited: root.fromGroup("clipboard")
                    label: "Clipboard"
                    help: root.isGliff ? "Shared while the tab has the keyboard; data moves only when pasted"
                        : root.isSsh ? "Programs on the server (tmux, Neovim) may set it; copying a selection always works"
                        : "What the server copies arrives once the tab has the keyboard"
                    Check {
                        checked: !!root.d.clipboard
                        onToggled: root.set("clipboard", !checked)
                    }
                }
                FormRow {
                    inherited: root.fromGroup("audio")
                    label: "Sound"
                    visible: root.isRdp
                    Segment {
                        value: root.d.audio || "local"
                        options: [{ value: "local", label: "Here" }, { value: "remote", label: "On remote" }, { value: "off", label: "Off" }]
                        onPicked: function (v) { root.set("audio", v) }
                    }
                }
                FormRow {
                    inherited: root.fromGroup("microphone")
                    label: "Microphone"
                    visible: root.isRdp
                    Check {
                        checked: !!root.d.microphone
                        onToggled: root.set("microphone", !checked)
                    }
                }
                FormRow {
                    inherited: root.fromGroup("homeDrive")
                    label: "Home folder"
                    visible: root.isRdp
                    help: "Shared as a drive"
                    Check {
                        checked: !!root.d.homeDrive
                        onToggled: root.set("homeDrive", !checked)
                    }
                }
                FormRow {
                    inherited: root.fromGroup("grabKeyboard")
                    label: "Super key"
                    visible: root.isRdp
                    help: "Send to remote instead of Hyprland"
                    Check {
                        checked: !!root.d.grabKeyboard
                        onToggled: root.set("grabKeyboard", !checked)
                    }
                }
                FormRow {
                    inherited: root.fromGroup("unlockAfter")
                    label: "Unlock on return"
                    visible: root.isRdp
                    help: "Reconnect when back after this long away; pick the remote's lock time"
                    Segment {
                        value: String(Number(root.d.unlockAfter) || 0)
                        options: [{ value: "0", label: "Off" }, { value: "5", label: "5m" }, { value: "10", label: "10m" },
                                  { value: "15", label: "15m" }, { value: "30", label: "30m" },
                                  { value: "60", label: "60m" }]
                        onPicked: function (v) { root.set("unlockAfter", Number(v)) }
                    }
                }

                Section { text: "CONNECTION"; visible: !root.isVnc }
                FormRow {
                    inherited: root.fromGroup("security")
                    label: "Security"
                    visible: root.isRdp
                    Segment {
                        value: root.d.security || "auto"
                        options: [{ value: "auto", label: "Auto" }, { value: "nla", label: "NLA" }, { value: "tls", label: "TLS" }, { value: "rdp", label: "RDP" }]
                        onPicked: function (v) { root.set("security", v) }
                    }
                }
                FormRow {
                    inherited: root.fromGroup("network")
                    label: "Network"
                    visible: root.isRdp
                    Segment {
                        value: root.d.network || "auto"
                        options: [{ value: "auto", label: "Auto" }, { value: "lan", label: "LAN" }, { value: "broadband", label: "Broadband" }, { value: "modem", label: "Slow" }]
                        onPicked: function (v) { root.set("network", v) }
                    }
                }
                FormRow {
                    inherited: root.fromGroup("ignoreCert")
                    label: "Ignore certificate"
                    visible: root.isRdp
                    help: "Skip the server identity check"
                    Check {
                        checked: !!root.d.ignoreCert
                        onToggled: root.set("ignoreCert", !checked)
                    }
                }
                FormRow {
                    inherited: root.fromGroup("gateway")
                    label: "Gateway"
                    visible: root.isRdp
                    help: "RD Gateway, optional"
                    Input {
                        maximumLength: Limits.host
                        placeholderText: "gateway.example.com"
                        text: root.d.gateway || ""
                        onTextEdited: root.set("gateway", text)
                    }
                }
                FormRow {
                    inherited: root.fromGroup("gatewayUser")
                    label: "Gateway user"
                    visible: root.hasGateway
                    Input {
                        maximumLength: Limits.user
                        placeholderText: "same as above"
                        text: root.d.gatewayUser || ""
                        onTextEdited: root.set("gatewayUser", text)
                    }
                }
                FormRow {
                    inherited: root.fromGroup("gatewayDomain")
                    label: "Gateway domain"
                    visible: root.hasGateway
                    Input {
                        maximumLength: Limits.domain
                        placeholderText: "same as above"
                        text: root.d.gatewayDomain || ""
                        onTextEdited: root.set("gatewayDomain", text)
                    }
                }
                FormRow {
                    label: "Gateway password"
                    visible: root.hasGateway
                    Input {
                        maximumLength: Limits.password
                        password: true
                        placeholderText: root.hasStoredGatewayPassword ? "•••••• stored — type to replace"
                                       : root.d.gatewaySavePassword ? "password"
                                       : root.d.gatewayUser ? "asked when connecting" : "same as above"
                        text: root.gatewayPassword
                        onTextEdited: {
                            root.gatewayPassword = text
                            root.gatewayPasswordTouched = true
                            // Typing a password means keeping it.
                            if (text !== "" && !root.d.gatewaySavePassword)
                                root.set("gatewaySavePassword", true)
                        }
                    }
                }
                FormRow {
                    label: "Save gateway password"
                    help: "In your keyring"
                    visible: root.hasGateway
                    Check {
                        checked: !!root.d.gatewaySavePassword
                        onToggled: root.set("gatewaySavePassword", !checked)
                    }
                }
                FormRow {
                    inherited: root.fromGroup("kdc")
                    label: "Kerberos KDC"
                    visible: root.isRdp
                    help: "Found automatically; list DCs to pin them"
                    Input {
                        maximumLength: Limits.hostList
                        placeholderText: "auto  (dc1.corp.lan, dc2.corp.lan)"
                        text: root.d.kdc || ""
                        onTextEdited: root.set("kdc", text)
                    }
                }
                FormRow {
                    label: "Capture"
                    visible: root.isGliff
                    help: root.d.gliffCapture === "shm" ? "Frames read back by the compositor: for a VM whose screen stays black"
                                                        : "GPU buffers, falling back by itself"
                    Segment {
                        value: root.d.gliffCapture || "auto"
                        options: [{ value: "auto", label: "Auto" }, { value: "shm", label: "Read back" }]
                        onPicked: function (v) { root.set("gliffCapture", v) }
                    }
                }
                FormRow {
                    label: "Server"
                    visible: root.isGliff
                    help: "gliff-server's path on the remote, when it is not on its PATH"
                    Input {
                        maximumLength: Limits.path
                        placeholderText: "gliff-server"
                        text: root.d.gliffServer || ""
                        onTextEdited: { root.set("gliffServer", text.trim()); root.error = "" }
                    }
                }
                FormRow {
                    label: "Extra ssh options"
                    visible: root.viaSsh
                    help: "Passed to ssh as-is"
                    Input {
                        maximumLength: Limits.args
                        placeholderText: "-J jump.example.com  -A"
                        text: root.d.sshArgs || ""
                        onTextEdited: root.set("sshArgs", text)
                    }
                }
                FormRow {
                    inherited: root.fromGroup("extraArgs")
                    label: "Extra arguments"
                    visible: root.isRdp
                    help: "Passed to FreeRDP as-is"
                    Input {
                        maximumLength: Limits.args
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
                textFormat: Text.PlainText
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
