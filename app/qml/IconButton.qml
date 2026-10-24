import QtQuick
import QtQuick.Controls.Basic

// A compact icon key: ink when available, faint when not, a soft plate on hover.
ToolButton {
    id: control
    property string iconName
    property string tip
    implicitWidth: Theme.control
    implicitHeight: Theme.control
    padding: 0
    icon.source: iconName ? "icons/" + iconName + ".svg" : ""
    icon.width: 16
    icon.height: 16
    icon.color: enabled ? (hovered ? Theme.text : Theme.muted) : Theme.faint
    background: Rectangle {
        radius: Theme.radius
        color: control.down ? Theme.line : control.hovered ? Theme.hover : "transparent"
    }
    ToolTip.visible: hovered && tip.length > 0
    ToolTip.delay: 600
    ToolTip.text: tip
}
