import QtQuick
import qs.Commons

Rectangle {
    id: root
    property string notice: ""
    property bool noticeIsError: false
    property var hints: []

    height: Math.round(Theme.small * 2.2)
    color: Theme.surface

    Rectangle { width: parent.width; height: 1; color: Theme.hairline }

    Row {
        id: facts
        anchors.left: parent.left
        anchors.leftMargin: Theme.padX
        anchors.verticalCenter: parent.verticalCenter
        spacing: Theme.gap * 1.5
        Text {
            text: Store.connections.length + (Store.connections.length === 1 ? " connection" : " connections")
            color: Theme.muted
            font.family: Theme.font
            font.pixelSize: Theme.caption
        }
        Row {
            visible: Sessions.activeCount > 0
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
            model: root.hints
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
