import QtQuick
import qs.Commons

// A row of mutually exclusive choices: [{value, label}]. Cheaper to read than a dropdown when every
// option fits; wraps when the pane is narrow. Tab reaches it, ←/→ (or h/l) choose.
Flow {
    id: root
    property var options: []
    property string value: ""
    signal picked(string value)

    width: parent ? parent.width : implicitWidth
    spacing: 0
    activeFocusOnTab: true

    function indexOfValue() {
        for (var i = 0; i < options.length; i++)
            if (String(options[i].value) === value)
                return i
        return -1
    }

    function step(delta) {
        if (options.length === 0)
            return
        var at = indexOfValue()
        var next = at < 0 ? 0 : Math.max(0, Math.min(options.length - 1, at + delta))
        if (next !== at) {
            root.value = String(options[next].value)
            root.picked(root.value)
        }
    }

    Keys.onPressed: function (event) {
        if (event.key === Qt.Key_Left || event.key === Qt.Key_H)
            step(-1)
        else if (event.key === Qt.Key_Right || event.key === Qt.Key_L)
            step(1)
        else if (event.key === Qt.Key_Home)
            step(-options.length)
        else if (event.key === Qt.Key_End)
            step(options.length)
        else
            return
        event.accepted = true
    }

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
            // Focus shows on the chosen option: a heavier accent frame.
            border.width: on && root.activeFocus ? 2 : Style.normalBorderWidth
            border.color: on ? Theme.accent : Style.normalBorderColor
            z: on ? 1 : 0
            Text {
                id: label
                anchors.centerIn: parent
                text: modelData.label
                color: parent.on ? Theme.accent : Theme.foreground
                font.family: Theme.font
                font.pixelSize: Theme.small
                font.bold: parent.on && root.activeFocus
            }
            MouseArea {
                id: mouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                    root.forceActiveFocus(Qt.MouseFocusReason)
                    root.value = String(modelData.value)
                    root.picked(root.value)
                }
            }
        }
    }
}
