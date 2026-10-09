import QtQuick
import QtQuick.Shapes

// The settings mark, Flea's: Lucide's "sliders-vertical" (ISC licence, lucide.dev), drawn on its
// 24 unit grid at stroke 2 with Omarchy's square caps, scaled to the slot.
Item {
    id: root
    property color color: "white"
    property real size: 16

    implicitWidth: size
    implicitHeight: size

    Shape {
        width: 24
        height: 24
        x: (root.width - root.size) / 2
        y: (root.height - root.size) / 2
        preferredRendererType: Shape.CurveRenderer
        transform: Scale { xScale: root.size / 24; yScale: root.size / 24 }

        ShapePath {
            strokeColor: root.color
            fillColor: "transparent"
            strokeWidth: 2
            capStyle: ShapePath.SquareCap
            joinStyle: ShapePath.MiterJoin
            PathSvg { path: "M4 21v-7 M4 10V3 M12 21v-9 M12 8V3 M20 21v-5 M20 12V3 M2 14h4 M10 8h4 M18 16h4" }
        }
    }
}
