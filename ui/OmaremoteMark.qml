import QtQuick

// OMARemote's mark, the app icon (share/icons/hicolor/scalable/apps/omaremote.svg) drawn cell by
// cell in the theme's colours instead of the file's fixed Tokyo Night: a monitor showing the
// Omarchy mark with its arrow. The icon's 24 cell grid without its border, 21 by 22 cells; a whole
// pixel per cell keeps the edges as sharp as the file's.
Item {
    id: root
    property int cell: 1
    property color frameColor: Theme.accent
    property color markColor: Theme.success

    implicitWidth: 21 * cell
    implicitHeight: 22 * cell

    // [x, y, width] runs of one row each, as in the SVG, shifted to the grid's corner.
    readonly property var frame: [[0,0,21],[0,1,1],[20,1,1],[0,2,1],[20,2,1],[0,3,1],[20,3,1],[0,4,1],[20,4,1],[0,5,1],[20,5,1],[0,6,1],[20,6,1],[0,7,1],[20,7,1],[0,8,1],[20,8,1],[0,9,1],[20,9,1],[0,10,1],[20,10,1],[0,11,1],[20,11,1],[0,12,1],[20,12,1],[0,13,1],[20,13,1],[0,14,1],[20,14,1],[0,15,1],[20,15,1],[0,16,1],[20,16,1],[0,17,1],[20,17,1],[0,18,11],[12,18,9],[10,19,1],[10,20,1],[6,21,9]]
    readonly property var mark: [[3,2,15],[3,3,1],[10,3,1],[17,3,1],[3,4,1],[5,4,6],[14,4,2],[17,4,1],[3,5,1],[5,5,1],[15,5,1],[17,5,1],[3,6,1],[5,6,1],[15,6,1],[17,6,1],[3,7,1],[5,7,1],[11,7,1],[15,7,1],[17,7,1],[3,8,1],[5,8,1],[11,8,2],[15,8,1],[17,8,1],[3,9,11],[15,9,1],[17,9,1],[3,10,1],[5,10,1],[11,10,2],[15,10,1],[17,10,1],[3,11,1],[5,11,1],[11,11,1],[15,11,1],[17,11,1],[3,12,1],[5,12,1],[15,12,1],[17,12,1],[3,13,1],[5,13,1],[15,13,1],[17,13,1],[3,14,1],[5,14,11],[17,14,1],[3,15,1],[10,15,1],[17,15,1],[3,16,8],[12,16,6]]

    Repeater {
        model: root.frame
        Rectangle {
            x: modelData[0] * root.cell
            y: modelData[1] * root.cell
            width: modelData[2] * root.cell
            height: root.cell
            color: root.frameColor
        }
    }
    Repeater {
        model: root.mark
        Rectangle {
            x: modelData[0] * root.cell
            y: modelData[1] * root.cell
            width: modelData[2] * root.cell
            height: root.cell
            color: root.markColor
        }
    }
}
