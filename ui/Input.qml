import QtQuick
import qs.Ui as Kit

// Omarchy's own text field, filling its row.
//
// Read-only unless it has the keyboard: an editable TextInput asks the clipboard what it holds on
// every clipboard change (canPaste), which on Wayland means talking to whichever app owns it, so a
// field nobody is typing in (the search field behind a session tab, an editor's fields) must not be
// editable. It turns editable the moment it gets focus, so typing, pasting and clicking work as
// before (Qt 6.12, QQuickTextInput::q_canPasteChanged; omarchy-plugin-marketplace#11263).
Kit.TextField {
    width: parent ? parent.width : implicitWidth
    selectByMouse: true
    readOnly: !activeFocus
}
