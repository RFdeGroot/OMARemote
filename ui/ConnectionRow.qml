import QtQuick
import qs.Commons
import "js/Format.js" as Format

Rectangle {
    id: root
    required property var modelData
    required property int index
    property bool current: false
    property real now: 0
    signal clicked()
    signal activated()

    readonly property string state_: { Sessions.sessions; return Sessions.stateFor(modelData.id) }
    readonly property string stage: {
        var live = Sessions.activeFor(modelData.id)
        return live.length > 0 && live[0].stage ? live[0].stage.toLowerCase() : "connecting"
    }
    readonly property color stateColor: state_ === "connected" ? Theme.success
                                      : state_ === "connecting" ? Theme.warning
                                      : state_ === "failed" ? Theme.urgent
                                      : (current ? Theme.accent : Theme.muted)

    width: ListView.view ? ListView.view.width : 0
    height: Math.round(Theme.body * 3.4)
    color: current ? Theme.selection : (mouse.containsMouse ? Theme.hover : "transparent")

    Rectangle {
        visible: root.current
        width: 2
        height: parent.height
        color: Theme.accent
    }

    Glyph {
        id: mark
        x: Theme.padX + 2
        width: Theme.icon * 1.6
        anchors.verticalCenter: parent.verticalCenter
        text: root.modelData.protocol === "ssh" ? "" : ""
        size: Theme.title
        color: root.stateColor
        SequentialAnimation on opacity {
            running: root.state_ === "connecting"
            loops: Animation.Infinite
            alwaysRunToEnd: true
            NumberAnimation { to: 0.35; duration: 500 }
            NumberAnimation { to: 1; duration: 500 }
        }
    }

    Column {
        anchors.left: mark.right
        anchors.leftMargin: Theme.gap
        anchors.right: meta.left
        anchors.rightMargin: Theme.gap
        anchors.verticalCenter: parent.verticalCenter
        spacing: 2
        Row {
            spacing: Theme.gap
            width: parent.width
            Text {
                text: root.modelData.name || root.modelData.host
                elide: Text.ElideRight
                width: Math.min(implicitWidth, parent.width - star.width - chip.width - 2 * Theme.gap)
                color: Theme.foreground
                font.family: Theme.font
                font.pixelSize: Theme.body
                font.bold: root.current
            }
            Glyph {
                id: star
                visible: root.modelData.favourite
                width: root.modelData.favourite ? implicitWidth : 0
                text: ""
                size: Theme.caption
                color: Theme.accent
                anchors.verticalCenter: parent.verticalCenter
            }
            Rectangle {
                id: chip
                anchors.verticalCenter: parent.verticalCenter
                width: chipText.implicitWidth + 8
                height: chipText.implicitHeight + 2
                radius: Theme.radius
                color: "transparent"
                border.width: 1
                border.color: Theme.hairline
                Text {
                    id: chipText
                    anchors.centerIn: parent
                    text: String(root.modelData.protocol || "rdp").toUpperCase()
                    color: Theme.muted
                    font.family: Theme.font
                    font.pixelSize: Theme.caption - 1
                    font.bold: true
                }
            }
        }
        Text {
            width: parent.width
            elide: Text.ElideRight
            text: {
                var who = Format.account(root.modelData)
                return (who ? who + " @ " : "") + Format.address(root.modelData)
            }
            color: Theme.muted
            font.family: Theme.font
            font.pixelSize: Theme.small
        }
    }

    Column {
        id: meta
        anchors.right: parent.right
        anchors.rightMargin: Theme.padX
        anchors.verticalCenter: parent.verticalCenter
        spacing: 2
        Text {
            anchors.right: parent.right
            text: root.state_ === "connected" ? "connected" : root.state_ === "connecting" ? root.stage + "…"
                : root.state_ === "failed" ? "failed" : Format.ago(root.modelData.lastConnected, root.now)
            color: root.state_ ? root.stateColor : Theme.muted
            font.family: Theme.font
            font.pixelSize: Theme.caption
        }
        Text {
            anchors.right: parent.right
            visible: text !== ""
            text: root.modelData.group || ""
            color: Theme.muted
            font.family: Theme.font
            font.pixelSize: Theme.caption
        }
    }

    Rectangle {
        anchors.bottom: parent.bottom
        anchors.left: mark.left
        anchors.right: parent.right
        height: 1
        color: Theme.hairline
        opacity: 0.6
    }

    MouseArea {
        id: mouse
        anchors.fill: parent
        hoverEnabled: true
        onClicked: root.clicked()
        onDoubleClicked: root.activated()
    }
}
