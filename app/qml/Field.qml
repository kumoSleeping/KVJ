import QtQuick
import QtQuick.Controls.Basic

// Single-line input on the control tone; an edge while hovered, an ink edge
// while typing.
TextField {
    id: control
    implicitHeight: Theme.control
    leftPadding: 10
    rightPadding: 10
    font.pixelSize: Theme.sizeSm
    color: Theme.text
    placeholderTextColor: Theme.faint
    selectionColor: Theme.selected
    selectedTextColor: Theme.text
    background: Rectangle {
        radius: Theme.radius
        color: Theme.inset
        border.width: 1
        border.color: control.activeFocus ? Theme.muted : control.hovered ? Theme.line : Theme.inset
    }
}
