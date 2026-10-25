import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Controls.impl

// A small check key: ink when on, an outline when off.
CheckBox {
    id: control
    spacing: 7
    font.pixelSize: Theme.sizeSm
    indicator: Rectangle {
        implicitWidth: 16
        implicitHeight: 16
        x: control.leftPadding
        y: (control.height - height) / 2
        radius: 4
        color: control.checked ? (control.enabled ? Theme.text : Theme.faint) : control.hovered ? Theme.hover : "transparent"
        border.width: control.checked ? 0 : 1.5
        border.color: control.hovered && control.enabled ? Theme.muted : Theme.faint
        ColorImage {
            anchors.centerIn: parent
            visible: control.checked
            source: "icons/check.svg"
            sourceSize: Qt.size(12, 12)
            color: Theme.raised
        }
    }
    contentItem: Text {
        leftPadding: control.indicator.width + control.spacing
        text: control.text
        font: control.font
        color: !control.enabled ? Theme.faint : control.checked ? Theme.text : Theme.muted
        verticalAlignment: Text.AlignVCenter
    }
}
