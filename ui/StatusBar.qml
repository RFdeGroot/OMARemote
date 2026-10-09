import QtQuick
import qs.Commons

Rectangle {
    id: root
    property string notice: ""
    property bool noticeIsError: false
    property var hints: []
    // The connection and session counts on the left; an own session window has no use for them.
    property bool showCounts: true

    height: Math.round(Theme.small * 2.2)
    color: Theme.surface

    // The hints that fit beside the counts: the first ones and always the last (the keymap, which
    // lists the rest), so a narrow window drops hints instead of drawing them over the counts.
    readonly property var shownHints: {
        var room = width - 3 * Theme.padX - (showCounts ? countText.implicitWidth : 0)
                   - (activeRow.visible ? facts.spacing + activeRow.implicitWidth : 0)
        var widths = hints.map(function (h) { return hintWidth(h) })
        var gap = hintRow.spacing
        var last = hints.length - 1
        var used = last >= 0 ? widths[last] : 0
        var out = []
        for (var i = 0; i < last; i++) {
            if (used + gap + widths[i] > room)
                break
            used += gap + widths[i]
            out.push(hints[i])
        }
        if (last >= 0 && used <= room)
            out.push(hints[last])
        return out
    }
    FontMetrics { id: keyMetrics; font.family: Theme.font; font.pixelSize: Theme.caption; font.bold: true }
    FontMetrics { id: labelMetrics; font.family: Theme.font; font.pixelSize: Theme.caption }
    function hintWidth(h) {
        return keyMetrics.advanceWidth(h[0]) + 4 + labelMetrics.advanceWidth(h[1])
    }

    Rectangle { width: parent.width; height: 1; color: Theme.hairline }

    Row {
        id: facts
        anchors.left: parent.left
        anchors.leftMargin: Theme.padX
        anchors.verticalCenter: parent.verticalCenter
        spacing: Theme.gap * 1.5
        Text {
            id: countText
            visible: root.showCounts
            text: Store.connections.length + (Store.connections.length === 1 ? " connection" : " connections")
            color: Theme.muted
            font.family: Theme.font
            font.pixelSize: Theme.caption
        }
        Row {
            id: activeRow
            visible: root.showCounts && Sessions.activeCount > 0
            spacing: 4
            Glyph { text: ""; size: Theme.caption - 3; color: Theme.success; anchors.verticalCenter: parent.verticalCenter }
            Text {
                text: Sessions.activeCount + " active"
                color: Theme.success
                font.family: Theme.font
                font.pixelSize: Theme.caption
            }
        }
        Text {
            id: noticeText
            text: root.notice
            visible: text !== ""
            // Whatever room the hints leave; a long notice elides rather than running into them.
            width: Math.min(implicitWidth, Math.max(0, root.width - hintRow.width - 3 * Theme.padX - x))
            elide: Text.ElideRight
            color: root.noticeIsError ? Theme.urgent : Theme.foreground
            font.family: Theme.font
            font.pixelSize: Theme.caption
        }
    }

    Row {
        id: hintRow
        anchors.right: parent.right
        anchors.rightMargin: Theme.padX
        anchors.verticalCenter: parent.verticalCenter
        spacing: Theme.gap * 1.5
        Repeater {
            model: root.shownHints
            delegate: Row {
                required property var modelData
                spacing: 4
                Text {
                    text: modelData[0]
                    color: Theme.accent
                    font.family: Theme.font
                    font.pixelSize: Theme.caption
                    font.bold: true
                }
                Text {
                    text: modelData[1]
                    color: Theme.muted
                    font.family: Theme.font
                    font.pixelSize: Theme.caption
                }
            }
        }
    }
}
