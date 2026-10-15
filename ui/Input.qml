import QtQuick
import QtQuick.Controls
import OMARemote
import qs.Ui as Kit
import "js/Limits.js" as Limits

// Omarchy's own text field, filling its row.
//
// It never reads the clipboard by itself (omarchy-plugin-marketplace#11361). Qt's TextInput asks
// the clipboard for its full text on every clipboard change while editable, and again whenever
// readOnly changes (q_canPasteChanged), which on Wayland means a transfer from whichever app owns
// it; the context menu's Paste reads canPaste too. So: the field is editable from the start and
// stays so, PasteGuard.guard cuts it loose from clipboard changes, there is no context menu, and
// pasting (ctrl+v, shift+insert, a middle click) goes through PasteGuard.paste: wl-paste, at most
// 16 KiB within 2 s, as one line. Checked in tests/test_paste.py.
//
// Every field has a maximum length (js/Limits.js; Limits.standard unless it names its own). A paste
// that would not fit is refused whole, with a hint, instead of being cut to what fits.
Kit.TextField {
    id: field
    width: parent ? parent.width : implicitWidth
    selectByMouse: true
    ContextMenu.menu: null
    maximumLength: Limits.standard

    // ShortcutField records ctrl+v as a shortcut: chords are its own, shift+insert still pastes.
    property bool keepsChords: false

    Component.onCompleted: PasteGuard.guard(field)

    Keys.onPressed: function (event) {
        if (!event.matches(StandardKey.Paste))
            return
        if (keepsChords && (event.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier)))
            return
        PasteGuard.paste(field, false)
        event.accepted = true
    }

    Connections {
        target: PasteGuard
        function onTooLong(target, maximum) {
            if (target === field)
                tooLongHint.show("Too long to paste here: at most " + maximum + " characters", 3000)
        }
    }

    Kit.PanelToolTip {
        id: tooLongHint
        delay: 0
    }

    // Qt pastes the selection on a middle click itself; this takes the click first.
    MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.MiddleButton
        cursorShape: Qt.IBeamCursor
        onClicked: function (mouse) {
            field.forceActiveFocus()
            field.cursorPosition = field.positionAt(mouse.x, mouse.y)
            PasteGuard.paste(field, true)
        }
    }
}
