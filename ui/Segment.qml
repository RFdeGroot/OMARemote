import QtQuick
import qs.Commons

// A row of mutually exclusive choices: [{value, label}]. Cheaper to read than a dropdown when every
// option fits; wraps when the pane is narrow.
Flow {
    id: root
    width: parent ? parent.width : implicitWidth
    property var options: []
    property string value: ""
    signal picked(string value)

    spacing: 0

    Repeater {
        model: root.options
        delegate: Rectangle {
            required property var modelData
            required property int index
            readonly property bool on: String(modelData.value) === root.value
            width: label.implicitWidth + 2 * Style.spacing.controlPaddingX
            height: Theme.control
            radius: Theme.radius
            color: on ? Theme.selection : (mouse.containsMouse ? Style.hoverFill : Style.normalFill)
            border.width: Style.normalBorderWidth
            border.color: on ? Theme.accent : Style.normalBorderColor
            z: on ? 1 : 0
            Text {
                id: label
                anchors.centerIn: parent
                text: modelData.label
                color: parent.on ? Theme.accent : Theme.foreground
                font.family: Theme.font
                font.pixelSize: Theme.small
            }
            MouseArea {
                id: mouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                    root.value = String(modelData.value)
                    root.picked(root.value)
                }
            }
        }
    }
}
