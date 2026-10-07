import QtQuick
import QtQuick.Layouts

// A label column beside one control, the settings-row shape Flea's panel uses.
RowLayout {
    id: root
    property string label: ""
    property string help: ""
    // The value shown comes from the connection's group.
    property bool inherited: false
    default property alias content: slot.data

    spacing: Theme.gap
    Layout.fillWidth: true

    Column {
        Layout.preferredWidth: 150
        Layout.alignment: Qt.AlignTop
        topPadding: 6
        Text {
            text: root.label + (root.inherited ? "  ·  group" : "")
            width: parent.width
            elide: Text.ElideRight
            textFormat: Text.PlainText
            color: Theme.foreground
            font.family: Theme.font
            font.pixelSize: Theme.small
        }
        Text {
            text: root.help
            visible: root.help !== ""
            width: parent.width
            wrapMode: Text.WordWrap
            color: Theme.muted
            font.family: Theme.font
            font.pixelSize: Theme.caption
        }
    }
    Item {
        id: slot
        Layout.fillWidth: true
        implicitHeight: childrenRect.height
    }
}
