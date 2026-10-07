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
        for (var i = 0; i < Store.groups.length; i++)
            out.push({ kind: "group", value: Store.groups[i] })
        for (var j = 0; j < Store.credentials.length; j++)
            out.push({ kind: "credential", value: Store.credentials[j].id })
        out.push({ kind: "newCredential", value: "" })
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
    property string editingCredential: ""
    signal picked(string filter)
    signal groupSettingsRequested(string name)
    signal credentialRequested(string id) // "" for a new set

    color: Theme.surface

    function countOf(f) {
        var list = Store.connections
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
        contentHeight: column.height
        clip: true
        boundsBehavior: Flickable.StopAtBounds

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
                    { f: "active", icon: "", label: "Active" }
                ]
                delegate: SidebarRow {
                    required property var modelData
                    icon: modelData.icon
                    label: modelData.label
                    count: { Store.connections; Sessions.sessions; return root.countOf(modelData.f) }
                    current: root.filter === modelData.f
                    cursor: root.hasCursor("filter", modelData.f)
                    iconColor: modelData.f === "active" && count > 0 ? Theme.success : (current ? Theme.accent : Theme.muted)
                    onClicked: root.picked(modelData.f)
                }
            }

            Heading { text: "GROUPS"; visible: Store.groups.length > 0 }
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
                }
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
}
