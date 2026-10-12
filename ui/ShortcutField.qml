import QtQuick

// A shortcut, typed ("SUPER + ALT + W") or recorded: with the field focused, press the keys. A
// combination Hyprland binds already never reaches the field; Hotkeys.conflict names it then.
Input {
    id: root
    signal recorded(string text)

    placeholderText: "press the keys, e.g. SUPER + ALT + W"

    // Hyprland's names for the keys that are not a letter, digit or F-key.
    readonly property var names: ({
        [Qt.Key_Return]: "RETURN", [Qt.Key_Enter]: "RETURN", [Qt.Key_Space]: "SPACE", [Qt.Key_Tab]: "TAB",
        [Qt.Key_Minus]: "MINUS", [Qt.Key_Equal]: "EQUAL", [Qt.Key_Comma]: "COMMA", [Qt.Key_Period]: "PERIOD",
        [Qt.Key_Slash]: "SLASH", [Qt.Key_Semicolon]: "SEMICOLON", [Qt.Key_Apostrophe]: "APOSTROPHE",
        [Qt.Key_BracketLeft]: "BRACKETLEFT", [Qt.Key_BracketRight]: "BRACKETRIGHT",
        [Qt.Key_Backslash]: "BACKSLASH", [Qt.Key_QuoteLeft]: "GRAVE", [Qt.Key_Home]: "HOME",
        [Qt.Key_End]: "END", [Qt.Key_PageUp]: "PRIOR", [Qt.Key_PageDown]: "NEXT",
        [Qt.Key_Insert]: "INSERT", [Qt.Key_Up]: "UP", [Qt.Key_Down]: "DOWN", [Qt.Key_Left]: "LEFT",
        [Qt.Key_Right]: "RIGHT"
    })

    function keyName(key) {
        if (key >= Qt.Key_A && key <= Qt.Key_Z) return String.fromCharCode(key)
        if (key >= Qt.Key_0 && key <= Qt.Key_9) return String.fromCharCode(key)
        if (key >= Qt.Key_F1 && key <= Qt.Key_F24) return "F" + (key - Qt.Key_F1 + 1)
        return names[key] || ""
    }

    Keys.onPressed: function (event) {
        var m = event.modifiers
        // Typing stays typing; a chord with Super, Ctrl or Alt is recorded.
        if (!(m & (Qt.MetaModifier | Qt.ControlModifier | Qt.AltModifier)))
            return
        // ctrl+s and ctrl+⏎ still save the editor.
        if ((m & (Qt.MetaModifier | Qt.ControlModifier | Qt.AltModifier)) === Qt.ControlModifier
                && [Qt.Key_S, Qt.Key_Return, Qt.Key_Enter].indexOf(event.key) >= 0)
            return
        var key = keyName(event.key)
        if (!key)
            return
        var parts = []
        if (m & Qt.MetaModifier) parts.push("SUPER")
        if (m & Qt.ControlModifier) parts.push("CTRL")
        if (m & Qt.AltModifier) parts.push("ALT")
        if (m & Qt.ShiftModifier) parts.push("SHIFT")
        parts.push(key)
        root.text = parts.join(" + ")
        root.recorded(root.text)
        event.accepted = true
    }
}
