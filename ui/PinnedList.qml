import QtQuick
import qs.Commons

// The connections list docked beside the session tabs while pinned, drawn as the connections
// tab's sidebar: running sessions under ACTIVE, the rest under their groups. The session area
// gives up this width, so a desktop that follows its tab resizes to fit next to it.
Rectangle {
    id: root
    // Every connection, favourites first then by name.
    property var model: []
    // The connection of the session on screen.
    property string currentConnection: ""
    signal unpin()
    // A click on a running connection switches to it; a double click connects any of them.
    signal switchRequested(string id)
    signal connectRequested(string id)

    // The row last clicked, outlined like the sidebar's keyboard cursor.
    property string pickedId: ""

    color: Theme.surface

    function isActive(c) {
        return Sessions.activeFor(c.id).length > 0
    }

    // [{title, connections}], ACTIVE first, then each group, then those without one.
    readonly property var sections: {
        Sessions.sessions
        var active = []
        var byGroup = {}
        var loose = []
        for (var i = 0; i < model.length; i++) {
            var c = model[i]
            if (isActive(c))
                active.push(c)
            else if (c.group)
                (byGroup[c.group] = byGroup[c.group] || []).push(c)
            else
                loose.push(c)
        }
        var out = []
        if (active.length > 0)
            out.push({ title: "ACTIVE", connections: active })
        var groups = Object.keys(byGroup).sort(function (a, b) { return a.localeCompare(b) })
        for (var g = 0; g < groups.length; g++)
            out.push({ title: groups[g].toUpperCase(), connections: byGroup[groups[g]] })
        if (loose.length > 0)
            out.push({ title: groups.length > 0 ? "OTHER" : "CONNECTIONS", connections: loose })
        if (out.length === 0)
            out.push({ title: "CONNECTIONS", connections: [] })
        return out
    }

    component Heading: Text {
        width: parent.width
        leftPadding: Theme.padX
        topPadding: Theme.gap * 1.5
        bottomPadding: Theme.gap * 0.5
        color: Theme.muted
        font.family: Theme.font
        font.pixelSize: Theme.caption
        font.bold: true
        font.letterSpacing: 1
    }

    Flickable {
        anchors.fill: parent
        anchors.margins: Theme.gap
        anchors.rightMargin: Theme.gap + 1
        contentHeight: column.height
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        Column {
            id: column
            width: parent.width
            spacing: 2

            Repeater {
                model: root.sections
                delegate: Column {
                    id: section
                    required property var modelData
                    required property int index
                    width: column.width
                    spacing: 2

                    Heading {
                        id: heading
                        text: section.modelData.title
                        topPadding: section.index === 0 ? Theme.gap * 0.5 : Theme.gap * 1.5

                        // Unpin sits on the first heading, where the sidebar has no control.
                        Rectangle {
                            visible: section.index === 0
                            anchors.right: parent.right
                            anchors.rightMargin: Theme.padX - (width - pinGlyph.implicitWidth) / 2
                            y: heading.topPadding + (heading.contentHeight - height) / 2
                            width: Theme.hitMin
                            height: Theme.hitMin
                            radius: Theme.radius
                            color: unpinMouse.containsMouse ? Theme.hover : "transparent"
                            Glyph {
                                id: pinGlyph
                                anchors.centerIn: parent
                                text: ""
                                size: Theme.caption
                                color: Theme.accent
                            }
                            MouseArea {
                                id: unpinMouse
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: root.unpin()
                            }
                        }
                    }

                    Repeater {
                        model: section.modelData.connections
                        delegate: SidebarRow {
                            required property var modelData
                            readonly property string state_: { Sessions.sessions; return Sessions.stateFor(modelData.id) }
                            icon: ""
                            label: modelData.name || modelData.host
                            note: String(modelData.protocol || "rdp").toUpperCase()
                            current: modelData.id === root.currentConnection
                            cursor: modelData.id === root.pickedId && !current
                            iconColor: state_ === "connected" ? Theme.success
                                     : state_ === "connecting" ? Theme.warning
                                     : state_ === "failed" ? Theme.urgent
                                     : (current ? Theme.accent : Theme.muted)
                            onClicked: {
                                root.pickedId = modelData.id
                                if (Sessions.activeFor(modelData.id).length > 0)
                                    root.switchRequested(modelData.id)
                            }
                            onDoubleClicked: root.connectRequested(modelData.id)
                        }
                    }
                }
            }
        }
    }

    Rectangle { anchors.right: parent.right; width: 1; height: parent.height; color: Theme.hairline }
}
