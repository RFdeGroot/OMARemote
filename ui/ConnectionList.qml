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

    delegate: ConnectionRow {
        current: modelData.id === root.selectedId
        now: root.now
        onClicked: root.picked(modelData.id)
        onActivated: root.activated(modelData.id)
    }

    // Relative times ("5 min ago") age while the window is open.
    Timer {
        interval: 30000
        repeat: true
        running: true
        onTriggered: root.now = Date.now() / 1000
    }
}
