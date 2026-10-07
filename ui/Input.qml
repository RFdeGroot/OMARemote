import QtQuick
import qs.Ui as Kit

// Omarchy's own text field, filling its row.
Kit.TextField {
    width: parent ? parent.width : implicitWidth
    selectByMouse: true
}
