import QtQuick
import QtQuick.Controls.Basic

// A slim track with an ink fill and a round handle ringed in the card's tone;
// faint while disabled. `large`: a thicker track and a bigger handle, easier
// to catch.
Slider {
    id: control
    property bool large: false
    implicitHeight: large ? 32 : Theme.control
    background: Rectangle {
        x: control.leftPadding
        y: control.topPadding + control.availableHeight / 2 - height / 2
        width: control.availableWidth
        height: control.large ? 6 : 4
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
        implicitWidth: control.large ? 18 : 14
        implicitHeight: control.large ? 18 : 14
        radius: width / 2
        color: control.enabled ? Theme.text : Theme.faint
        border.width: 2
        border.color: Theme.raised
        scale: control.pressed ? 1.15 : control.hovered ? 1.06 : 1
        Behavior on scale { NumberAnimation { duration: 90 } }
    }
}
