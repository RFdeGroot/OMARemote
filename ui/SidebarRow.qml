import QtQuick
import qs.Commons

Rectangle {
    id: root
    property string icon: ""
    property string label: ""
    property int count: -1
    property bool current: false
    property color iconColor: current ? Theme.accent : Theme.muted
    // A glyph shown on hover (and always when actionPinned) that runs actionClicked.
    property string action: ""
    property bool actionPinned: false
    signal clicked()
    signal rightClicked()
    signal actionClicked()

    width: parent ? parent.width : 0
    height: Math.round(Theme.body * 2.1)
    radius: Theme.radius
    color: current ? Theme.selection : (mouse.containsMouse ? Theme.hover : "transparent")

    Glyph {
        id: glyph
        x: Theme.padX
        width: Theme.icon
        anchors.verticalCenter: parent.verticalCenter
        text: root.icon
        size: Theme.body
        color: root.iconColor
    }
    Text {
        anchors.left: glyph.right
        anchors.leftMargin: Theme.gap
        anchors.right: actionGlyph.visible ? actionGlyph.left : badge.left
        anchors.rightMargin: Theme.gap
        anchors.verticalCenter: parent.verticalCenter
        text: root.label
        elide: Text.ElideRight
        color: root.current ? Theme.accent : Theme.foreground
        font.family: Theme.font
        font.pixelSize: Theme.small
    }
    Glyph {
        id: actionGlyph
        visible: root.action !== "" && (mouse.containsMouse || actionMouse.containsMouse || root.actionPinned)
        anchors.right: badge.left
        anchors.rightMargin: Theme.gap
        anchors.verticalCenter: parent.verticalCenter
        text: root.action
        size: Theme.caption
        color: actionMouse.containsMouse ? Theme.accent : Theme.muted
        z: 1
        MouseArea {
            id: actionMouse
            anchors.fill: parent
            anchors.margins: -4
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.actionClicked()
        }
    }
    Text {
        id: badge
        anchors.right: parent.right
        anchors.rightMargin: Theme.padX
        anchors.verticalCenter: parent.verticalCenter
        text: root.count >= 0 ? String(root.count) : ""
        color: Theme.muted
        font.family: Theme.font
        font.pixelSize: Theme.caption
    }
    MouseArea {
        id: mouse
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        onClicked: function (event) {
            if (event.button === Qt.RightButton)
                root.rightClicked()
            else
                root.clicked()
        }
    }
}
