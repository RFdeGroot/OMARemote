import QtQuick
import QtQuick.Layouts
import qs.Commons

// Move to group (m on a connection): the groups, "No group" and "New group…" in a small card.
// j/k or the arrows move, enter picks, esc closes; a click picks too.
FocusScope {
    id: root
    property bool opened: false
    property string connectionName: ""
    property string currentGroup: ""
    property int cursor: 0
    // The value picked: a group's name, "" for none, "\n" for a new group.
    signal chosen(string value)
    signal closed()

    readonly property var options: {
        var out = []
        for (var i = 0; i < Store.groups.length; i++)
            if (Store.groups[i] !== currentGroup)
                out.push({ value: Store.groups[i], label: Store.groups[i], icon: "" })
        if (currentGroup !== "")
            out.push({ value: "", label: "No group", icon: "" })
        out.push({ value: "\n", label: "New group…", icon: "" })
        return out
    }

    function open(name, group) {
        connectionName = name
        currentGroup = group || ""
        cursor = 0
        opened = true
        forceActiveFocus()
    }
    function close() {
        opened = false
        closed()
    }
    function pick(i) {
        var value = options[i].value
        opened = false
        chosen(value)
    }

    visible: opened

    Keys.onPressed: function (event) {
        if (event.key === Qt.Key_Escape)
            root.close()
        else if (event.key === Qt.Key_J || event.key === Qt.Key_Down || event.key === Qt.Key_Tab)
            cursor = Math.min(options.length - 1, cursor + 1)
        else if (event.key === Qt.Key_K || event.key === Qt.Key_Up || event.key === Qt.Key_Backtab)
            cursor = Math.max(0, cursor - 1)
        else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter)
            pick(cursor)
        event.accepted = true
    }

    Rectangle {
        anchors.fill: parent
        color: Util.alpha(Theme.background, 0.6)
        MouseArea { anchors.fill: parent; onClicked: root.close() }
    }

    Rectangle {
        anchors.centerIn: parent
        width: Math.min(320, parent.width - 2 * Theme.panelPad)
        height: body.implicitHeight + 2 * Theme.panelPad
        radius: Theme.radius
        color: Theme.surface
        border.width: 1
        border.color: Theme.hairline
        MouseArea { anchors.fill: parent }

        ColumnLayout {
            id: body
            anchors.fill: parent
            anchors.margins: Theme.panelPad
            spacing: 2

            Text {
                textFormat: Text.PlainText
                Layout.fillWidth: true
                Layout.bottomMargin: Theme.gap
                elide: Text.ElideRight
                text: "Move " + root.connectionName + " to"
                color: Theme.foreground
                font.family: Theme.font
                font.pixelSize: Theme.body
                font.bold: true
            }
            Repeater {
                model: root.options
                delegate: SidebarRow {
                    required property var modelData
                    required property int index
                    Layout.fillWidth: true
                    icon: modelData.icon
                    label: modelData.label
                    cursor: root.cursor === index
                    current: root.cursor === index
                    onClicked: root.pick(index)
                }
            }
        }
    }
}
