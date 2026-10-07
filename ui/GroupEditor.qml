import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Ui as Kit

// Settings for a group of connections: a credential set and any connection setting. A setting
// left at "—" is not set by the group; its connections decide it themselves.
Rectangle {
    id: root
    property string name: ""
    property string credential: ""          // set id, "" for none, "new" while creating one
    property var settings: ({})             // only the keys the group sets
    property bool apply: true
    // A credential set being created here.
    property string newUser: ""
    property string newDomain: ""
    property string newPassword: ""
    property bool newSave: true
    property string error: ""
    signal saved(string name, string credential, var newCredential, var settings, bool apply)
    signal cancelled()

    color: Theme.surface

    readonly property int members: { Store.stored; return Store.membersOf(name) }

    function load(groupName) {
        name = groupName
        var g = Store.group(groupName)
        credential = g.credential
        settings = JSON.parse(JSON.stringify(g.settings))
        apply = true
        newUser = newDomain = newPassword = ""
        newSave = true
        error = ""
        flick.contentY = 0
        forceActiveFocus()
    }

    function value(key) {
        return settings[key] === undefined ? "" : String(settings[key])
    }

    // "" removes the key: the group stops setting it.
    function set(key, v) {
        var next = Object.assign({}, settings)
        if (v === "" || v === undefined || v === null)
            delete next[key]
        else
            next[key] = v
        settings = next
    }

    function setBool(key, v) {
        set(key, v === "" ? "" : v === "on")
    }

    function boolValue(key) {
        return settings[key] === undefined ? "" : (settings[key] ? "on" : "off")
    }

    function save() {
        if (credential === "new" && !newUser.trim()) {
            error = "A credential set needs a user name."
            return
        }
        var s = Object.assign({}, settings)
        if (s.display === "fixed") {
            s.width = s.width || 1920
            s.height = s.height || 1080
        } else {
            delete s.width
            delete s.height
        }
        saved(name, credential, credential === "new"
              ? { username: newUser.trim(), domain: newDomain.trim(), savePassword: newSave, password: newPassword } : null,
              s, apply)
    }

    Keys.onPressed: function (event) {
        if (event.key === Qt.Key_Escape) {
            root.cancelled()
            event.accepted = true
        } else if (event.key === Qt.Key_S && (event.modifiers & Qt.ControlModifier)) {
            root.save()
            event.accepted = true
        }
    }

    readonly property var notSet: [{ value: "", label: "—" }]
    readonly property var onOff: [{ value: "", label: "—" }, { value: "on", label: "On" }, { value: "off", label: "Off" }]

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

        Column {
            Layout.fillWidth: true
            Layout.margins: Theme.panelPad
            Layout.bottomMargin: Theme.gap
            spacing: 2
            Text {
                width: parent.width
                elide: Text.ElideRight
                text: "Group " + root.name
                color: Theme.foreground
                font.family: Theme.font
                font.pixelSize: Theme.heading
                font.bold: true
            }
            Text {
                width: parent.width
                wrapMode: Text.Wrap
                text: root.members + (root.members === 1 ? " connection" : " connections")
                      + ". Settings left at — are up to each connection."
                color: Theme.muted
                font.family: Theme.font
                font.pixelSize: Theme.small
            }
        }

        FollowFocus { flickable: flick }

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

                Section { text: "CREDENTIALS"; Layout.topMargin: 0 }
                FormRow {
                    label: "Credentials"
                    help: "Used by connections set to inherit"
                    Kit.Dropdown {
                        width: parent.width
                        showLabel: false
                        value: root.credential
                        options: {
                            Store.credentials
                            var out = [{ value: "", label: "None" }]
                            for (var i = 0; i < Store.credentials.length; i++)
                                out.push({ value: Store.credentials[i].id, label: Store.credentialLabel(Store.credentials[i]) })
                            out.push({ value: "new", label: "+ New credential set…" })
                            return out
                        }
                        onChanged: function (v) { root.credential = v }
                    }
                }
                FormRow {
                    label: "User name"
                    visible: root.credential === "new"
                    Input { text: root.newUser; placeholderText: "administrator"; onTextEdited: root.newUser = text }
                }
                FormRow {
                    label: "Domain"
                    visible: root.credential === "new"
                    Input { text: root.newDomain; placeholderText: "optional, e.g. corp.lan"; onTextEdited: root.newDomain = text }
                }
                FormRow {
                    label: "Password"
                    visible: root.credential === "new"
                    Input {
                        password: true
                        text: root.newPassword
                        placeholderText: root.newSave ? "password" : "asked when connecting"
                        onTextEdited: { root.newPassword = text; if (text !== "") root.newSave = true }
                    }
                }
                FormRow {
                    label: "Save credentials"
                    help: "Password in your keyring"
                    visible: root.credential === "new"
                    Check { checked: root.newSave; onToggled: root.newSave = !checked }
                }

                Section { text: "DISPLAY" }
                FormRow {
                    label: "Open in"
                    Segment {
                        value: root.value("openIn")
                        options: root.notSet.concat([{ value: "tab", label: "Tab" }, { value: "window", label: "Own window" }])
                        onPicked: function (v) { root.set("openIn", v) }
                    }
                }
                FormRow {
                    label: "Resolution"
                    Segment {
                        value: root.value("display")
                        options: root.notSet.concat([{ value: "fit", label: "Fit" }, { value: "fullscreen", label: "Fullscreen" }, { value: "fixed", label: "Fixed" }])
                        onPicked: function (v) { root.set("display", v) }
                    }
                }
                FormRow {
                    label: "Size"
                    visible: root.value("display") === "fixed"
                    RowLayout {
                        width: parent.width
                        spacing: Theme.gap
                        Input {
                            Layout.preferredWidth: 80
                            width: 80
                            text: root.value("width") || "1920"
                            validator: IntValidator { bottom: 640; top: 8192 }
                            onTextEdited: root.set("width", parseInt(text) || "")
                        }
                        Text { text: "×"; color: Theme.muted; font.family: Theme.font; font.pixelSize: Theme.body }
                        Input {
                            Layout.preferredWidth: 80
                            width: 80
                            text: root.value("height") || "1080"
                            validator: IntValidator { bottom: 480; top: 8192 }
                            onTextEdited: root.set("height", parseInt(text) || "")
                        }
                        Item { Layout.fillWidth: true }
                    }
                }
                FormRow {
                    label: "Scale"
                    Segment {
                        value: root.value("scale")
                        options: root.notSet.concat([{ value: "auto", label: "Auto" }, { value: "100", label: "100" }, { value: "125", label: "125" },
                                                     { value: "150", label: "150" }, { value: "175", label: "175" }, { value: "200", label: "200" }])
                        onPicked: function (v) { root.set("scale", v) }
                    }
                }

                Section { text: "DEVICES" }
                FormRow {
                    label: "Clipboard"
                    Segment { value: root.boolValue("clipboard"); options: root.onOff; onPicked: function (v) { root.setBool("clipboard", v) } }
                }
                FormRow {
                    label: "Sound"
                    Segment {
                        value: root.value("audio")
                        options: root.notSet.concat([{ value: "local", label: "Here" }, { value: "remote", label: "On remote" }, { value: "off", label: "Off" }])
                        onPicked: function (v) { root.set("audio", v) }
                    }
                }
                FormRow {
                    label: "Microphone"
                    Segment { value: root.boolValue("microphone"); options: root.onOff; onPicked: function (v) { root.setBool("microphone", v) } }
                }
                FormRow {
                    label: "Home folder"
                    Segment { value: root.boolValue("homeDrive"); options: root.onOff; onPicked: function (v) { root.setBool("homeDrive", v) } }
                }
                FormRow {
                    label: "Super key"
                    help: "Send to remote"
                    Segment { value: root.boolValue("grabKeyboard"); options: root.onOff; onPicked: function (v) { root.setBool("grabKeyboard", v) } }
                }

                Section { text: "CONNECTION" }
                FormRow {
                    label: "Security"
                    Segment {
                        value: root.value("security")
                        options: root.notSet.concat([{ value: "auto", label: "Auto" }, { value: "nla", label: "NLA" }, { value: "tls", label: "TLS" }, { value: "rdp", label: "RDP" }])
                        onPicked: function (v) { root.set("security", v) }
                    }
                }
                FormRow {
                    label: "Network"
                    Segment {
                        value: root.value("network")
                        options: root.notSet.concat([{ value: "auto", label: "Auto" }, { value: "lan", label: "LAN" }, { value: "broadband", label: "Broadband" }, { value: "modem", label: "Slow" }])
                        onPicked: function (v) { root.set("network", v) }
                    }
                }
                FormRow {
                    label: "Ignore certificate"
                    Segment { value: root.boolValue("ignoreCert"); options: root.onOff; onPicked: function (v) { root.setBool("ignoreCert", v) } }
                }
                FormRow {
                    label: "Gateway"
                    help: "Empty: not set"
                    Input { text: root.value("gateway"); placeholderText: "gateway.example.com"; onTextEdited: root.set("gateway", text.trim()) }
                }
                FormRow {
                    label: "Kerberos KDC"
                    help: "Empty: not set"
                    Input { text: root.value("kdc"); placeholderText: "dc1.corp.lan, dc2.corp.lan"; onTextEdited: root.set("kdc", text.trim()) }
                }
            }
        }

        Rectangle { Layout.fillWidth: true; height: 1; color: Theme.hairline }

        RowLayout {
            Layout.fillWidth: true
            Layout.leftMargin: Theme.panelPad
            Layout.rightMargin: Theme.panelPad
            Layout.topMargin: Theme.gap
            spacing: Theme.gap
            Check { checked: root.apply; onToggled: root.apply = !checked }
            Text {
                Layout.fillWidth: true
                wrapMode: Text.Wrap
                text: "Apply to the " + root.members + (root.members === 1 ? " connection" : " connections")
                      + " in this group: their own values for these settings go"
                      + (root.credential ? ", and they inherit its credentials" : "")
                color: Theme.foreground
                font.family: Theme.font
                font.pixelSize: Theme.small
            }
        }

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
