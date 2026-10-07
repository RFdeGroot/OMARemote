import QtQuick
import QtQuick.Layouts
import qs.Commons

// One shared credential set: user name, domain, and optionally a password in the keyring.
Rectangle {
    id: root
    property var cred: ({})
    property string password: ""
    property bool passwordTouched: false
    property bool deleteArmed: false
    property string error: ""
    signal saved(var cred, string password, bool passwordTouched)
    signal deleted(string id)
    signal cancelled()

    color: Theme.surface

    readonly property bool isNew: !cred.id
    readonly property var users: { Store.stored; Store.groupSettings; return cred.id ? Store.credentialUsers(cred.id) : { connections: 0, groups: 0 } }
    readonly property bool hasStoredPassword: !!cred.id && Sessions.secrets["credential:" + cred.id] === true

    function load(c) {
        cred = JSON.parse(JSON.stringify(c))
        password = ""
        passwordTouched = false
        deleteArmed = false
        error = ""
        if (cred.id && cred.savePassword)
            Sessions.checkSecret("credential", cred.id)
        userField.forceActiveFocus()
    }

    function set(key, value) {
        var next = Object.assign({}, cred)
        next[key] = value
        cred = next
    }

    function save() {
        if (!String(cred.username || "").trim()) {
            error = "A credential set needs a user name."
            userField.forceActiveFocus()
            return
        }
        var c = Object.assign({}, cred)
        c.username = c.username.trim()
        c.domain = String(c.domain || "").trim()
        saved(c, password, passwordTouched)
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

    Timer { id: disarm; interval: 3000; onTriggered: root.deleteArmed = false }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        Column {
            Layout.fillWidth: true
            Layout.margins: Theme.panelPad
            spacing: 2
            Text {
                width: parent.width
                elide: Text.ElideRight
                text: root.isNew ? "New credential set" : Store.credentialLabel(root.cred)
                color: Theme.foreground
                font.family: Theme.font
                font.pixelSize: Theme.heading
                font.bold: true
            }
            Text {
                width: parent.width
                wrapMode: Text.Wrap
                visible: !root.isNew
                text: "Used by " + root.users.connections + (root.users.connections === 1 ? " connection" : " connections")
                      + (root.users.groups ? " and " + root.users.groups + (root.users.groups === 1 ? " group" : " groups") : "")
                color: Theme.muted
                font.family: Theme.font
                font.pixelSize: Theme.small
            }
        }

        ColumnLayout {
            Layout.fillWidth: true
            Layout.leftMargin: Theme.panelPad
            Layout.rightMargin: Theme.panelPad
            spacing: Theme.gap
            FormRow {
                label: "User name"
                Input {
                    id: userField
                    placeholderText: "administrator"
                    text: root.cred.username || ""
                    onTextEdited: { root.set("username", text); root.error = "" }
                    KeyNavigation.tab: domainField
                }
            }
            FormRow {
                label: "Domain"
                Input {
                    id: domainField
                    placeholderText: "optional, e.g. corp.lan"
                    text: root.cred.domain || ""
                    onTextEdited: root.set("domain", text)
                    KeyNavigation.tab: passwordField
                }
            }
            FormRow {
                label: "Password"
                Input {
                    id: passwordField
                    password: true
                    placeholderText: root.hasStoredPassword ? "•••••• stored — type to replace"
                                   : root.cred.savePassword ? "password" : "asked when connecting"
                    text: root.password
                    onTextEdited: {
                        root.password = text
                        root.passwordTouched = true
                        if (text !== "" && !root.cred.savePassword)
                            root.set("savePassword", true)
                    }
                }
            }
            FormRow {
                label: "Save credentials"
                help: "Password in your keyring"
                Check { checked: !!root.cred.savePassword; onToggled: root.set("savePassword", !checked) }
            }
        }

        Item { Layout.fillHeight: true }
        Rectangle { Layout.fillWidth: true; height: 1; color: Theme.hairline }

        RowLayout {
            Layout.fillWidth: true
            Layout.margins: Theme.gap * 1.5
            Layout.leftMargin: Theme.panelPad
            Layout.rightMargin: Theme.panelPad
            spacing: Theme.gap
            ActionButton {
                visible: !root.isNew
                danger: true
                icon: ""
                text: root.deleteArmed ? "Press again to delete" : "Delete"
                onClicked: {
                    if (root.deleteArmed) {
                        root.deleted(root.cred.id)
                    } else {
                        root.deleteArmed = true
                        disarm.restart()
                    }
                }
            }
            Text {
                Layout.fillWidth: true
                text: root.error || (root.deleteArmed && (root.users.connections || root.users.groups)
                      ? "Its connections will ask for credentials" : "")
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
