import QtQuick
import qs.Commons

// Text button in the kit's control states. `primary` fills with the accent for the one action a
// view leads with; `danger` turns the ink urgent.
Rectangle {
    id: root

    property string text: ""
    property string icon: ""
    property string hint: ""
    property bool primary: false
    property bool danger: false
    property bool enabled_: true
    property int fontSize: Theme.body
    signal clicked()

    readonly property color ink: !enabled_ ? Theme.muted : primary ? Theme.background : danger ? Theme.urgent : Theme.foreground
    readonly property bool hot: mouse.containsMouse && enabled_

    implicitHeight: Theme.control
    implicitWidth: row.implicitWidth + 2 * Style.spacing.controlPaddingX
    radius: Theme.radius
    color: primary ? (hot ? Qt.lighter(Theme.accent, 1.12) : Theme.accent)
                   : (mouse.pressed ? Style.pressedFill : hot ? Style.hoverFill : Style.normalFill)
    border.width: primary ? 0 : Style.normalBorderWidth
    border.color: danger && hot ? Theme.urgent : hot ? Style.hoverBorderColor : Style.normalBorderColor
    opacity: enabled_ ? 1 : 0.55

    Row {
        id: row
        anchors.centerIn: parent
        spacing: Style.spacing.md
        Glyph {
            visible: root.icon !== ""
            text: root.icon
            color: root.ink
            size: root.fontSize
            anchors.verticalCenter: parent.verticalCenter
        }
        Text {
            text: root.text
            visible: root.text !== ""
            color: root.ink
            font.family: Theme.font
            font.pixelSize: root.fontSize
            font.bold: root.primary
            anchors.verticalCenter: parent.verticalCenter
        }
        Text {
            text: root.hint
            visible: root.hint !== ""
            color: root.primary ? Qt.rgba(root.ink.r, root.ink.g, root.ink.b, 0.6) : Theme.muted
            font.family: Theme.font
            font.pixelSize: Theme.caption
            anchors.verticalCenter: parent.verticalCenter
        }
    }

    MouseArea {
        id: mouse
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: root.enabled_ ? Qt.PointingHandCursor : Qt.ArrowCursor
        onClicked: if (root.enabled_) root.clicked()
    }
}
