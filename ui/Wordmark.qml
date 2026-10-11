import QtQuick

// A word in pixel capitals on the mark's grid: one-cell strokes, square corners, five cells high.
// Letters from `split` on take the second colour (OMA|REMOTE).
Item {
    id: root
    property string text: "OMAREMOTE"
    property int cell: 2
    property int split: -1
    property color color: Theme.foreground
    property color secondColor: color

    // Each letter's rows, '#' a cell.
    readonly property var glyphs: ({
        "O": ["####", "#..#", "#..#", "#..#", "####"],
        "M": ["#...#", "##.##", "#.#.#", "#...#", "#...#"],
        "A": ["####", "#..#", "####", "#..#", "#..#"],
        "R": ["####", "#..#", "####", "#.#.", "#..#"],
        "E": ["####", "#...", "###.", "#...", "####"],
        "T": ["###", ".#.", ".#.", ".#.", ".#."]
    })

    // [x, y, width, second] runs, laid out with one empty cell between letters.
    readonly property var layout: {
        var out = []
        var x = 0
        for (var i = 0; i < text.length; i++) {
            var g = glyphs[text[i]]
            if (!g) { x += 3; continue }
            for (var y = 0; y < g.length; y++) {
                var row = g[y]
                for (var c = 0; c < row.length; c++) {
                    if (row[c] !== "#") continue
                    var w = 1
                    while (row[c + w] === "#") w++
                    out.push([x + c, y, w, split >= 0 && i >= split])
                    c += w - 1
                }
            }
            x += g[0].length + 1
        }
        return { runs: out, cells: Math.max(0, x - 1) }
    }

    implicitWidth: layout.cells * cell
    implicitHeight: 5 * cell

    Repeater {
        model: root.layout.runs
        Rectangle {
            x: modelData[0] * root.cell
            y: modelData[1] * root.cell
            width: modelData[2] * root.cell
            height: root.cell
            color: modelData[3] ? root.secondColor : root.color
        }
    }
}
