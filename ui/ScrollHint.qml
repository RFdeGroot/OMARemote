import QtQuick
import qs.Commons

// A slim scrollbar along a pane's right edge, as an overlay (GTK's, so Ghostty's, and macOS's):
// out of sight at rest, it shows while the pointer is over the pane, while the pane scrolls (the
// wheel, or keys moving the selection) and while the thumb is held, and fades out a moment
// after. Only when the content does not fit. The thumb can be dragged, and a click on the track
// jumps there. Declared inside a Flickable: `ScrollHint { flickable: pane }`. For anything else
// (an SSH tab's terminal): `pane`, and `total`, `windowSize` and `position` in its own units, and a
// `seek` handler that scrolls there.
Item {
    id: root
    property Flickable flickable: null
    property Item pane: flickable
    property real total: flickable ? flickable.contentHeight : 0
    property real windowSize: flickable ? flickable.height : 0
    property real position: flickable ? flickable.contentY - flickable.originY : 0
    // A drag or a click on the track, without a Flickable: show from there (0 to range).
    signal seek(real position)
    readonly property real range: total - windowSize
    // Pixels for a Flickable (a pixel's rounding is no history); whole rows for a terminal.
    readonly property bool scrolls: range > (flickable ? 1 : 0)
    // Shown now: what the fade follows (and the tests read). The bar's own hover counts too: its
    // MouseArea takes the hover from the pane's handler below it, and the bar must not fade out
    // from under the pointer (it blinked, and could not be grabbed).
    readonly property bool shown: scrolls && (pointerOn || area.pressed || recent.running)

    // On the pane itself (a Flickable's, not its content): it stays put while the content moves.
    parent: pane
    anchors.top: parent ? parent.top : undefined
    anchors.bottom: parent ? parent.bottom : undefined
    anchors.right: parent ? parent.right : undefined
    anchors.margins: 2
    width: 6
    z: 10
    visible: scrolls && opacity > 0
    opacity: shown ? 1 : 0
    // In quickly, out slowly; the fade starts once `recent` ran out.
    Behavior on opacity { NumberAnimation { duration: root.shown ? 120 : 400; easing.type: Easing.OutQuad } }

    // The pointer anywhere over the pane: a passive handler on an item over the whole pane (a
    // Flickable's, not its content), so clicks, the wheel and drags still reach the pane.
    Item {
        parent: root.pane
        anchors.fill: parent
        HoverHandler { id: paneHover }
    }

    // A scroll keeps it shown a moment after the last step: for the keys (j/k moving the
    // selection), with the pointer elsewhere. The pointer leaving the pane ends that at once, so
    // leaving hides it the same way after a scroll as without one.
    Timer { id: recent; interval: 900 }
    readonly property bool pointerOn: paneHover.hovered || area.containsMouse
    onPointerOnChanged: if (!pointerOn) recent.stop()
    onPositionChanged: if (scrolls) recent.restart()

    Rectangle {
        anchors.fill: parent
        radius: width / 2
        color: Util.alpha(Theme.foreground, 0.06)
    }
    Rectangle {
        id: thumb
        objectName: "thumb" // for the tests
        width: parent.width
        radius: width / 2
        height: Math.max(24, root.height * root.windowSize / Math.max(1, root.total))
        y: root.range > 0 ? Math.max(0, Math.min(1, root.position / root.range)) * (root.height - height) : 0
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
            if (root.flickable)
                root.flickable.contentY = root.flickable.originY + f * root.range
            else
                root.seek(f * root.range)
        }
        onPressed: function (mouse) { scrollTo(mouse.y) }
        onPositionChanged: function (mouse) { if (pressed) scrollTo(mouse.y) }
    }
}
