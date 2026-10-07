import QtQuick

// A Nerd Font icon drawn in the theme's own monospace face.
Text {
    property real size: Theme.icon
    font.family: Theme.font
    font.pixelSize: size
    color: Theme.foreground
    verticalAlignment: Text.AlignVCenter
    horizontalAlignment: Text.AlignHCenter
    textFormat: Text.PlainText
}
