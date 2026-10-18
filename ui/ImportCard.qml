import QtQuick
import QtQuick.Layouts
import qs.Commons
import "js/Format.js" as Format

// What an import from another client (.rdp files, Remmina, 1Remote, ~/.ssh/config) would add, before it
// does: one row per connection found, the new ones switched on. What is here already, listed
// twice or cannot be taken in shows why and stays off. j/k or the arrows move, space switches,
// enter imports, esc cancels.
FocusScope {
    id: root
    readonly property var preview: Sync.importPreview
    readonly property bool opened: preview !== null
    readonly property var entries: preview ? preview.entries : []
    property var picked: ({})
    property int cursor: 0
    signal closed()

    readonly property var pickedRefs: entries.filter(function (e) { return pickable(e) && !!picked[e.ref] })
                                             .map(function (e) { return e.ref })
    function count(status) {
        return entries.filter(function (e) { return e.status === status }).length
    }
    function pickable(e) {
        return e.status === "new" || e.status === "trashed"
    }
    function toggle(i) {
        var e = entries[i]
        if (!e || !pickable(e))
            return
        var next = Object.assign({}, picked)
        next[e.ref] = !next[e.ref]
        picked = next
    }
    function statusText(e) {
        if (e.status === "here") return "already here"
        if (e.status === "twice") return "listed twice"
        if (e.status === "trashed") return "in Recently deleted"
        if (e.status === "invalid") return e.reason
        return ""
    }
    function close() {
        Sync.importPreview = null
    }
    onOpenedChanged: if (!opened) closed()

    onPreviewChanged: {
        // entries may not follow yet: read the preview itself.
        var found = preview ? preview.entries : []
        var next = {}
        for (var i = 0; i < found.length; i++)
            if (found[i].status === "new")
                next[found[i].ref] = true
        picked = next
        cursor = 0
        if (opened)
            forceActiveFocus()
    }

    visible: opened

    Keys.onPressed: function (event) {
        if (event.key === Qt.Key_Escape)
            root.close()
        else if (event.key === Qt.Key_J || event.key === Qt.Key_Down || event.key === Qt.Key_Tab)
            cursor = Math.min(entries.length - 1, cursor + 1)
        else if (event.key === Qt.Key_K || event.key === Qt.Key_Up || event.key === Qt.Key_Backtab)
            cursor = Math.max(0, cursor - 1)
        else if (event.key === Qt.Key_Space)
            toggle(cursor)
        else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter)
            Sync.applyForeign(pickedRefs)
        list.positionViewAtIndex(cursor, ListView.Contain)
        event.accepted = true
    }

    Rectangle {
        anchors.fill: parent
        color: Util.alpha(Theme.background, 0.6)
        MouseArea { anchors.fill: parent; onClicked: root.close() }
    }

    Rectangle {
        anchors.centerIn: parent
        width: Math.min(620, parent.width - 2 * Theme.panelPad)
        height: body.implicitHeight + 2 * Theme.panelPad
        radius: Theme.radius
        color: Theme.surface
        border.width: 1
        border.color: Theme.hairline
        MouseArea { anchors.fill: parent }

        ColumnLayout {
            id: body
            x: Theme.panelPad
            y: Theme.panelPad
            width: parent.width - 2 * Theme.panelPad
            spacing: Theme.gap

            Text {
                textFormat: Text.PlainText
                Layout.fillWidth: true
                elide: Text.ElideRight
                text: "Import from " + (root.preview ? root.preview.title : "")
                color: Theme.foreground
                font.family: Theme.font
                font.pixelSize: Theme.title
                font.bold: true
            }
            Text {
                textFormat: Text.PlainText
                Layout.fillWidth: true
                wrapMode: Text.Wrap
                text: {
                    var parts = [root.count("new") + " new"]
                    if (root.count("here")) parts.push(root.count("here") + " already here")
                    if (root.count("trashed")) parts.push(root.count("trashed") + " in Recently deleted")
                    if (root.count("twice")) parts.push(root.count("twice") + " listed twice")
                    if (root.count("invalid")) parts.push(root.count("invalid") + " cannot be imported")
                    return parts.join(" · ")
                }
                color: Theme.muted
                font.family: Theme.font
                font.pixelSize: Theme.small
            }

            ListView {
                id: list
                Layout.fillWidth: true
                Layout.preferredHeight: Math.min(contentHeight, root.height * 0.55)
                clip: true
                model: root.entries
                currentIndex: root.cursor
                delegate: Rectangle {
                    required property var modelData
                    required property int index
                    readonly property bool canPick: root.pickable(modelData)
                    width: ListView.view.width
                    height: rowBody.implicitHeight + Theme.gap
                    radius: Theme.radius
                    color: root.cursor === index ? Util.alpha(Theme.accent, 0.15) : "transparent"
                    MouseArea {
                        anchors.fill: parent
                        onClicked: { root.cursor = index; root.toggle(index) }
                    }
                    RowLayout {
                        id: rowBody
                        anchors.verticalCenter: parent.verticalCenter
                        x: Theme.gap
                        width: parent.width - 2 * Theme.gap
                        spacing: Theme.gap
                        Check {
                            enabled: canPick
                            opacity: canPick ? 1 : 0.4
                            activeFocusOnTab: false
                            checked: !!root.picked[modelData.ref]
                            onToggled: { root.cursor = index; root.toggle(index) }
                        }
                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 0
                            Text {
                                textFormat: Text.PlainText
                                Layout.fillWidth: true
                                elide: Text.ElideRight
                                text: modelData.name
                                color: canPick ? Theme.foreground : Theme.muted
                                font.family: Theme.font
                                font.pixelSize: Theme.body
                            }
                            Text {
                                textFormat: Text.PlainText
                                Layout.fillWidth: true
                                elide: Text.ElideRight
                                text: [modelData.protocol.toUpperCase() + "  "
                                       + (modelData.username ? modelData.username + "@" : "") + modelData.host
                                       + (modelData.port !== Format.defaultPort(modelData.protocol)
                                          ? ":" + modelData.port : "")
                                       // Where the sign-in goes too: a gateway is shown, never hidden.
                                       + (modelData.gateway ? "  via gateway " + modelData.gateway : ""),
                                       modelData.group].concat(modelData.notes).join("  ·  ")
                                color: Theme.muted
                                font.family: Theme.font
                                font.pixelSize: Theme.small
                            }
                        }
                        Text {
                            textFormat: Text.PlainText
                            visible: text !== ""
                            Layout.maximumWidth: list.width * 0.35
                            elide: Text.ElideRight
                            text: root.statusText(modelData)
                            color: modelData.status === "invalid" ? Theme.urgent : Theme.muted
                            font.family: Theme.font
                            font.pixelSize: Theme.small
                        }
                    }
                }
            }

            Text {
                textFormat: Text.PlainText
                Layout.fillWidth: true
                wrapMode: Text.Wrap
                visible: root.preview !== null && root.preview.errors.length > 0
                text: root.preview ? root.preview.errors.slice(0, 3).join("\n")
                      + (root.preview.errors.length > 3 ? "\n… and " + (root.preview.errors.length - 3) + " more" : "") : ""
                color: Theme.urgent
                font.family: Theme.font
                font.pixelSize: Theme.small
            }
            Text {
                textFormat: Text.PlainText
                Layout.fillWidth: true
                wrapMode: Text.Wrap
                text: "Connections that are here already stay exactly as they are, so importing again adds "
                      + "nothing twice. Passwords stay behind, and nothing turns off certificate checks or "
                      + "shares a folder: switch those on yourself where you want them."
                color: Theme.muted
                font.family: Theme.font
                font.pixelSize: Theme.small
            }
            RowLayout {
                Layout.fillWidth: true
                spacing: Theme.gap
                Item { Layout.fillWidth: true }
                ActionButton { text: "Cancel"; onClicked: root.close() }
                ActionButton {
                    primary: true
                    enabled: root.pickedRefs.length > 0
                    text: "Import " + root.pickedRefs.length
                    onClicked: Sync.applyForeign(root.pickedRefs)
                }
            }
        }
    }
}
