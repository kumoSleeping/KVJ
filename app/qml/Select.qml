import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Controls.impl

// Drop-down on the control tone; the list floats on the raised tone with its
// own edge.
ComboBox {
    id: control
    implicitHeight: Theme.control
    leftPadding: 10
    rightPadding: 28
    font.pixelSize: Theme.sizeSm
    contentItem: Text {
        text: control.displayText
        font: control.font
        color: control.enabled ? Theme.text : Theme.faint
        verticalAlignment: Text.AlignVCenter
        elide: Text.ElideRight
    }
    indicator: ColorImage {
        x: control.width - width - 8
        y: (control.height - height) / 2
        source: "icons/chevron-down.svg"
        sourceSize: Qt.size(14, 14)
        color: control.enabled ? Theme.muted : Theme.faint
    }
    background: Rectangle {
        radius: Theme.radius
        color: control.down || control.popup.visible ? Theme.selected : control.hovered && control.enabled ? Theme.hover : Theme.inset
        border.width: control.visualFocus ? 1 : 0
        border.color: Theme.muted
        Behavior on color { ColorAnimation { duration: 90 } }
    }
    delegate: ItemDelegate {
        id: item
        required property int index
        required property var modelData
        width: ListView.view.width
        height: 30
        rightPadding: 10
        topPadding: 0
        bottomPadding: 0
        leftPadding: 10
        highlighted: control.highlightedIndex === index
        contentItem: Text {
            text: item.modelData
            font.pixelSize: Theme.sizeSm
            font.weight: control.currentIndex === item.index ? Font.DemiBold : Font.Normal
            color: control.currentIndex === item.index ? Theme.text : Theme.body
            verticalAlignment: Text.AlignVCenter
            elide: Text.ElideRight
        }
        background: Rectangle {
            radius: Theme.radius - 1
            color: item.highlighted ? Theme.hover : "transparent"
        }
    }
    popup: Popup {
        y: control.height + 4
        width: Math.max(control.width, 220)
        implicitHeight: Math.min(contentItem.implicitHeight + 8, 320)
        padding: 5
        contentItem: ListView {
            clip: true
            implicitHeight: contentHeight
            model: control.popup.visible ? control.delegateModel : null
            currentIndex: control.highlightedIndex
            ScrollIndicator.vertical: ScrollIndicator {}
        }
        background: Rectangle {
            radius: Theme.radiusLg
            color: Theme.raised
            border.width: 1
            border.color: Theme.line
        }
    }
}
