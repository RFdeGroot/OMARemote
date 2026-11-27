import QtQuick
import QtQuick.Layouts
import qs.Commons
import OMARemote
import "js/Format.js" as Format
import "js/Limits.js" as Limits

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

    onCurrentChanged: {
        if (current)
            Qt.callLater(focusDesktop)
        else
            closeSearch() // another tab: the search ends, as the bar goes
    }

    // In front of the user: the shown tab of the active manager window, or the active own or hotkey
    // window. Coming back after the connection's unlockAfter minutes away reconnects (RDP), so a
    // desktop Windows locked meanwhile comes back signed in.
    readonly property bool present: current && Window.active
    property real awaySince: 0
    // A view that starts out of sight (a tab adopted in the background, a window opened unfocused)
    // is away from the start.
    Component.onCompleted: if (!present) awaySince = Date.now()
    onPresentChanged: {
        if (!present) {
            awaySince = Date.now()
            return
        }
        var away = awaySince > 0 ? Date.now() - awaySince : 0
        awaySince = 0
        if (showDesktop && !hasPrompt && session
                && Format.unlockDue(session.protocol, connection ? connection.unlockAfter : 0, away))
            root.reconnectRequested()
    }
    onHasPromptChanged: if (current) Qt.callLater(focusDesktop)
    onLiveChanged: {
        if (!live)
            reconnect = null
        if (current)
            Qt.callLater(focusDesktop)
        if (!live && isSsh)
            Qt.callLater(root.filesAfterSession)
        // Settings › Sessions: a clean end goes straight back, unless its files question waits.
        if (!live && Format.closeOnEnd(session, Store.ui.sessionEnd)
                && !(isSsh && Sessions.isMounted(session.connection) && (Store.ui.sftpOnEnd || "ask") === "ask"))
            Qt.callLater(root.closeRequested)
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

    // The letterbox around a picture. Not under an SSH terminal on a see-through window: its
    // see-through background would show this solid ground instead of the desktop.
    Rectangle {
        anchors.fill: parent
        visible: !(Theme.glass.on && root.isSsh)
        color: Qt.darker(Theme.background, 1.25)
    }

    // A remote desktop and the area around it stay opaque on a see-through window.
    Rectangle {
        anchors.fill: parent
        visible: root.current && Theme.glass.on && !root.isSsh
        color: Theme.background
    }

    // An SSH tab on a see-through window before its first picture: the terminal's background, so
    // the tab never shows bare desktop. Gone once the picture (which carries it) is there.
    Rectangle {
        anchors.fill: parent
        visible: root.current && root.isSsh && Theme.glass.on && view.remoteSize.width <= 0
        color: Qt.rgba(Theme.background.r, Theme.background.g, Theme.background.b, Theme.glass.terminal / 255)
    }

    RdpView {
        id: view
        anchors.fill: parent
        visible: root.current
        socketPath: root.live && root.session.socket ? root.session.socket : ""
        // RDP: the desktop follows the tab unless fixed. VNC: fit scales the picture to the tab,
        // native shows it pixel for pixel, resize asks the server to follow the tab. SSH: the
        // terminal always fills the tab, at the screen's own scale. Gliff: a private screen follows
        // the tab, at the screen's own scale; a mirrored one is fitted by the server.
        followSize: !root.connection ? true
                  : root.connection.protocol === "vnc" ? root.connection.vncScaling !== "fit"
                  : root.connection.protocol === "ssh" || root.connection.protocol === "gliff" ? true
                  : root.connection.display !== "fixed"
        desktopScale: root.connection && (root.connection.protocol || "rdp") === "rdp" && root.connection.scale !== "auto"
                      ? parseInt(root.connection.scale) : 0
        focus: root.current
        captureShortcuts: !!root.session && root.session.protocol === "gliff"
        // The connection's Clipboard switch; SSH always shares (copying a selection, pasting): its
        // switch is for OSC 52, which omaremote-ssh drops itself. Gliff's session process shares
        // the clipboard itself, so its view never touches it.
        shareClipboard: !!root.connection && root.connection.protocol !== "gliff"
                        && (root.connection.protocol === "ssh" || root.connection.clipboard !== false)
        // VNC, as Gliff: nothing moves until something is copied during the session.
        offerAtConnect: !!root.connection && root.connection.protocol !== "vnc"
        // SSH: the terminal's background follows Omarchy's see-through terminals (Theme.glass);
        // remote desktops stay opaque.
        terminalAlpha: root.isSsh ? Theme.glass.terminal : -1
        // VNC sends the text itself at once; Gliff's session process applies its own switch.
        withholdPasswords: !root.connection || (root.connection.protocol === "vnc"
                                                 && root.connection.clipboardPasswords !== true)
        releaseKey: Store.ui.gliffReleaseKey || "shift+escape"
        onShortcutsCapturedChanged: {
            if (shortcutsCaptured)
                Sessions.capturedSession = root.session.id
            else if (root.session && Sessions.capturedSession === root.session.id)
                Sessions.capturedSession = ""
        }

        // App chords, all on the session keys (Settings › Keyboard) so nothing a Windows user
        // types is taken. Right Ctrl as the session key never reaches the remote side.
        Keys.onPressed: function (event) {
            if (root.hostKey(event, true)) {
                event.accepted = true
            } else if (root.chord(event)) {
                view.releaseAllKeys()
                event.accepted = true
            } else if (root.isSsh && root.live && event.key === Qt.Key_F && root.onlyMods(event, Qt.ControlModifier | Qt.ShiftModifier)) {
                root.openSearch() // Ghostty's find (ctrl+shift+f)
                event.accepted = true
            } else if (root.searching && event.key === Qt.Key_Escape && root.onlyMods(event, 0)) {
                root.closeSearch() // Escape ends a search, as Ghostty's, before the terminal gets it
                event.accepted = true
            }
        }
        Keys.onReleased: function (event) {
            if (root.hostKey(event, false))
                event.accepted = true
        }
        onActiveFocusChanged: if (!activeFocus) root.hostHeld = false
        onPasteProgress: function (job, got, total, what) {
            root.paste = { job: job, got: got, total: total, what: what }
        }
        onStatsChanged: function (text) {
            if (root.session)
                Sessions.setStats(root.session.id, text)
        }
        onReconnectChanged: function (phase, attempt, seconds) {
            root.reconnect = phase === "off" ? null : { phase: phase, attempt: attempt, seconds: seconds, at: Date.now() }
        }
        onPasteDone: function (job) {
            if (root.paste && root.paste.job === job)
                root.paste = null
        }
    }

    // An SSH tab's scrollbar, as Ghostty's and every other pane's here: the terminal's history in
    // rows (omaremote-ssh's `scrollbar` lines; other sessions send none, so there is never one).
    // None on the alternate screen (less, vim): no history there.
    ScrollHint {
        pane: view
        total: view.scrollTotal
        windowSize: view.scrollLength
        position: view.scrollOffset
        onSeek: function (row) { view.scrollToRow(Math.round(row)) }
    }

    // SSH trying a lost connection again (omaremote-ssh): what it does, and a way out. The
    // terminal stays usable under it (ssh may ask for a password on a try).
    property var reconnect: null
    property int reconnectLeft: 0
    Timer {
        running: !!root.reconnect && root.reconnect.phase === "wait"
        interval: 250
        repeat: true
        triggeredOnStart: true
        onTriggered: root.reconnectLeft = Math.max(0, Math.ceil(root.reconnect.seconds - (Date.now() - root.reconnect.at) / 1000))
    }
    Rectangle {
        id: reconnectCard
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.top: parent.top
        anchors.topMargin: Theme.panelPad
        visible: root.live && !!root.reconnect
        width: Math.min(parent.width - 2 * Theme.panelPad, reconnectRow.implicitWidth + 2 * Theme.padX)
        height: reconnectRow.implicitHeight + Theme.gap * 2
        radius: Theme.radius
        color: Theme.surface
        border.width: 1
        border.color: Theme.warning
        RowLayout {
            id: reconnectRow
            anchors.centerIn: parent
            spacing: Theme.gap * 2
            // Still: an endless animation would redraw the window every frame for as long as a try
            // waits for the computer.
            Glyph {
                text: ""
                color: Theme.warning
            }
            ColumnLayout {
                spacing: 2
                Text {
                    textFormat: Text.PlainText
                    text: !root.reconnect ? ""
                        : root.reconnect.phase === "trying" ? "Connection lost · reconnecting to " + (root.session ? root.session.host : "") + "…"
                        : "Connection lost · trying again in " + root.reconnectLeft + " s"
                    color: Theme.foreground
                    font.family: Theme.font
                    font.pixelSize: Theme.small
                }
                Text {
                    textFormat: Text.PlainText
                    text: root.reconnect ? "Try " + root.reconnect.attempt + " · gives up after 10 minutes" : ""
                    color: Theme.muted
                    font.family: Theme.font
                    font.pixelSize: Theme.small
                }
            }
            ActionButton {
                visible: !!root.reconnect && root.reconnect.phase === "wait"
                primary: true
                icon: ""
                text: "Try now"
                hint: "⏎"
                onClicked: view.reconnectNow()
            }
            ActionButton { text: "Cancel"; icon: ""; danger: true; onClicked: view.cancelReconnect() }
        }
    }

    // An SSH tab's links, as Ghostty's: ctrl over a URL or an OSC 8 hyperlink shows where it goes
    // (the preview, bottom left; it moves right when the pointer is there), a ctrl+click opens it.
    // Only these schemes, whatever the session says: a link is the remote side's text, and an
    // OSC 8 one can show other words than where it leads.
    function openLink(url) {
        if (!Format.openableLink(url))
            return false
        Qt.openUrlExternally(url)
        return true
    }
    Connections {
        target: view
        function onOpenUrl(url) { root.openLink(url) }
    }
    Rectangle {
        id: linkPreview
        readonly property string url: root.current ? view.hoveredLink : ""
        visible: url !== ""
        anchors.bottom: parent.bottom
        anchors.margins: Theme.gap
        // Out of the pointer's way, as Ghostty's: to the right while the pointer is on the left half.
        readonly property bool aside: linkHover.point.position.x < parent.width / 2
                                      && linkHover.point.position.y > parent.height - 3 * height
        x: aside ? parent.width - width - Theme.gap : Theme.gap
        width: Math.min(linkText.implicitWidth + 2 * Theme.padX, parent.width * 0.6)
        height: linkText.implicitHeight + Theme.gap
        radius: Theme.radius
        color: Theme.surface
        border.width: 1
        border.color: Util.alpha(Theme.foreground, 0.15)
        Text {
            id: linkText
            anchors.fill: parent
            anchors.leftMargin: Theme.padX
            anchors.rightMargin: Theme.padX
            verticalAlignment: Text.AlignVCenter
            textFormat: Text.PlainText
            elide: Text.ElideMiddle
            text: linkPreview.url
            color: Theme.foreground
            font.family: Theme.font
            font.pixelSize: Theme.small
        }
    }
    HoverHandler { id: linkHover }

    // An SSH tab's find bar, Ghostty's: ctrl+shift+f opens it (top right; drag it to another
    // corner), typing highlights every match in the scrollback and goes to the newest (a
    // browser's find; Ghostty waits for Enter), Enter goes to the next one up
    // (older), shift+Enter down, Escape closes it (in the terminal too, while it is open). The
    // session searches (omaremote-ssh, libghostty-vt's search) and says how many it found.
    property bool searching: false
    function onlyMods(event, want) {
        return (event.modifiers & (Qt.ControlModifier | Qt.ShiftModifier | Qt.AltModifier | Qt.MetaModifier)) === want
    }
    function openSearch() {
        view.releaseAllKeys() // ctrl and shift went to the session; their release goes to the field
        searching = true
        findField.forceActiveFocus()
        findField.selectAll()
        if (findField.text !== "")
            view.search(findField.text)
    }
    function closeSearch() {
        if (!searching)
            return
        searching = false
        view.search("")
        if (root.current)
            root.focusDesktop()
    }
    Connections {
        target: view
        // A session that ended or a view that attached again starts without one.
        function onAttachedChanged() { root.searching = false }
    }
    Rectangle {
        id: findBar
        objectName: "findBar" // for the tests
        visible: root.searching && root.current
        // Which corner, as Ghostty's: a drag ends in the nearest one.
        property bool atRight: true
        property bool atTop: true
        readonly property real cornerX: atRight ? parent.width - width - Theme.gap : Theme.gap
        readonly property real cornerY: atTop ? Theme.gap : parent.height - height - Theme.gap
        x: cornerX
        y: cornerY
        z: 20
        width: findRow.implicitWidth + 2 * Theme.gap
        height: findRow.implicitHeight + Theme.gap
        radius: Theme.radius
        color: Theme.surface
        border.width: 1
        border.color: Util.alpha(Theme.foreground, 0.15)
        DragHandler {
            id: drag
            target: findBar
            // The drag moves it freely; let go, it goes to the corner nearest its middle.
            onActiveChanged: if (!active) {
                findBar.atRight = findBar.x + findBar.width / 2 > findBar.parent.width / 2
                findBar.atTop = findBar.y + findBar.height / 2 < findBar.parent.height / 2
                findBar.x = Qt.binding(function () { return findBar.cornerX })
                findBar.y = Qt.binding(function () { return findBar.cornerY })
            }
        }
        RowLayout {
            id: findRow
            anchors.centerIn: parent
            spacing: Theme.gap
            Input {
                id: findField
                objectName: "findField"
                width: undefined
                Layout.preferredWidth: 14 * Theme.small
                maximumLength: Limits.standard // at most 768 bytes: the session takes 1 KiB
                placeholderText: "Find…"
                onTextChanged: if (root.searching) view.search(text)
                Keys.onPressed: function (event) {
                    if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                        view.searchStep(!(event.modifiers & Qt.ShiftModifier))
                        event.accepted = true
                    } else if (event.key === Qt.Key_Escape) {
                        root.closeSearch()
                        event.accepted = true
                    } else if (event.key === Qt.Key_F && (event.modifiers & Qt.ControlModifier)
                               && (event.modifiers & Qt.ShiftModifier)) {
                        findField.selectAll()
                        event.accepted = true
                    }
                }
            }
            Text {
                objectName: "findCount"
                // Ghostty's: the selected match of all of them (0: none yet).
                text: (view.searchSelected >= 0 ? view.searchSelected + 1 : 0) + "/" + view.searchTotal
                textFormat: Text.PlainText
                color: Theme.muted
                font.family: Theme.font
                font.pixelSize: Theme.small
                horizontalAlignment: Text.AlignRight
                Layout.preferredWidth: Math.max(implicitWidth, 5 * Theme.small * 0.6)
            }
            Repeater {
                // Up: the next match into the history (Enter); down: back toward the prompt.
                model: [{ glyph: "\uf077", older: true }, { glyph: "\uf078", older: false }, { glyph: "\uf00d", close: true }]
                delegate: Rectangle {
                    required property var modelData
                    implicitWidth: Theme.control
                    implicitHeight: Theme.control
                    radius: Theme.radius
                    color: findButton.pressed ? Style.pressedFill : findButton.containsMouse ? Style.hoverFill : "transparent"
                    Glyph {
                        anchors.centerIn: parent
                        text: parent.modelData.glyph
                        size: Theme.small
                    }
                    MouseArea {
                        id: findButton
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: parent.modelData.close ? root.closeSearch() : view.searchStep(parent.modelData.older)
                    }
                }
            }
        }
    }

    // A paste from the remote that takes more than a second (Gliff): how far, and a way out.
    property var paste: null
    Rectangle {
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        anchors.bottomMargin: Theme.panelPad
        visible: root.current && !!root.paste
        width: pasteRow.implicitWidth + 2 * Theme.padX
        height: pasteRow.implicitHeight + Theme.gap * 2
        radius: Theme.radius
        color: Theme.surface
        border.width: 1
        border.color: Theme.accent
        RowLayout {
            id: pasteRow
            anchors.centerIn: parent
            spacing: Theme.gap * 2
            Text {
                textFormat: Text.PlainText
                text: !root.paste ? ""
                    : "Pasting " + root.paste.what + " · " + Format.bytes(root.paste.got)
                      + (root.paste.total > 0 ? " of " + Format.bytes(root.paste.total) : "")
                color: Theme.foreground
                font.family: Theme.font
                font.pixelSize: Theme.small
            }
            ActionButton { text: "Cancel"; icon: ""; danger: true; onClicked: if (root.paste) view.cancelPaste(root.paste.job) }
        }
    }

    // Right Ctrl held, when it is the session key (Keymap.isHostKey).
    property bool hostHeld: false
    function hostKey(event, pressed) {
        if (!Keymap.isHostKey(event))
            return false
        hostHeld = pressed
        return true
    }

    // The session-key chords (Ctrl+Alt unless Settings › Keyboard says otherwise), for the desktop
    // and for the panel of an ended session alike. True when the key was one of them; with Right
    // Ctrl held every key is OMARemote's, a chord or not.
    function chord(event) {
        if (!Keymap.isSessionChord(event, hostHeld))
            return false
        if (event.key === Qt.Key_Home) root.navigate("home")
        else if (event.key === Qt.Key_PageDown) root.navigate("next")
        else if (event.key === Qt.Key_PageUp) root.navigate("previous")
        else if (event.key === Qt.Key_End && live) view.sendCtrlAltDel()
        else if (event.key === Qt.Key_Escape && root.session && root.session.protocol === "gliff") view.releaseShortcuts()
        else if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter) && live) root.toggleFullscreen()
        else if (event.key === Qt.Key_K) root.navigate("keys")
        else if (event.key === Qt.Key_N) root.navigate("quick")
        else if (event.key === Qt.Key_O && !root.inWindow && live) root.navigate("window")
        else if (event.key === Qt.Key_T && root.inWindow) root.navigate("tab")
        else if (event.key === Qt.Key_H && root.inWindow) root.navigate("hide")
        else if (event.key === Qt.Key_P) root.togglePinned()
        else if (event.key === Qt.Key_B && root.isSsh) Sessions.browse(root.session.connection)
        else if (event.key === Qt.Key_R && live && root.session.protocol === "rdp") root.reconnectRequested()
        else if (event.key === Qt.Key_W) root.closeRequested()
        else return Keymap.sessionKeys === "rctrl"
        return true
    }

    // ---------------------------------------------------------------- connecting

    Column {
        id: connecting
        anchors.centerIn: parent
        visible: root.live && !root.showDesktop && !root.hasPrompt
        spacing: Theme.gap * 1.5
        Glyph {
            anchors.horizontalCenter: parent.horizontalCenter
            text: root.session && root.session.protocol === "ssh" ? "" : root.session && root.session.protocol === "gliff" ? "" : ""
            size: Theme.display * 2
            color: Theme.accent
            // By id: a bare `parent` here is the SessionView's own parent, always visible, which ran
            // this in every session tab and had the window redraw at the screen's refresh rate.
            SequentialAnimation on opacity {
                running: connecting.visible
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

    // The session's last picture stays behind the panel, dimmed like behind a question, with the
    // panel on a card so the remote's text never runs through it.
    Rectangle {
        anchors.fill: parent
        visible: ended.visible
        color: Util.alpha(Theme.background, 0.85)
    }

    Rectangle {
        anchors.centerIn: ended
        visible: ended.visible
        width: ended.width + 2 * Theme.panelPad
        height: ended.implicitHeight + 2 * Theme.panelPad
        radius: Theme.radius
        color: Theme.surface
        border.width: 1
        border.color: root.session && root.session.state === "failed" ? Theme.urgent : Theme.hairline
    }

    Column {
        id: ended
        anchors.centerIn: parent
        width: Math.min(parent.width - 4 * Theme.panelPad, 520)
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
        Keys.onReleased: function (event) {
            if (root.hostKey(event, false))
                event.accepted = true
        }
        Keys.onPressed: function (event) {
            if (root.hostKey(event, true) || root.chord(event)) {
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
                        : root.prompt.kind === "hostkey" ? (root.prompt.changed ? root.prompt.host + " shows a key of a new type"
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

                // ssh's host key (Gliff), the first time this computer meets the host.
                Text {
                    textFormat: Text.PlainText
                    Layout.fillWidth: true
                    visible: root.hasPrompt && root.prompt.kind === "hostkey"
                    wrapMode: Text.Wrap
                    text: !visible ? "" : (root.prompt.changed
                            ? "This computer already knows other keys of this host. That is expected after its ssh was upgraded, but can also mean someone is intercepting the connection. Only continue if you expected this.\n\n"
                            : "This computer has not connected to it before. ")
                        + "Trusting adds its key to ~/.ssh/known_hosts, as ssh does when you answer yes. "
                        + "To check it, run ssh-keygen -lf /etc/ssh/ssh_host_" + (String(root.prompt.key).split(" ")[0].toLowerCase() || "ed25519")
                        + "_key.pub on that machine.\n\n"
                        + root.prompt.details
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
                    Input { id: authUser; maximumLength: Limits.user; visible: parent.needsUser; Layout.fillWidth: true; text: root.hasPrompt ? (root.prompt.user || "") : ""
                            focus: root.hasPrompt && root.prompt.kind === "auth" && parent.userFirst
                            onAccepted: (parent.needsDomain ? authDomain : authPassword).forceActiveFocus() }
                    Text { textFormat: Text.PlainText; visible: parent.needsDomain; text: "Domain"; color: Theme.foreground; font.family: Theme.font; font.pixelSize: Theme.small }
                    Input { id: authDomain; maximumLength: Limits.domain; visible: parent.needsDomain; Layout.fillWidth: true; text: root.hasPrompt ? (root.prompt.domain || "") : ""
                            onAccepted: authPassword.forceActiveFocus() }
                    Text { textFormat: Text.PlainText; text: "Password"; color: Theme.foreground; font.family: Theme.font; font.pixelSize: Theme.small }
                    Input {
                        id: authPassword
                        maximumLength: Limits.password
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
                        readonly property bool trust: root.hasPrompt && (root.prompt.kind === "cert" || root.prompt.kind === "hostkey")
                        text: trust ? "Trust" : "Sign in"
                        hint: "⏎"
                        onClicked: trust ? view.answerCertificate(1) : root.submitAuth()
                    }
                }
            }
        }

        Keys.onPressed: function (event) {
            if (event.key === Qt.Key_Escape) {
                view.cancelPrompt()
                event.accepted = true
            } else if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter) && (root.prompt.kind === "cert" || root.prompt.kind === "hostkey")) {
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
