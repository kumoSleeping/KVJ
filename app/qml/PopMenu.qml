import QtQuick
import QtQuick.Controls.Basic

// A small menu floating on the raised tone with its own edge, like the
// drop-downs' lists.
Menu {
    id: menu
    padding: 5
    implicitWidth: 196
    font.pixelSize: Theme.sizeSm
    delegate: MenuItem {
        id: item
        implicitHeight: 30
        leftPadding: 10
        rightPadding: 10
        topPadding: 0
        bottomPadding: 0
        readonly property bool risky: !!item.action && item.action.risky === true
        contentItem: Text {
            text: item.text
            font: menu.font
            color: !item.enabled ? Theme.faint : item.risky ? Theme.danger : Theme.text
            verticalAlignment: Text.AlignVCenter
            elide: Text.ElideRight
        }
        background: Rectangle {
            radius: Theme.radius - 1
            color: item.highlighted && item.enabled ? Theme.hover : "transparent"
        }
    }
    background: Rectangle {
        implicitWidth: menu.implicitWidth
        radius: Theme.radiusLg
        color: Theme.raised
        border.width: 1
        border.color: Theme.line
    }
}
