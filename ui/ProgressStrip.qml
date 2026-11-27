import QtQuick
import qs.Commons

// A terminal's progress as Ghostty draws it (OSC 9;4, RdpView's progressState/progressPercent),
// in the Omarchy theme's colours: a thin bar in its accent, its red after a failure, the accent
// faded while paused (not the theme's yellow: some themes put another colour there), and a block
// sliding back and forth while the program gives no percentage. Nothing while there is no
// report; the animation runs only while it shows.
Item {
    id: root
    property string state_: ""
    property int percent: -1
    readonly property bool pulsing: state_ === "indeterminate" || ((state_ === "set" || state_ === "error") && percent < 0)
    readonly property color ink: state_ === "error" ? Theme.urgent : Theme.accent
    readonly property real inkOpacity: state_ === "pause" ? 0.5 : 1
    visible: state_ !== ""
    clip: true

    Rectangle {
        anchors.fill: parent
        color: Util.alpha(Theme.foreground, 0.10)
    }
    Rectangle {
        visible: !root.pulsing
        height: parent.height
        width: parent.width * Math.max(0, Math.min(100, root.percent)) / 100
        color: root.ink
        opacity: root.inkOpacity
    }
    Rectangle {
        id: block
        visible: root.pulsing
        height: parent.height
        width: Math.max(8, parent.width / 5)
        color: root.ink
        SequentialAnimation on x {
            running: root.visible && root.pulsing
            loops: Animation.Infinite
            NumberAnimation { from: 0; to: root.width - block.width; duration: 900; easing.type: Easing.InOutQuad }
            NumberAnimation { from: root.width - block.width; to: 0; duration: 900; easing.type: Easing.InOutQuad }
        }
    }
}
