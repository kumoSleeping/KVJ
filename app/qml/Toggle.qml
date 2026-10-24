import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Controls.impl

// A small check key: ink when on, an outline when off.
CheckBox {
    id: control
    spacing: 6
    font.pixelSize: Theme.sizeSm
    indicator: Rectangle {
        implicitWidth: 16
        implicitHeight: 16
        x: control.leftPadding
        y: (control.height - height) / 2
        radius: 4
        color: control.checked ? Theme.text : "transparent"
        border.width: control.checked ? 0 : 1
        border.color: Theme.muted
        ColorImage {
            anchors.centerIn: parent
            visible: control.checked
            source: "icons/check.svg"
            sourceSize: Qt.size(12, 12)
            color: Theme.bg
        }
    }
    contentItem: Text {
        leftPadding: control.indicator.width + control.spacing
        text: control.text
        font: control.font
        color: control.checked ? Theme.text : Theme.muted
        verticalAlignment: Text.AlignVCenter
    }
}
