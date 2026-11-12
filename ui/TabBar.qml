import QtQuick
import qs.Commons

// Connections, then one tab per session, drawn the way Flea draws its tabs: a compact strip,
// caption-size titles, fixed-width tabs, an accent edge under the current one.
Item {
    id: root
    // [{id, title, state}] for the session tabs.
    property var tabs: []
    property string current: "home"
    signal picked(string id)
    signal closed(string id)
    signal monitorPicked(string id, int index)

    implicitHeight: Theme.chrome
    // Every session tab is the same width until the strip runs out of room, then they share it.
    readonly property int tabWidth: {
        var full = Math.round(Theme.caption * 12) + Theme.hitMin + 2 * Theme.padX
        var room = (width - home.width) / Math.max(1, tabs.length)
        return Math.round(Math.max(Theme.hitMin * 3, Math.min(full, room)))
    }

    component Tab: Item {
        id: tab
        property string tabId: ""
        property string title: ""
        property string mark: ""
        property color markColor: Theme.muted
        property real markSize: Theme.caption
        property bool closable: false
        property bool last: false
        property var monitors: []
        property int monitor: -1
        readonly property bool on: root.current === tabId
        // Numbers only, inside the tab we already have. Too little room hides them; the tab does not grow.
        readonly property int iconPx: {
            var n = monitors ? Math.min(8, monitors.length) : 0
            if (n < 1)
                return 0
            var markW = Theme.padX + Math.round(Theme.caption * 0.8) + Math.round(Theme.gap * 0.75)
            var closeW = closable ? Theme.hitMin : Theme.padX
            var sliver = Math.round(Theme.caption * 1.5)
            var gaps = (n - 1) * 2
            var room = width - markW - closeW - sliver - gaps
            var each = Math.floor(room / n)
            var cap = Math.max(6, Math.round(Theme.caption * 1.15))
            if (each < 6)
                return 0
            return Math.min(cap, each)
        }
        height: root.height

        Rectangle {
            anchors.fill: parent
            color: tab.on ? Theme.background : (mouse.containsMouse ? Theme.hover : "transparent")
        }
        // Flush on the strip's bottom edge, replacing the hairline there.
        Rectangle {
            visible: tab.on
            anchors.bottom: parent.bottom
            width: parent.width
            height: 3
            color: Theme.accent
        }
        Rectangle {
            visible: !tab.on && !tab.last
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            width: 1
            height: parent.height * 0.45
            color: Theme.foreground
            opacity: 0.12
        }
        Glyph {
            id: markGlyph
            visible: tab.mark !== ""
            anchors.left: parent.left
            anchors.leftMargin: Theme.padX
            anchors.verticalCenter: parent.verticalCenter
            text: tab.mark
            size: tab.markSize
            color: tab.markColor
        }
        Text {
            anchors.left: markGlyph.visible ? markGlyph.right : parent.left
            anchors.leftMargin: markGlyph.visible ? Theme.gap * 0.75 : Theme.padX
            anchors.right: tab.iconPx > 0 ? iconRow.left : (tab.closable ? closeHit.left : parent.right)
            anchors.rightMargin: tab.iconPx > 0 ? 2 : (tab.closable ? 0 : Theme.padX)
            anchors.verticalCenter: parent.verticalCenter
            text: tab.title
            elide: Text.ElideRight
            textFormat: Text.PlainText
            color: tab.on ? Theme.foreground : Theme.muted
            font.family: Theme.font
            font.pixelSize: Theme.caption
        }
        MouseArea {
            id: mouse
            anchors.fill: parent
            hoverEnabled: true
            acceptedButtons: Qt.LeftButton | Qt.MiddleButton
            onClicked: function (event) {
                if (event.button === Qt.MiddleButton && tab.closable)
                    root.closed(tab.tabId)
                else
                    root.picked(tab.tabId)
            }
        }
        // Drawn after the tab's click area so a number is a monitor switch, not a tab pick.
        Row {
            id: iconRow
            visible: tab.iconPx >= 6
            anchors.right: tab.closable ? closeHit.left : parent.right
            anchors.rightMargin: 1
            anchors.verticalCenter: parent.verticalCenter
            spacing: 2
            Repeater {
                model: (tab.monitors || []).slice(0, 8)
                delegate: Item {
                    id: icon
                    required property int index
                    width: tab.iconPx
                    height: tab.iconPx
                    readonly property bool active: index === tab.monitor
                    Rectangle {
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.top: parent.top
                        anchors.bottom: parent.bottom
                        anchors.bottomMargin: Math.max(1, parent.height * 0.16)
                        color: "transparent"
                        radius: 1
                        border.width: icon.active ? 2 : 1
                        border.color: icon.active ? Theme.accent : Theme.hairline
                    }
                    Rectangle {
                        anchors.horizontalCenter: parent.horizontalCenter
                        anchors.bottom: parent.bottom
                        width: Math.max(2, parent.width * 0.42)
                        height: Math.max(1, parent.height * 0.12)
                        radius: 1
                        color: icon.active ? Theme.accent : Theme.muted
                    }
                    Text {
                        anchors.centerIn: parent
                        anchors.verticalCenterOffset: -parent.height * 0.08
                        text: String(index + 1)
                        textFormat: Text.PlainText
                        color: icon.active ? Theme.accent : Theme.muted
                        font.family: Theme.font
                        font.pixelSize: Math.max(6, Math.round(tab.iconPx * 0.5))
                    }
                    MouseArea {
                        anchors.fill: parent
                        acceptedButtons: Qt.LeftButton
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.monitorPicked(tab.tabId, icon.index)
                    }
                }
            }
        }
        // The mark stays put and its target never shrinks; only the ink answers the pointer.
        Item {
            id: closeHit
            visible: tab.closable
            anchors.right: parent.right
            width: Theme.hitMin
            height: parent.height
            Glyph {
                anchors.centerIn: parent
                text: ""
                size: Theme.caption
                color: closeMouse.containsMouse ? Theme.urgent : (tab.on ? Theme.foreground : Theme.muted)
            }
            MouseArea {
                id: closeMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.closed(tab.tabId)
            }
        }
    }

    Row {
        height: parent.height
        Tab {
            id: home
            tabId: "home"
            title: "Connections"
            mark: ""
            markColor: on ? Theme.accent : Theme.muted
            width: implicitTitle.implicitWidth + Theme.caption * 1.5 + Theme.gap * 0.75 + 2 * Theme.padX
            last: root.tabs.length === 0
            Text { textFormat: Text.PlainText; id: implicitTitle; visible: false; text: "Connections"; font.family: Theme.font; font.pixelSize: Theme.caption }
        }
        Repeater {
            model: root.tabs
            delegate: Tab {
                required property var modelData
                required property int index
                width: root.tabWidth
                tabId: modelData.id
                title: modelData.title
                mark: ""
                markSize: Math.round(Theme.caption * 0.6)
                markColor: modelData.state === "connected" ? Theme.success
                         : modelData.state === "connecting" ? Theme.warning
                         : modelData.state === "failed" ? Theme.urgent : Theme.muted
                closable: true
                last: index === root.tabs.length - 1
                monitors: modelData.monitors || []
                monitor: modelData.monitor === undefined ? -1 : modelData.monitor
            }
        }
    }
}
