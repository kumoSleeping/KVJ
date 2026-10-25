import QtQuick
import QtQuick.Controls.Basic

// Thin track with an ink fill and a round handle; faint while disabled.
// `large`: a thicker track and a bigger handle, easier to catch.
Slider {
    id: control
    property bool large: false
    implicitHeight: large ? 34 : Theme.control
    background: Rectangle {
        x: control.leftPadding
        y: control.topPadding + control.availableHeight / 2 - height / 2
        width: control.availableWidth
        height: control.large ? 5 : 3
        radius: height / 2
        color: Theme.line
        // Filled from the centre for a signed value, from the start otherwise.
        Rectangle {
            readonly property real zero: control.from < 0 && control.to > 0 ? (0 - control.from) / (control.to - control.from) : 0
            x: Math.min(zero, control.visualPosition) * parent.width
            width: Math.abs(control.visualPosition - zero) * parent.width
            height: parent.height
            radius: parent.radius
            color: control.enabled ? Theme.text : Theme.faint
        }
    }
    handle: Rectangle {
        x: control.leftPadding + control.visualPosition * (control.availableWidth - width)
        y: control.topPadding + control.availableHeight / 2 - height / 2
        implicitWidth: control.large ? 20 : 14
        implicitHeight: control.large ? 20 : 14
        radius: width / 2
        color: control.enabled ? Theme.text : Theme.faint
        scale: control.pressed ? 1.15 : 1
    }
}
