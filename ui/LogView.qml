import QtQuick
import QtQuick.Layouts
import Quickshell.Io
import qs.Commons
import "js/Format.js" as Format

// A session's FreeRDP log, followed live. Lines are compacted (time, level, source, message) and
// warnings and errors can be shown alone, which is usually where the answer is.
Rectangle {
    id: root
    property var session: null
    property bool problemsOnly: false
    signal closed()

    color: Theme.background
    focus: visible

    readonly property var lines: Format.logLines(file.loadedText, problemsOnly)

    Keys.onPressed: function (event) {
        if (event.key === Qt.Key_Escape || event.key === Qt.Key_Q || event.key === Qt.Key_L) {
            root.closed()
        } else if (event.key === Qt.Key_W) {
            root.problemsOnly = !root.problemsOnly
        } else if (event.key === Qt.Key_J || event.key === Qt.Key_Down) {
            view.contentY = Math.min(view.contentY + Theme.body * 3, Math.max(0, view.contentHeight - view.height))
        } else if (event.key === Qt.Key_K || event.key === Qt.Key_Up) {
            view.contentY = Math.max(0, view.contentY - Theme.body * 3)
        } else if (event.key === Qt.Key_G && (event.modifiers & Qt.ShiftModifier) || event.key === Qt.Key_End) {
            view.positionViewAtEnd()
        } else if (event.key === Qt.Key_G || event.key === Qt.Key_Home) {
            view.positionViewAtBeginning()
        } else {
            return
        }
        event.accepted = true
    }

    // The log is only watched here; its end is read by `omaremote-session read log` (the session's
    // own ordinary file, its last MiB), at most every 250 ms while the session writes.
    QtObject {
        id: file
        property string loadedText: ""
    }

    FileView {
        path: root.session ? root.session.log : ""
        preload: false
        blockAllReads: true
        watchChanges: path !== ""
        printErrors: false
        onFileChanged: if (!settle.running) settle.start()
    }

    Timer {
        id: settle
        interval: 250
        onTriggered: root.readLog()
    }

    function readLog() {
        if (!root.session || !root.session.log)
            return
        if (reader.running) {
            reader.again = true
            return
        }
        reader.command = [Sessions.bin, "read", "log", root.session.id]
        reader.running = true
    }

    onSessionChanged: {
        file.loadedText = ""
        readLog()
    }
    Component.onCompleted: readLog()

    Process {
        id: reader
        property bool again: false
        stdout: StdioCollector { id: logOut; waitForEnd: true }
        onExited: {
            if (again) {
                again = false
                root.readLog()
                return
            }
            try {
                var answer = JSON.parse(logOut.text)
                if (typeof answer.text !== "string")
                    return
                var follow = view.atYEnd
                file.loadedText = answer.text
                if (follow)
                    Qt.callLater(view.positionViewAtEnd)
            } catch (e) {
            }
        }
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        RowLayout {
            Layout.fillWidth: true
            Layout.margins: Theme.gap
            Layout.leftMargin: Theme.padX
            spacing: Theme.gap
            Glyph { text: ""; color: Theme.accent; size: Theme.body }
            Text {
                textFormat: Text.PlainText
                Layout.fillWidth: true
                elide: Text.ElideMiddle
                text: root.session ? root.session.name + " · " + Format.clock(root.session.started) + " · " + root.session.log : ""
                color: Theme.foreground
                font.family: Theme.font
                font.pixelSize: Theme.small
            }
            ActionButton {
                icon: "\uf0b0"
                text: root.problemsOnly ? "Warnings & errors" : "All lines"
                hint: "w"
                onClicked: root.problemsOnly = !root.problemsOnly
            }
            ActionButton { text: "Close"; hint: "esc"; onClicked: root.closed() }
        }
        Rectangle { Layout.fillWidth: true; height: 1; color: Theme.hairline }

        ListView {
            id: view
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            model: root.lines
            boundsBehavior: Flickable.StopAtBounds
            Component.onCompleted: positionViewAtEnd()
            delegate: Text {
                required property var modelData
                width: ListView.view.width
                leftPadding: Theme.padX
                rightPadding: Theme.padX
                wrapMode: Text.WrapAnywhere
                textFormat: Text.PlainText
                text: modelData.text
                color: modelData.level === "ERROR" ? Theme.urgent
                     : modelData.level === "WARN" ? Theme.warning
                     : modelData.level === "DEBUG" ? Theme.muted : Theme.foreground
                font.family: Theme.font
                font.pixelSize: Theme.caption
            }
        }

        Text {
            textFormat: Text.PlainText
            visible: root.lines.length === 0
            Layout.alignment: Qt.AlignHCenter
            Layout.bottomMargin: Theme.panelPad * 2
            text: root.problemsOnly ? "No warnings or errors" : "The log is empty"
            color: Theme.muted
            font.family: Theme.font
            font.pixelSize: Theme.small
        }
    }
}
