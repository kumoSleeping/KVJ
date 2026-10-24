import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Controls.impl

// Text action with an optional icon. `primary` is the one ink-filled key per view.
Button {
    id: control
    property string iconName
    property bool primary: false
    readonly property color contentColor: !enabled ? Theme.faint : primary ? Theme.bg : Theme.text
    implicitHeight: primary ? 34 : Theme.control
    leftPadding: 12
    rightPadding: 14
    spacing: 6
    font.pixelSize: Theme.sizeSm
    font.weight: primary ? Font.DemiBold : Font.Medium
    icon.source: iconName ? "icons/" + iconName + ".svg" : ""
    icon.width: 14
    icon.height: 14
    icon.color: contentColor
    contentItem: IconLabel {
        spacing: control.spacing
        display: control.display
        icon: control.icon
        text: control.text
        font: control.font
        color: control.contentColor
    }
    background: Rectangle {
        implicitWidth: 64
        radius: Theme.radius
        color: control.primary ? (control.enabled ? (control.down ? Theme.muted : Theme.text) : Theme.line)
                               : (control.down ? Theme.line : control.hovered ? Theme.hover : Theme.raised)
    }
}
