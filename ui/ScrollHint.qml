import QtQuick
import qs.Commons

// A slim scrollbar along a Flickable's right edge: there only when the content does not fit, so a
// pane that scrolls shows it does. The thumb can be dragged, and a click on the track jumps there.
// Declared inside the Flickable: `ScrollHint { flickable: pane }`.
Item {
    id: root
    property Flickable flickable: null
    readonly property real range: flickable ? flickable.contentHeight - flickable.height : 0

    // On the Flickable itself, not its content: it stays put while the content moves.
    parent: flickable
    anchors.top: parent ? parent.top : undefined
    anchors.bottom: parent ? parent.bottom : undefined
    anchors.right: parent ? parent.right : undefined
    anchors.margins: 2
    width: 6
    z: 10
    visible: range > 1

    Rectangle {
        anchors.fill: parent
        radius: width / 2
        color: Util.alpha(Theme.foreground, 0.06)
    }
    Rectangle {
        id: thumb
        width: parent.width
        radius: width / 2
        height: root.flickable ? Math.max(24, root.height * root.flickable.height / Math.max(1, root.flickable.contentHeight)) : 0
        y: root.range > 0 ? (root.flickable.contentY - root.flickable.originY) / root.range * (root.height - height) : 0
        color: Util.alpha(Theme.foreground, area.pressed || area.containsMouse ? 0.45 : 0.25)
    }
    MouseArea {
        id: area
        // A little wider than the bar: easier to catch.
        anchors.fill: parent
        anchors.leftMargin: -4
        hoverEnabled: true
        function scrollTo(y) {
            var f = Math.max(0, Math.min(1, (y - thumb.height / 2) / Math.max(1, root.height - thumb.height)))
            root.flickable.contentY = root.flickable.originY + f * root.range
        }
        onPressed: function (mouse) { scrollTo(mouse.y) }
        onPositionChanged: function (mouse) { if (pressed) scrollTo(mouse.y) }
    }
}
