import QtQuick
import QtQuick.Controls
import OMARemote

// Run by tests/test_paste.py: qml6 -platform offscreen paste.qml -- <mode> <Input.qml url>.
// Prints one "RESULT {json}" line and quits.
Window {
    id: root
    visible: true
    width: 300
    height: 100
    readonly property var args: Qt.application.arguments
    readonly property string mode: args[args.length - 2]

    // Writes the clipboard (copy) as an app would.
    TextInput { id: source }
    // A plain TextInput, unguarded: shows the test can see clipboard reads.
    TextInput { id: plain; property int reads: 0; onCanPasteChanged: reads++ }

    Loader { id: loader; width: parent.width; source: root.args[root.args.length - 1] }
    Connections { target: loader.item; function onCanPasteChanged() { root.reads++ } }
    property int reads: 0
    property int refused: 0
    Connections { target: PasteGuard; function onTooLong(field, maximum) { root.refused = maximum } }

    function setClipboard(text) { source.text = text; source.selectAll(); source.copy() }
    function done(result) { console.log("RESULT " + JSON.stringify(result)); Qt.exit(0) }

    // Once the window is up and active, so focus is real (it is what flips readOnly in a toggle).
    Timer {
        running: true
        interval: 50
        onTriggered: {
            root.requestActivate()
            try { root.start() } catch (e) { root.done({ error: String(e) }) }
        }
    }

    function start() {
        var field = loader.item
        if (mode === "guard") {
            field.forceActiveFocus()
            var focused = field.activeFocus
            setClipboard("one")
            plain.forceActiveFocus()
            setClipboard("two")
            field.forceActiveFocus()
            // Input.qml guarded itself on completion: a second cut finds nothing.
            var again = PasteGuard.guard(field)
            done({ focused: focused, again: again, reads: reads, plainReads: plain.reads, readOnly: field.readOnly,
                   menu: field.ContextMenu.menu === null })
        } else {
            if (mode === "short")
                field.maximumLength = 10
            field.text = "ab[sel]cd"
            field.select(2, 7)
            PasteGuard.paste(field, mode === "primary")
            wait.start()
        }
    }
    Timer { id: wait; interval: 2600; onTriggered: root.done({ text: loader.item.text, refused: root.refused,
                                                                  maximum: loader.item.maximumLength }) }
}
