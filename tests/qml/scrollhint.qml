import QtQuick

// Run by tests/test_scrollhint.py: qml6 -platform offscreen scrollhint.qml -- <ScrollHint.qml url>.
// A ListView taller inside than out (as the connection lists) and a pane whose content fits, each
// with ui/ScrollHint.qml; prints one "RESULT {json}" line of what the bars showed, and quits.
Window {
    id: root
    visible: true
    width: 400
    height: 300
    readonly property var args: Qt.application.arguments
    readonly property url hint: args[args.length - 1]
    property var seen: ({})

    // Away from the corner: the offscreen platform's pointer rests at 0,0, which would be hovering.
    ListView {
        id: list
        x: 20
        y: 50
        width: 180
        height: 200
        model: 100
        delegate: Text { text: "row " + index; height: 20 }
        Loader { id: listHint; source: root.hint; onLoaded: item.flickable = list }
    }
    Flickable {
        id: short
        x: 210
        y: 50
        width: 180
        height: 200
        contentHeight: 100
        Loader { id: shortHint; source: root.hint; onLoaded: item.flickable = short }
    }

    // The steps, each a moment apart; `shown` and the bar's opacity at each.
    property int step: 0
    property bool anyShownAtStart: false
    Timer {
        // Every frame of the first half second: a bar flashing up while the list lays out.
        interval: 16; repeat: true; running: root.step === 0
        onTriggered: if (listHint.item && (listHint.item.shown || listHint.item.opacity > 0)) root.anyShownAtStart = true
    }
    Timer {
        interval: 500; repeat: true; running: true
        onTriggered: {
            const s = root.step++
            const h = listHint.item
            if (s === 1) {
                root.seen.atRest = { shown: h.shown, visible: h.visible }
                list.contentY = 400        // a scroll (the wheel, or keys moving the selection)
            } else if (s === 2) {
                root.seen.scrolled = { shown: h.shown, visible: h.visible }
            } else if (s === 4) {
                // 1 s after the scroll: faded out again.
                root.seen.later = { shown: h.shown, visible: h.visible, opacity: h.opacity }
                short.contentY = 0
                root.seen.fits = { shown: shortHint.item.shown, visible: shortHint.item.visible }
                root.seen.anyShownAtStart = root.anyShownAtStart
                console.log("RESULT " + JSON.stringify(root.seen))
                Qt.exit(0)
            }
        }
    }
}
