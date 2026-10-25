import QtQuick
import QtQuick.Controls.Basic

// A compact icon key: muted ink, full ink when hovered or `active`, faint when
// not available; a soft plate under the pointer.
ToolButton {
    id: control
    property string iconName
    property string tip
    property bool active: false
    property int iconSize: 16
    implicitWidth: Theme.control
    implicitHeight: Theme.control
    padding: 0
    icon.source: iconName ? "icons/" + iconName + ".svg" : ""
    icon.width: iconSize
    icon.height: iconSize
    icon.color: enabled ? (hovered || active ? Theme.text : Theme.muted) : Theme.faint
    background: Rectangle {
        radius: Theme.radius
        color: control.down ? Theme.selected : control.hovered || control.active ? Theme.hover : "transparent"
        Behavior on color { ColorAnimation { duration: 90 } }
    }
    ToolTip.visible: hovered && tip.length > 0
    ToolTip.delay: 600
    ToolTip.text: tip
}
