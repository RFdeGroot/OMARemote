import QtQuick
import QtQuick.Layouts
import qs.Commons

// The keymap sheet ? opens, after Flea's: every binding from Keymap.qml in two columns of groups.
// Typing filters it; arrows pick a row and Enter runs it, so it doubles as a command palette.
FocusScope {
    id: root
    property bool opened: false
    property string query: ""
    property int cursor: 0
    signal run(string action)
    signal closed()

    visible: opened

    function open() {
        query = ""
        cursor = 0
        opened = true
        forceActiveFocus()
    }

    function runPicked() {
        if (!picked)
            return
        var action = picked.action
        close()
        run(action)
    }

    function close() {
        opened = false
        closed()
    }

    function matches(b) {
        if (!query)
            return true
        var hay = (b.label + " " + b.group + " " + Keymap.caps(b).join(" ")).toLowerCase()
        var words = query.toLowerCase().split(/\s+/)
        for (var i = 0; i < words.length; i++)
            if (words[i] && hay.indexOf(words[i]) < 0)
                return false
        return true
    }

    readonly property var rows: Keymap.bindings.filter(matches)
    // Only rows that can run here are picked by the arrows; the others are reference.
    readonly property var runnable: rows.filter(function (b) { return b.run !== false })
    readonly property var picked: query && runnable.length > 0 ? runnable[Math.min(cursor, runnable.length - 1)] : null

    // Groups flowed into two columns of roughly equal length, split on a group boundary.
    readonly property var columns: {
        var flat = []
        for (var g = 0; g < Keymap.groups.length; g++) {
            var inGroup = rows.filter(function (b) { return b.group === Keymap.groups[g] })
            if (inGroup.length === 0)
                continue
            flat.push({ heading: Keymap.groups[g] })
            for (var i = 0; i < inGroup.length; i++)
                flat.push({ row: inGroup[i] })
        }
        if (card.width < 760)
            return [flat]
        var half = Math.ceil(flat.length / 2)
        var split = half
        for (var d = 0; d < half; d++) {
            if (flat[half + d] && flat[half + d].heading) { split = half + d; break }
            if (half - d > 0 && flat[half - d] && flat[half - d].heading) { split = half - d; break }
        }
        return [flat.slice(0, split), flat.slice(split)]
    }

    Keys.onPressed: function (event) {
        var k = event.key
        if (k === Qt.Key_Escape) {
            if (query)
                query = ""
            else
                close()
        } else if ((k === Qt.Key_Question || k === Qt.Key_F1) && !query) {
            close()
        } else if (k === Qt.Key_Down || (k === Qt.Key_Tab && !(event.modifiers & Qt.ShiftModifier))) {
            cursor = Math.min(cursor + 1, Math.max(0, runnable.length - 1))
        } else if (k === Qt.Key_Up || k === Qt.Key_Backtab) {
            cursor = Math.max(0, cursor - 1)
        } else if (k === Qt.Key_Return || k === Qt.Key_Enter) {
            runPicked()
        } else if (k === Qt.Key_Backspace) {
            query = query.slice(0, -1)
            cursor = 0
        } else if (event.text && event.text.length === 1 && event.text >= " " && !(event.modifiers & Qt.ControlModifier)) {
            query += event.text
            cursor = 0
        } else {
            return
        }
        event.accepted = true
    }

    // Scrim: a click outside the card closes it.
    Rectangle {
        anchors.fill: parent
        color: Util.alpha(Theme.background, 0.75)
        MouseArea { anchors.fill: parent; onClicked: root.close() }
    }

    Rectangle {
        id: card
        anchors.centerIn: parent
        width: Math.min(parent.width - 2 * Theme.panelPad, 980)
        height: Math.min(parent.height - 2 * Theme.panelPad, body.implicitHeight + 2 * Theme.panelPad)
        radius: Theme.radius
        color: Theme.surface
        border.width: 1
        border.color: Theme.accent
        MouseArea { anchors.fill: parent } // keeps clicks on the card from closing it

        ColumnLayout {
            id: body
            anchors.fill: parent
            anchors.margins: Theme.panelPad
            spacing: Theme.gap

            RowLayout {
                Layout.fillWidth: true
                spacing: Theme.gap
                Glyph { text: ""; color: Theme.accent; size: Theme.title }
                Text {
                    text: "Keys"
                    color: Theme.foreground
                    font.family: Theme.font
                    font.pixelSize: Theme.heading
                    font.bold: true
                }
                Text {
                    Layout.fillWidth: true
                    Layout.leftMargin: Theme.gap
                    text: root.query ? "“" + root.query + "”  ·  ↑↓ pick  ·  ⏎ run" : "Type to find an action"
                    color: root.query ? Theme.foreground : Theme.muted
                    font.family: Theme.font
                    font.pixelSize: Theme.small
                    elide: Text.ElideRight
                }
                Text {
                    text: "Esc close"
                    color: Theme.muted
                    font.family: Theme.font
                    font.pixelSize: Theme.caption
                }
            }
            Rectangle { Layout.fillWidth: true; height: 1; color: Theme.hairline }

            Flickable {
                Layout.fillWidth: true
                Layout.fillHeight: true
                Layout.preferredHeight: grid.implicitHeight
                contentHeight: grid.implicitHeight
                clip: true
                boundsBehavior: Flickable.StopAtBounds

                RowLayout {
                    id: grid
                    width: parent.width
                    spacing: Theme.panelPad
                    Repeater {
                        model: root.columns
                        delegate: Column {
                            required property var modelData
                            Layout.fillWidth: true
                            Layout.alignment: Qt.AlignTop
                            Layout.preferredWidth: 1
                            spacing: 3
                            Repeater {
                                model: modelData
                                delegate: Loader {
                                    required property var modelData
                                    width: parent.width
                                    sourceComponent: modelData.heading ? heading : row
                                    property var entry: modelData
                                }
                            }
                        }
                    }
                }
            }

            Text {
                visible: root.rows.length === 0
                text: "No key matches “" + root.query + "”"
                color: Theme.muted
                font.family: Theme.font
                font.pixelSize: Theme.small
            }
        }
    }

    Component {
        id: heading
        Text {
            topPadding: Theme.gap
            bottomPadding: 2
            text: entry.heading.toUpperCase()
            color: Theme.accent
            font.family: Theme.font
            font.pixelSize: Theme.caption
            font.bold: true
            font.letterSpacing: 1
        }
    }

    Component {
        id: row
        Rectangle {
            readonly property bool isPicked: !!root.picked && root.picked.action === entry.row.action && root.picked.context === entry.row.context
            height: line.implicitHeight + 4
            radius: Theme.radius
            color: isPicked ? Theme.selection : "transparent"
            border.width: isPicked ? 1 : 0
            border.color: Theme.accent
            opacity: root.query && entry.row.run === false ? 0.6 : 1

            RowLayout {
                id: line
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.leftMargin: 4
                anchors.verticalCenter: parent.verticalCenter
                spacing: Theme.gap
                // The caps column has one width, so every label starts on the same x.
                Row {
                    Layout.preferredWidth: 170
                    Layout.minimumWidth: 170
                    spacing: 4
                    Repeater {
                        model: Keymap.caps(entry.row)
                        delegate: Rectangle {
                            required property string modelData
                            width: capText.implicitWidth + 10
                            height: capText.implicitHeight + 4
                            radius: Theme.radius
                            color: Theme.raised
                            border.width: 1
                            border.color: Theme.hairline
                            Text {
                                id: capText
                                anchors.centerIn: parent
                                text: modelData
                                color: Theme.foreground
                                font.family: Theme.font
                                font.pixelSize: Theme.caption
                            }
                        }
                    }
                }
                Text {
                    Layout.fillWidth: true
                    text: entry.row.label
                    elide: Text.ElideRight
                    color: Theme.foreground
                    font.family: Theme.font
                    font.pixelSize: Theme.small
                }
            }
        }
    }
}
