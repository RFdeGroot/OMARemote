import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.Commons

// About OMARemote: a small card over the window, opened from the mark at the bottom of the sidebar.
// The mark large, the version and whether there is a newer one, and the links. esc, a click beside
// it or on the mark again closes it. The files it keeps are in Settings › Files.
FocusScope {
    id: root
    property bool opened: false
    signal closed()

    function open() {
        opened = true
        forceActiveFocus()
    }
    function close() {
        opened = false
        closed()
    }

    visible: opened

    Keys.onPressed: function (event) {
        if (event.key === Qt.Key_Escape) {
            root.close()
            event.accepted = true
        }
    }

    // Whether this is the newest release, as far as the check at start knows.
    readonly property string updateState: {
        if (Updates.canUpdate) return ""
        if (Updates.newer) return Updates.latest + " released"
        if (Updates.latest !== "") return "Up to date"
        if (Updates.offline) return "Update check off (Settings › Updates)"
        return "Not checked yet"
    }

    Rectangle {
        anchors.fill: parent
        color: Util.alpha(Theme.background, 0.6)
        MouseArea { anchors.fill: parent; onClicked: root.close() }
    }

    Rectangle {
        id: card
        anchors.centerIn: parent
        width: Math.min(360, parent.width - 2 * Theme.panelPad)
        height: body.implicitHeight + 2 * Theme.panelPad
        radius: Theme.radius
        color: Theme.surface
        border.width: 1
        border.color: Theme.hairline
        MouseArea { anchors.fill: parent } // clicks on the card stay on it

        ColumnLayout {
            id: body
            anchors.fill: parent
            anchors.margins: Theme.panelPad
            spacing: Theme.gap

            Row {
                Layout.alignment: Qt.AlignHCenter
                Layout.topMargin: Theme.gap
                spacing: 10
                OmaremoteMark { cell: 2; anchors.verticalCenter: parent.verticalCenter }
                Wordmark {
                    anchors.verticalCenter: parent.verticalCenter
                    text: "OMAREMOTE"
                    split: 3
                    secondColor: Theme.muted
                }
            }
            Text {
                textFormat: Text.PlainText
                Layout.fillWidth: true
                Layout.topMargin: Theme.gap
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.Wrap
                text: "Remote desktops for Omarchy: RDP, VNC and SSH"
                color: Theme.foreground
                font.family: Theme.font
                font.pixelSize: Theme.body
            }
            Text {
                textFormat: Text.PlainText
                Layout.fillWidth: true
                horizontalAlignment: Text.AlignHCenter
                text: "Version " + (Updates.version || "dev") + (Updates.checkout ? " (a checkout)" : "") + " · MIT licence"
                color: Theme.muted
                font.family: Theme.font
                font.pixelSize: Theme.caption
            }
            Text {
                textFormat: Text.PlainText
                Layout.fillWidth: true
                visible: root.updateState !== ""
                horizontalAlignment: Text.AlignHCenter
                text: root.updateState
                color: Theme.muted
                font.family: Theme.font
                font.pixelSize: Theme.caption
            }
            ActionButton {
                Layout.alignment: Qt.AlignHCenter
                visible: Updates.canUpdate
                primary: true
                fontSize: Theme.caption
                icon: "\uf019"
                text: "Update to " + Updates.latest
                onClicked: { root.close(); Updates.install() }
            }
            RowLayout {
                Layout.alignment: Qt.AlignHCenter
                Layout.topMargin: Theme.gap
                spacing: Theme.gap
                ActionButton { text: "GitHub"; icon: "\uf09b"; fontSize: Theme.caption; onClicked: Quickshell.execDetached(["xdg-open", "https://github.com/RFdeGroot/OMARemote"]) }
                ActionButton { text: "Report a problem"; icon: "\uf188"; fontSize: Theme.caption; onClicked: Quickshell.execDetached(["xdg-open", "https://github.com/RFdeGroot/OMARemote/issues"]) }
            }
        }
    }
}
