import QtQuick
import qs.Commons
import "js/Format.js" as Format

Rectangle {
    id: root
    property string notice: ""
    property bool noticeIsError: false
    // A Gliff stream's stats line (Format.parseStats), shown where the notice goes while there is
    // none: a dot for the link's health and as many facts as fit; a click opens all of them.
    property string info: ""
    readonly property var stats: Format.parseStats(info)
    readonly property bool showStats: stats !== null && notice === ""
    readonly property string statsReason: Format.statsReason(stats)
    // The facts after the reason, which Format.statsParts puts first.
    readonly property var statsParts: Format.statsParts(stats).slice(statsReason ? 1 : 0)
    property bool statsOpen: false
    onShowStatsChanged: if (!showStats) statsOpen = false
    readonly property color statsColor: !stats ? Theme.muted : stats.health === "bad" ? Theme.urgent
                                        : stats.health === "warn" ? Theme.warning : Theme.success
    // The facts that fit in what the hints leave: the reason (when not green) and fps always.
    readonly property string statsText: {
        var room = width - hintRow.width - 3 * Theme.padX - statsBox.x - statsDot.width - statsRow.spacing
                   - (statsReason ? labelMetrics.advanceWidth(statsReason + "· ") + 2 * statsRow.spacing : 0)
        var out = ""
        for (var i = 0; i < statsParts.length; i++) {
            var next = out ? out + " · " + statsParts[i] : statsParts[i]
            if (i > 0 && labelMetrics.advanceWidth(next) > room)
                break
            out = next
        }
        return out
    }
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
                   - (showStats ? facts.spacing + statsDot.width + statsRow.spacing
                                  + labelMetrics.advanceWidth((statsReason ? statsReason + " · " : "") + (statsParts[0] || "")) : 0)
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
    // Session keys are given as ctrl+alt+…; drawn as Settings › Keyboard has them (Keymap.session).
    function hintWidth(h) {
        return keyMetrics.advanceWidth(Keymap.session(h[0])) + 4 + labelMetrics.advanceWidth(h[1])
    }

    Rectangle { width: parent.width; height: 1; color: Theme.hairline }

    Row {
        id: facts
        anchors.left: parent.left
        anchors.leftMargin: Theme.padX
        anchors.verticalCenter: parent.verticalCenter
        spacing: Theme.gap * 1.5
        Text {
            textFormat: Text.PlainText
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
                textFormat: Text.PlainText
                text: Sessions.activeCount + " active"
                color: Theme.success
                font.family: Theme.font
                font.pixelSize: Theme.caption
            }
        }
        Item {
            id: statsBox
            visible: root.showStats
            width: statsRow.implicitWidth
            height: statsRow.implicitHeight
            Row {
                id: statsRow
                spacing: 4
                Glyph { id: statsDot; text: ""; size: Theme.caption - 3; color: root.statsColor; anchors.verticalCenter: parent.verticalCenter }
                Text {
                    textFormat: Text.PlainText
                    visible: root.statsReason !== ""
                    text: root.statsReason
                    color: root.statsColor
                    font.family: Theme.font
                    font.pixelSize: Theme.caption
                }
                Text {
                    textFormat: Text.PlainText
                    text: (root.statsReason && root.statsText ? "· " : "") + root.statsText
                    color: Theme.muted
                    font.family: Theme.font
                    font.pixelSize: Theme.caption
                }
            }
            // The bar's full height over the dot and the facts: a click opens the card.
            MouseArea {
                width: parent.width
                height: root.height
                y: (parent.height - height) / 2
                cursorShape: Qt.PointingHandCursor
                onClicked: root.statsOpen = !root.statsOpen
            }
        }
        Text {
            textFormat: Text.PlainText
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
                    textFormat: Text.PlainText
                    text: Keymap.session(modelData[0])
                    color: Theme.accent
                    font.family: Theme.font
                    font.pixelSize: Theme.caption
                    font.bold: true
                }
                Text {
                    textFormat: Text.PlainText
                    text: modelData[1]
                    color: Theme.muted
                    font.family: Theme.font
                    font.pixelSize: Theme.caption
                }
            }
        }
    }

    // Every fact of the stream, over the session just above the bar; a click on it or the line closes it.
    Rectangle {
        id: statsCard
        visible: root.statsOpen && root.showStats
        x: Math.min(facts.x + statsBox.x, root.width - width - Theme.padX)
        anchors.bottom: parent.top
        anchors.bottomMargin: Theme.gap
        width: statsGrid.implicitWidth + 2 * Theme.panelPad
        height: statsColumn.implicitHeight + 2 * Theme.panelPad
        radius: Theme.radius
        color: Theme.raised
        border.color: Theme.hairline
        z: 10
        MouseArea { anchors.fill: parent; onClicked: root.statsOpen = false }
        Column {
            id: statsColumn
            x: Theme.panelPad
            y: Theme.panelPad
            spacing: Theme.gap
            Grid {
                id: statsGrid
                columns: 2
                columnSpacing: Theme.gap * 2
                rowSpacing: 4
                Repeater {
                    model: [].concat.apply([], Format.statsRows(root.stats))
                    delegate: Text {
                        required property var modelData
                        required property int index
                        textFormat: Text.PlainText
                        // The label column muted, the value column (and a not-green verdict) stands out.
                        text: modelData
                        color: index % 2 === 0 ? Theme.muted : index === 1 && root.stats.health !== "ok" ? root.statsColor : Theme.foreground
                        font.family: Theme.font
                        font.pixelSize: Theme.small
                    }
                }
            }
            Text {
                textFormat: Text.PlainText
                width: statsGrid.implicitWidth
                wrapMode: Text.WordWrap
                text: "Gliff sends a picture only when the screen changes: a still screen shows few fps."
                color: Theme.muted
                font.family: Theme.font
                font.pixelSize: Theme.caption
            }
        }
    }
}
