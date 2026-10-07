import QtQuick
import QtQuick.Layouts
import qs.Commons
import OMARemote
import "js/Format.js" as Format

// One session tab: the remote desktop, and whatever stands in front of it (connecting, a question
// from the session, or why it ended).
Item {
    id: root
    // The backend's record of this session (Sessions.sessions entry).
    property var session: null
    property bool current: false
    readonly property var connection: { Store.connections; return session ? Store.get(session.connection) : null }
    readonly property bool live: !!session && Sessions.isActive(session)
    readonly property bool showDesktop: view.state === "connected" && live
    readonly property var prompt: view.prompt
    readonly property bool hasPrompt: prompt && prompt.kind !== undefined

    signal reconnectRequested()
    signal closeRequested()
    signal navigate(string where) // home, next, previous
    signal toggleFullscreen()

    function focusDesktop() {
        if (hasPrompt)
            promptLoader.forceActiveFocus()
        else
            view.forceActiveFocus()
    }

    onCurrentChanged: if (current) Qt.callLater(focusDesktop)
    onHasPromptChanged: if (current) Qt.callLater(focusDesktop)

    Rectangle {
        anchors.fill: parent
        color: Qt.darker(Theme.background, 1.25)
    }

    RdpView {
        id: view
        anchors.fill: parent
        visible: root.current
        socketPath: root.live && root.session.socket ? root.session.socket : ""
        // RDP: the desktop follows the tab unless fixed. VNC: fit scales the picture to the tab,
        // native shows it pixel for pixel, resize asks the server to follow the tab.
        followSize: !root.connection ? true
                  : root.connection.protocol === "vnc" ? root.connection.vncScaling !== "fit"
                  : root.connection.display !== "fixed"
        desktopScale: root.connection && root.connection.protocol !== "vnc" && root.connection.scale !== "auto"
                      ? parseInt(root.connection.scale) : 0
        focus: root.current

        // App chords, all on Ctrl+Alt so nothing a Windows user types is taken.
        Keys.onPressed: function (event) {
            var chord = (event.modifiers & Qt.ControlModifier) && (event.modifiers & Qt.AltModifier)
            if (!chord)
                return
            if (event.key === Qt.Key_Home) root.navigate("home")
            else if (event.key === Qt.Key_PageDown) root.navigate("next")
            else if (event.key === Qt.Key_PageUp) root.navigate("previous")
            else if (event.key === Qt.Key_End) view.sendCtrlAltDel()
            else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) root.toggleFullscreen()
            else if (event.key === Qt.Key_K) root.navigate("keys")
            else return
            view.releaseAllKeys()
            event.accepted = true
        }
    }

    // ---------------------------------------------------------------- connecting

    Column {
        anchors.centerIn: parent
        visible: root.live && !root.showDesktop && !root.hasPrompt
        spacing: Theme.gap * 1.5
        Glyph {
            anchors.horizontalCenter: parent.horizontalCenter
            text: ""
            size: Theme.display * 2
            color: Theme.accent
            SequentialAnimation on opacity {
                running: parent.visible
                loops: Animation.Infinite
                NumberAnimation { to: 0.3; duration: 700; easing.type: Easing.InOutQuad }
                NumberAnimation { to: 1; duration: 700; easing.type: Easing.InOutQuad }
            }
        }
        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: root.session ? (root.session.stage || "Connecting") + "…" : ""
            color: Theme.foreground
            font.family: Theme.font
            font.pixelSize: Theme.title
        }
        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: root.session ? root.session.host + (root.session.auth ? " · " + root.session.auth : "") : ""
            color: Theme.muted
            font.family: Theme.font
            font.pixelSize: Theme.small
        }
        ActionButton {
            anchors.horizontalCenter: parent.horizontalCenter
            text: "Cancel"
            onClicked: if (root.session) Sessions.stop(root.session.id)
        }
    }

    // ---------------------------------------------------------------- ended or failed

    Column {
        anchors.centerIn: parent
        width: Math.min(parent.width - 2 * Theme.panelPad, 520)
        visible: !root.live && !!root.session
        spacing: Theme.gap * 1.5
        Glyph {
            anchors.horizontalCenter: parent.horizontalCenter
            text: root.session && root.session.state === "failed" ? "" : ""
            size: Theme.display * 2
            color: root.session && root.session.state === "failed" ? Theme.urgent : Theme.muted
        }
        Text {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            text: root.session && root.session.state === "failed" ? "Connection failed" : "Disconnected"
            color: Theme.foreground
            font.family: Theme.font
            font.pixelSize: Theme.heading
        }
        Text {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.Wrap
            visible: text !== ""
            text: root.session ? (root.session.error || "") : ""
            color: Theme.urgent
            font.family: Theme.font
            font.pixelSize: Theme.small
        }
        Row {
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: Theme.gap
            ActionButton { primary: true; icon: ""; text: "Reconnect"; hint: "⏎"; onClicked: root.reconnectRequested() }
            ActionButton { text: "Log"; hint: "l"; onClicked: Sessions.openLog(root.session) }
            ActionButton { text: "Close tab"; hint: "w"; onClicked: root.closeRequested() }
        }
        focus: visible && root.current
        Keys.onPressed: function (event) {
            if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) root.reconnectRequested()
            else if (event.key === Qt.Key_L) Sessions.openLog(root.session)
            else if (event.key === Qt.Key_W || event.key === Qt.Key_Escape) root.closeRequested()
            else return
            event.accepted = true
        }
    }

    // ---------------------------------------------------------------- questions from the session

    Rectangle {
        anchors.fill: parent
        visible: root.hasPrompt
        color: Util.alpha(Theme.background, 0.85)
    }

    FocusScope {
        id: promptLoader
        anchors.centerIn: parent
        width: Math.min(parent.width - 2 * Theme.panelPad, 560)
        height: card.implicitHeight
        visible: root.hasPrompt

        Rectangle {
            id: card
            width: parent.width
            implicitHeight: promptBody.implicitHeight + 2 * Theme.panelPad
            radius: Theme.radius
            color: Theme.surface
            border.width: 1
            border.color: root.prompt && root.prompt.changed ? Theme.urgent : Theme.accent

            ColumnLayout {
                id: promptBody
                x: Theme.panelPad
                y: Theme.panelPad
                width: parent.width - 2 * Theme.panelPad
                spacing: Theme.gap

                Text {
                    Layout.fillWidth: true
                    wrapMode: Text.Wrap
                    text: !root.hasPrompt ? ""
                        : root.prompt.kind === "cert" ? (root.prompt.changed ? "The certificate of " + root.prompt.host + " has changed"
                                                                            : "Trust " + root.prompt.host + "?")
                        : root.prompt.reason === "gateway" ? "Sign in to the gateway"
                        : root.prompt.reason === "vnc-password" ? "Password for " + (root.session ? root.session.name : "")
                        : "Sign in to " + (root.session ? root.session.name : "")
                    color: Theme.foreground
                    font.family: Theme.font
                    font.pixelSize: Theme.heading
                    font.bold: true
                }

                // Certificate details.
                Text {
                    Layout.fillWidth: true
                    visible: root.hasPrompt && root.prompt.kind === "cert"
                    wrapMode: Text.Wrap
                    text: !visible ? "" : (root.prompt.changed
                        ? "This can mean the server was reinstalled, or that someone is intercepting the connection. Only continue if you expected this.\n\n"
                        : "The server's certificate could not be verified, which is normal for servers with a self-signed certificate.\n\n")
                        + "Subject:  " + root.prompt.subject + "\nIssuer:   " + root.prompt.issuer + "\n" + root.prompt.fingerprint
                    color: Theme.muted
                    font.family: Theme.font
                    font.pixelSize: Theme.small
                }

                // Credentials.
                GridLayout {
                    Layout.fillWidth: true
                    visible: root.hasPrompt && root.prompt.kind === "auth"
                    columns: 2
                    columnSpacing: Theme.gap
                    rowSpacing: Theme.gap
                    // A VNC password has no user; neither VNC form has a domain.
                    readonly property bool needsUser: root.hasPrompt && root.prompt.reason !== "vnc-password"
                    readonly property bool needsDomain: root.hasPrompt && String(root.prompt.reason).indexOf("vnc") !== 0
                    Text { visible: parent.needsUser; text: "User name"; color: Theme.foreground; font.family: Theme.font; font.pixelSize: Theme.small }
                    Input { id: authUser; visible: parent.needsUser; Layout.fillWidth: true; text: root.hasPrompt ? (root.prompt.user || "") : "" }
                    Text { visible: parent.needsDomain; text: "Domain"; color: Theme.foreground; font.family: Theme.font; font.pixelSize: Theme.small }
                    Input { id: authDomain; visible: parent.needsDomain; Layout.fillWidth: true; text: root.hasPrompt ? (root.prompt.domain || "") : "" }
                    Text { text: "Password"; color: Theme.foreground; font.family: Theme.font; font.pixelSize: Theme.small }
                    Input {
                        id: authPassword
                        Layout.fillWidth: true
                        password: true
                        focus: root.hasPrompt && root.prompt.kind === "auth"
                        onAccepted: root.submitAuth()
                    }
                }

                RowLayout {
                    Layout.fillWidth: true
                    Layout.topMargin: Theme.gap
                    spacing: Theme.gap
                    Item { Layout.fillWidth: true }
                    ActionButton { text: "Cancel"; hint: "esc"; onClicked: view.cancelPrompt() }
                    ActionButton {
                        visible: root.hasPrompt && root.prompt.kind === "cert"
                        text: "Once"
                        onClicked: view.answerCertificate(2)
                    }
                    ActionButton {
                        primary: true
                        text: root.hasPrompt && root.prompt.kind === "cert" ? "Trust" : "Sign in"
                        hint: "⏎"
                        onClicked: root.hasPrompt && root.prompt.kind === "cert" ? view.answerCertificate(1) : root.submitAuth()
                    }
                }
            }
        }

        Keys.onPressed: function (event) {
            if (event.key === Qt.Key_Escape) {
                view.cancelPrompt()
                event.accepted = true
            } else if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter) && root.prompt.kind === "cert") {
                view.answerCertificate(1)
                event.accepted = true
            }
        }
    }

    function submitAuth() {
        view.answerCredentials(authUser.text, authDomain.text, authPassword.text)
        authPassword.text = ""
    }

    function disconnect() {
        if (live)
            view.disconnectSession()
    }
}
