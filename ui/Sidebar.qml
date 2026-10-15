import QtQuick
import qs.Commons

// Library filters and the groups connections carry, Flea's rail in miniature.
Rectangle {
    id: root
    property string filter: "all"
    // Keyboard: while focused, cursor indexes entries (views, groups, credential sets, new set).
    property bool focused: false
    property int cursor: 0
    readonly property var entries: {
        var out = [{ kind: "filter", value: "all" }, { kind: "filter", value: "favourites" },
                   { kind: "filter", value: "recent" }, { kind: "filter", value: "active" }]
        if (Store.trash.length > 0)
            out.push({ kind: "filter", value: "trash" })
        for (var i = 0; i < Store.groups.length; i++)
            out.push({ kind: "group", value: Store.groups[i] })
        out.push({ kind: "newGroup", value: "" })
        for (var j = 0; j < Store.credentials.length; j++)
            out.push({ kind: "credential", value: Store.credentials[j].id })
        out.push({ kind: "newCredential", value: "" })
        if (Updates.canUpdate)
            out.push({ kind: "update", value: "" })
        if (Updates.pluginOffered)
            out.push({ kind: "pluginInstall", value: "" })
        else if (Updates.pluginNewer)
            out.push({ kind: "pluginUpdate", value: "" })
        return out
    }
    function indexOf(kind, value) {
        for (var i = 0; i < entries.length; i++)
            if (entries[i].kind === kind && entries[i].value === value)
                return i
        return -1
    }
    function hasCursor(kind, value) {
        return focused && entries[cursor] !== undefined && entries[cursor].kind === kind && entries[cursor].value === value
    }

    property string editingGroup: ""
    property bool creatingGroup: false
    // A connection being dragged, and the group it is in: the groups take it, and "No group" shows.
    property bool dragging: false
    property string dragGroup: ""
    property string editingCredential: ""
    signal picked(string filter)
    signal groupSettingsRequested(string name) // "" for a new group
    signal droppedOnGroup(string name) // "" for none, "\n" for a new one
    signal credentialRequested(string id) // "" for a new set
    signal aboutRequested()

    color: Theme.surface

    function countOf(f) {
        if (f === "trash")
            return Store.trash.length
        // Quick connections count where they show: Recent and Active.
        var list = f === "recent" || f === "active" ? Store.connections.concat(Store.quickConnections) : Store.connections
        var n = 0
        for (var i = 0; i < list.length; i++) {
            var c = list[i]
            if (f === "favourites" ? c.favourite
                : f === "recent" ? c.lastConnected > 0
                : f === "active" ? Sessions.activeFor(c.id).length > 0
                : f.indexOf("group:") === 0 ? c.group === f.slice(6)
                : true)
                n++
        }
        return n
    }

    component Heading: Text {
        textFormat: Text.PlainText
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
        id: pane
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: footer.top
        anchors.margins: Theme.gap
        contentHeight: column.height
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        ScrollHint { flickable: pane }

        Column {
            id: column
            width: parent.width
            spacing: 2

            Heading { text: "LIBRARY"; topPadding: Theme.gap * 0.5 }
            Repeater {
                model: [
                    { f: "all", icon: "", label: "All connections" },
                    { f: "favourites", icon: "", label: "Favourites" },
                    { f: "recent", icon: "", label: "Recent" },
                    { f: "active", icon: "", label: "Active" },
                    { f: "trash", icon: "", label: "Recently deleted" }
                ]
                delegate: SidebarRow {
                    required property var modelData
                    visible: modelData.f !== "trash" || Store.trash.length > 0
                    icon: modelData.icon
                    label: modelData.label
                    count: { Store.connections; Store.quickConnections; Store.trash; Sessions.sessions; return root.countOf(modelData.f) }
                    current: root.filter === modelData.f
                    cursor: root.hasCursor("filter", modelData.f)
                    iconColor: modelData.f === "active" && count > 0 ? Theme.success : (current ? Theme.accent : Theme.muted)
                    onClicked: root.picked(modelData.f)
                }
            }

            Heading { text: "GROUPS" }
            Repeater {
                model: Store.groups
                delegate: SidebarRow {
                    required property string modelData
                    readonly property var info: { Store.groupSettings; return Store.group(modelData) }
                    icon: "\uf07b"
                    label: modelData
                    count: { Store.connections; return root.countOf("group:" + modelData) }
                    current: root.filter === "group:" + modelData || root.editingGroup === modelData
                    cursor: root.hasCursor("group", modelData)
                    // The gear stays visible on groups that set something, so their settings are findable.
                    action: "\uf013"
                    actionPinned: !!info.credential || Object.keys(info.settings).length > 0
                    onClicked: root.picked("group:" + modelData)
                    onRightClicked: root.groupSettingsRequested(modelData)
                    onActionClicked: root.groupSettingsRequested(modelData)
                    dropTarget: root.dragging && root.dragGroup !== modelData
                    onDropped: root.droppedOnGroup(modelData)
                }
            }
            // While dragging a grouped connection: out of its group.
            SidebarRow {
                visible: root.dragging && root.dragGroup !== ""
                icon: "\uf05e"
                label: "No group"
                dropTarget: visible
                onDropped: root.droppedOnGroup("")
            }
            SidebarRow {
                icon: "\uf067"
                label: root.dragging ? "Into a new group" : "New group"
                current: root.creatingGroup
                cursor: root.hasCursor("newGroup", "")
                dropTarget: root.dragging
                onClicked: root.groupSettingsRequested("")
                onDropped: root.droppedOnGroup("\n")
            }

            Heading { text: "CREDENTIALS" }
            Repeater {
                model: Store.credentials
                delegate: SidebarRow {
                    required property var modelData
                    icon: "\uf084"
                    label: Store.credentialLabel(modelData)
                    count: { Store.stored; Store.groupSettings; return Store.credentialUsers(modelData.id).connections }
                    current: root.editingCredential === modelData.id
                    cursor: root.hasCursor("credential", modelData.id)
                    onClicked: root.credentialRequested(modelData.id)
                    onRightClicked: root.credentialRequested(modelData.id)
                }
            }
            SidebarRow {
                icon: "\uf067"
                label: "New credential set"
                current: root.editingCredential === "new"
                cursor: root.hasCursor("newCredential", "")
                onClicked: root.credentialRequested("")
            }
        }
    }

    // The mark at the bottom; above it the update button when GitHub has a newer release.
    Column {
        id: footer
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.margins: Theme.gap
        spacing: Theme.gap * 0.5

        ActionButton {
            id: updateButton
            visible: Updates.canUpdate
            width: parent.width
            primary: true
            fontSize: Theme.caption
            icon: "\uf019"
            text: "Update to " + Updates.latest
            onClicked: Updates.install()

            // The sidebar's keyboard cursor, drawn over the button so its fill does not hide it.
            Rectangle {
                anchors.fill: parent
                anchors.margins: -2
                visible: root.hasCursor("update", "")
                radius: Theme.radius + 2
                color: "transparent"
                border.width: 2
                border.color: Theme.foreground
            }
        }
        Text {
            textFormat: Text.PlainText
            width: parent.width
            leftPadding: Theme.padX
            elide: Text.ElideRight
            visible: Updates.checkout && Updates.newer
            text: Updates.latest + " released"
            color: Theme.muted
            font.family: Theme.font
            font.pixelSize: Theme.caption - 1
        }

        // The Omarchy bar plugin: installed from here when missing, updated when it has a new release.
        ActionButton {
            visible: Updates.pluginOffered || Updates.pluginNewer
            width: parent.width
            primary: Updates.pluginNewer
            fontSize: Theme.caption
            icon: Updates.pluginOffered ? "\uf067" : "\uf019"
            text: Updates.pluginOffered ? "Install bar plugin" : "Update bar plugin"
            onClicked: Updates.pluginOffered ? Updates.installPlugin() : Updates.updatePlugin()

            Rectangle {
                anchors.fill: parent
                anchors.margins: -2
                visible: root.hasCursor("pluginInstall", "") || root.hasCursor("pluginUpdate", "")
                radius: Theme.radius + 2
                color: "transparent"
                border.width: 2
                border.color: Theme.foreground
            }
        }
        // "hide" declines the offer for good (x or del on the button does the same).
        Row {
            visible: Updates.pluginOffered
            leftPadding: Theme.padX
            spacing: Theme.gap
            Text {
                textFormat: Text.PlainText
                text: "Bar plugin not installed"
                color: Theme.muted
                font.family: Theme.font
                font.pixelSize: Theme.caption - 1
            }
            Text {
                textFormat: Text.PlainText
                text: "hide"
                color: hideMouse.containsMouse ? Theme.foreground : Theme.muted
                font.family: Theme.font
                font.pixelSize: Theme.caption - 1
                font.underline: true
                MouseArea {
                    id: hideMouse
                    anchors.fill: parent
                    anchors.margins: -4
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: Updates.declinePlugin(true)
                }
            }
        }
        // OMARemote's mark and name; a click opens the About card, which has the version.
        Item {
            width: parent.width
            height: brand.height + Theme.gap * 0.5
            Row {
                id: brand
                anchors.bottom: parent.bottom
                x: Theme.padX
                spacing: 8
                OmaremoteMark {
                    anchors.verticalCenter: parent.verticalCenter
                }
                Wordmark {
                    anchors.verticalCenter: parent.verticalCenter
                    text: "OMAREMOTE"
                    split: 3
                    secondColor: Theme.muted
                }
            }
            MouseArea {
                id: brandMouse
                anchors.fill: brand
                anchors.margins: -4
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.aboutRequested()
            }
        }
    }
}
