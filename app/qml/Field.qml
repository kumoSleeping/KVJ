import QtQuick
import QtQuick.Controls.Basic

// Single-line input on the inset tone; its outline shows only while focused.
TextField {
    id: control
    implicitHeight: Theme.control
    leftPadding: 10
    rightPadding: 10
    font.pixelSize: Theme.sizeSm
    color: Theme.text
    placeholderTextColor: Theme.faint
    selectionColor: Theme.line
    selectedTextColor: Theme.text
    background: Rectangle {
        radius: Theme.radius
        color: Theme.inset
        border.width: control.activeFocus ? 1 : 0
        border.color: Theme.muted
    }
}
