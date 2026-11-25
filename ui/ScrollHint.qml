import QtQuick
import qs.Commons

// A slim scrollbar along a Flickable's right edge, as an overlay (GTK's, so Ghostty's, and
// macOS's): out of sight at rest, it shows while the pointer is over the pane, while the pane
// scrolls (the wheel, or keys moving the selection) and while the thumb is held, and fades out a
// moment after. Only when the content does not fit. The thumb can be dragged, and a click on
// the track jumps there. Declared inside the Flickable: `ScrollHint { flickable: pane }`.
Item {
    id: root
    property Flickable flickable: null
    readonly property real range: flickable ? flickable.contentHeight - flickable.height : 0
    // Shown now: what the fade follows (and the tests read). The bar's own hover counts too: its
    // MouseArea takes the hover from the pane's handler below it, and the bar must not fade out
    // from under the pointer (it blinked, and could not be grabbed).
    readonly property bool shown: range > 1 && (pointerOn || area.pressed || recent.running)

    // On the Flickable itself, not its content: it stays put while the content moves.
    parent: flickable
    anchors.top: parent ? parent.top : undefined
    anchors.bottom: parent ? parent.bottom : undefined
    anchors.right: parent ? parent.right : undefined
    anchors.margins: 2
    width: 6
    z: 10
    visible: range > 1 && opacity > 0
    opacity: shown ? 1 : 0
    // In quickly, out slowly; the fade starts once `recent` ran out.
    Behavior on opacity { NumberAnimation { duration: root.shown ? 120 : 400; easing.type: Easing.OutQuad } }

    // The pointer anywhere over the pane: a passive handler on an item over the whole Flickable
    // (not its content), so clicks, the wheel and drags still reach the pane.
    Item {
        parent: root.flickable
        anchors.fill: parent
        HoverHandler { id: paneHover }
    }

    // A scroll keeps it shown a moment after the last step: for the keys (j/k moving the
    // selection), with the pointer elsewhere. The pointer leaving the pane ends that at once, so
    // leaving hides it the same way after a scroll as without one.
    Timer { id: recent; interval: 900 }
    readonly property bool pointerOn: paneHover.hovered || area.containsMouse
    onPointerOnChanged: if (!pointerOn) recent.stop()
    Connections {
        target: root.flickable
        function onContentYChanged() { if (root.range > 1) recent.restart() }
    }

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
        // A little wider than the bar: easier to catch. Faded out, the bar is not visible and
        // takes nothing: the pane's own edge is there then.
        anchors.fill: parent
        anchors.leftMargin: -4
        hoverEnabled: true
        // The Flickable below takes over a drag past its threshold (a mouse drag flicks it): the
        // thumb's drag must stay the thumb's.
        preventStealing: true
        function scrollTo(y) {
            var f = Math.max(0, Math.min(1, (y - thumb.height / 2) / Math.max(1, root.height - thumb.height)))
            root.flickable.contentY = root.flickable.originY + f * root.range
        }
        onPressed: function (mouse) { scrollTo(mouse.y) }
        onPositionChanged: function (mouse) { if (pressed) scrollTo(mouse.y) }
    }
}
