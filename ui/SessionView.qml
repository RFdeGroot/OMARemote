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
    // Shown in an own window (SessionWindow) instead of a tab.
    property bool inWindow: false
    readonly property var connection: { Store.connections; return session ? Store.get(session.connection) : null }
    readonly property bool live: !!session && Sessions.isActive(session)
    readonly property bool showDesktop: view.state === "connected" && live
    readonly property var prompt: view.prompt
    readonly property bool hasPrompt: prompt && prompt.kind !== undefined

    signal reconnectRequested()
    signal closeRequested()
    signal navigate(string where) // home, next, previous, keys, window (out of the tab), tab (into one), quick (connect)
    signal toggleFullscreen()
    signal togglePinned()

    // The keyboard goes to what is on screen: a prompt, the remote desktop, or (once the session has
    // ended or failed) its panel, whose ⏎, l and w would otherwise never arrive.
    function focusDesktop() {
        if (hasPrompt)
            promptLoader.forceActiveFocus()
        else if (!live && session)
            ended.forceActiveFocus()
        else
            view.forceActiveFocus()
    }

    onCurrentChanged: if (current) Qt.callLater(focusDesktop)
    onHasPromptChanged: if (current) Qt.callLater(focusDesktop)
    onLiveChanged: {
        if (current)
            Qt.callLater(focusDesktop)
        if (!live && isSsh)
            Qt.callLater(root.filesAfterSession)
    }

    readonly property bool isSsh: !!session && session.protocol === "ssh"
    // Its files still mounted once the last SSH session to that connection has ended: asked on the
    // ended panel, or unmounted or kept as Settings › SSH says.
    property bool filesAsked: false
    readonly property bool filesStillMounted: {
        Sessions.sessions
        if (!isSsh || live || !session || !(Sessions.mountedFiles, Sessions.isMounted(session.connection)))
            return false
        return Sessions.activeFor(session.connection).length === 0
    }
    // Unmount is done by the session's supervisor (files_after_session); here only the mount list
    // is brought up to date for the question.
    function filesAfterSession() {
        filesAsked = false
        Sessions.refreshMounts()
    }

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
        // native shows it pixel for pixel, resize asks the server to follow the tab. SSH: the
        // terminal always fills the tab, at the screen's own scale.
        followSize: !root.connection ? true
                  : root.connection.protocol === "vnc" ? root.connection.vncScaling !== "fit"
                  : root.connection.protocol === "ssh" ? true
                  : root.connection.display !== "fixed"
        desktopScale: root.connection && (root.connection.protocol || "rdp") === "rdp" && root.connection.scale !== "auto"
                      ? parseInt(root.connection.scale) : 0
        focus: root.current

        // App chords, all on Ctrl+Alt so nothing a Windows user types is taken.
        Keys.onPressed: function (event) {
            if (root.chord(event)) {
                view.releaseAllKeys()
                event.accepted = true
            }
        }
    }

    // The Ctrl+Alt chords, for the desktop and for the panel of an ended session alike. True when
    // the key was one of them.
    function chord(event) {
        if (!((event.modifiers & Qt.ControlModifier) && (event.modifiers & Qt.AltModifier)))
            return false
        if (event.key === Qt.Key_Home) root.navigate("home")
        else if (event.key === Qt.Key_PageDown) root.navigate("next")
        else if (event.key === Qt.Key_PageUp) root.navigate("previous")
        else if (event.key === Qt.Key_End && live) view.sendCtrlAltDel()
        else if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter) && live) root.toggleFullscreen()
        else if (event.key === Qt.Key_K) root.navigate("keys")
        else if (event.key === Qt.Key_N) root.navigate("quick")
        else if (event.key === Qt.Key_O && !root.inWindow && live) root.navigate("window")
        else if (event.key === Qt.Key_T && root.inWindow) root.navigate("tab")
        else if (event.key === Qt.Key_H && root.inWindow) root.navigate("hide")
        else if (event.key === Qt.Key_P) root.togglePinned()
        else if (event.key === Qt.Key_B && root.isSsh) Sessions.browse(root.session.connection)
        else if (event.key === Qt.Key_W) root.closeRequested()
        else return false
        return true
    }

    // ---------------------------------------------------------------- connecting

    Column {
        anchors.centerIn: parent
        visible: root.live && !root.showDesktop && !root.hasPrompt
        spacing: Theme.gap * 1.5
        Glyph {
            anchors.horizontalCenter: parent.horizontalCenter
            text: root.session && root.session.protocol === "ssh" ? "" : ""
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
            textFormat: Text.PlainText
            anchors.horizontalCenter: parent.horizontalCenter
            text: root.session ? (root.session.stage || "Connecting") + "…" : ""
            color: Theme.foreground
            font.family: Theme.font
            font.pixelSize: Theme.title
        }
        Text {
            textFormat: Text.PlainText
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
        id: ended
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
            textFormat: Text.PlainText
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            text: root.session && root.session.state === "failed" ? "Connection failed" : "Disconnected"
            color: Theme.foreground
            font.family: Theme.font
            font.pixelSize: Theme.heading
        }
        Text {
            textFormat: Text.PlainText
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
            ActionButton { text: root.inWindow ? "Close" : "Close tab"; hint: "w"; onClicked: root.closeRequested() }
        }
        // Its files still mounted (Settings › SSH: ask).
        Row {
            id: filesQuestion
            anchors.horizontalCenter: parent.horizontalCenter
            visible: root.filesStillMounted && !root.filesAsked && (Store.ui.sftpOnEnd || "ask") === "ask"
            spacing: Theme.gap
            Text {
                textFormat: Text.PlainText
                anchors.verticalCenter: parent.verticalCenter
                text: "Its files are still mounted"
                color: Theme.muted
                font.family: Theme.font
                font.pixelSize: Theme.small
            }
            ActionButton { text: "Unmount"; hint: "u"; onClicked: { Sessions.unmountFiles(root.session.connection); root.filesAsked = true } }
            ActionButton { text: "Keep"; onClicked: root.filesAsked = true }
        }
        focus: visible && root.current
        Keys.onPressed: function (event) {
            if (root.chord(event)) {
                event.accepted = true
                return
            }
            if (event.key === Qt.Key_U && filesQuestion.visible) { Sessions.unmountFiles(root.session.connection); root.filesAsked = true }
            else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) root.reconnectRequested()
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
                    textFormat: Text.PlainText
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
                    textFormat: Text.PlainText
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
                    // The first thing to fill in: the user name when none is known (a quick
                    // connection, a connection without one), else the password.
                    readonly property bool userFirst: needsUser && !root.prompt.user
                    readonly property bool needsDomain: root.hasPrompt && String(root.prompt.reason).indexOf("vnc") !== 0
                    Text { textFormat: Text.PlainText; visible: parent.needsUser; text: "User name"; color: Theme.foreground; font.family: Theme.font; font.pixelSize: Theme.small }
                    Input { id: authUser; visible: parent.needsUser; Layout.fillWidth: true; text: root.hasPrompt ? (root.prompt.user || "") : ""
                            focus: root.hasPrompt && root.prompt.kind === "auth" && parent.userFirst
                            onAccepted: (parent.needsDomain ? authDomain : authPassword).forceActiveFocus() }
                    Text { textFormat: Text.PlainText; visible: parent.needsDomain; text: "Domain"; color: Theme.foreground; font.family: Theme.font; font.pixelSize: Theme.small }
                    Input { id: authDomain; visible: parent.needsDomain; Layout.fillWidth: true; text: root.hasPrompt ? (root.prompt.domain || "") : ""
                            onAccepted: authPassword.forceActiveFocus() }
                    Text { textFormat: Text.PlainText; text: "Password"; color: Theme.foreground; font.family: Theme.font; font.pixelSize: Theme.small }
                    Input {
                        id: authPassword
                        Layout.fillWidth: true
                        password: true
                        focus: root.hasPrompt && root.prompt.kind === "auth" && !parent.userFirst
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
