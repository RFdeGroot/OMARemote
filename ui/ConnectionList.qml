import QtQuick
import qs.Commons

ListView {
    id: root
    property string selectedId: ""
    property real now: Date.now() / 1000
    signal picked(string id)
    signal activated(string id)

    clip: true
    boundsBehavior: Flickable.StopAtBounds
    currentIndex: {
        for (var i = 0; i < count; i++)
            if (model[i] && model[i].id === selectedId)
                return i
        return -1
    }
    highlightMoveDuration: 0

    // Under group headings when grouped (the model is then sorted by group), in the sidebar's style.
    property bool grouped: false

    delegate: Column {
        id: entry
        required property var modelData
        required property int index
        readonly property string group: modelData.group || ""
        readonly property bool opensGroup: root.grouped
            && (index === 0 || (root.model[index - 1].group || "") !== group)
        width: ListView.view.width

        Text {
            visible: entry.opensGroup
            width: parent.width
            leftPadding: Theme.padX + 2
            topPadding: entry.index === 0 ? Theme.gap * 1.5 : Theme.gap * 2.5
            bottomPadding: Theme.gap * 0.5
            text: entry.group !== "" ? entry.group.toUpperCase() : "OTHER"
            color: Theme.muted
            font.family: Theme.font
            font.pixelSize: Theme.caption
            font.bold: true
            font.letterSpacing: 1
        }

        ConnectionRow {
            modelData: entry.modelData
            index: entry.index
            width: entry.width
            current: modelData.id === root.selectedId
            now: root.now
            onClicked: root.picked(modelData.id)
            onActivated: root.activated(modelData.id)
        }
    }

    // Relative times ("5 min ago") age while the window is open.
    Timer {
        interval: 30000
        repeat: true
        running: true
        onTriggered: root.now = Date.now() / 1000
    }
}
