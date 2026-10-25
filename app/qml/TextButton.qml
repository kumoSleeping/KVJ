import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Controls.impl

// Text action with an optional icon, on the control tone. `primary` is the one
// ink-filled key per region; `outlined` draws its edge instead of a fill, for a
// key that must read as one at a glance; `flat` has no plate until hovered.
Button {
    id: control
    property string iconName
    property bool primary: false
    property bool outlined: false
    readonly property color contentColor: !enabled ? Theme.faint : primary ? Theme.bg : Theme.text
    implicitHeight: Theme.control
    leftPadding: iconName ? 10 : 12
    rightPadding: 12
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
        implicitWidth: 56
        radius: Theme.radius
        color: control.primary ? (control.enabled ? (control.down ? Theme.body : control.hovered ? Qt.lighter(Theme.text, Theme.dark ? 0.92 : 1.6) : Theme.text) : Theme.line)
             : control.down ? Theme.selected
             : control.hovered && control.enabled ? Theme.hover
             : control.flat || control.outlined ? "transparent" : Theme.inset
        border.width: control.outlined && !control.primary ? 1 : 0
        border.color: control.enabled ? Theme.line : Theme.hover
        Behavior on color { ColorAnimation { duration: 90 } }
    }
}
