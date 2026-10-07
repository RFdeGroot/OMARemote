import QtQuick
import qs.Ui as Kit

// Omarchy's switch. The caller owns the value: bind `checked`, flip it on `toggled()`.
// Tab reaches it and Space or Enter flips it; focus draws the kit's own cursor ring.
Kit.ToggleSwitch {
    id: root
    activeFocusOnTab: true
    // The ring always reserves its padding, so focus never shifts the layout.
    cursorRing: true
    hasCursor: activeFocus
    Keys.onPressed: function (event) {
        if (event.key === Qt.Key_Space || event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            root.toggled()
            event.accepted = true
        }
    }
}
