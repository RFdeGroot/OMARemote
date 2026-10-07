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

    FileView {
        id: file
        property string loadedText: ""
        path: root.session ? root.session.log : ""
        watchChanges: true
        printErrors: false
        onLoaded: {
            var follow = view.atYEnd
            loadedText = text()
            if (follow)
                Qt.callLater(view.positionViewAtEnd)
        }
        onFileChanged: reload()
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
