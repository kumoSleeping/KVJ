import QtQuick
import QtQuick.Controls.Basic

// Thin track with an ink fill and a round handle.
Slider {
    id: control
    implicitHeight: Theme.control
    background: Rectangle {
        x: control.leftPadding
        y: control.topPadding + control.availableHeight / 2 - height / 2
        width: control.availableWidth
        height: 3
        radius: 1.5
        color: Theme.line
        // Filled from the centre for a signed value, from the start otherwise.
        Rectangle {
            readonly property real zero: control.from < 0 && control.to > 0 ? (0 - control.from) / (control.to - control.from) : 0
            x: Math.min(zero, control.visualPosition) * parent.width
            width: Math.abs(control.visualPosition - zero) * parent.width
            height: parent.height
            radius: 1.5
            color: Theme.text
        }
    }
    handle: Rectangle {
        x: control.leftPadding + control.visualPosition * (control.availableWidth - width)
        y: control.topPadding + control.availableHeight / 2 - height / 2
        implicitWidth: 14
        implicitHeight: 14
        radius: 7
        color: Theme.text
        scale: control.pressed ? 1.15 : 1
    }
}
