import QtQuick
import KVJ

// A small light with its word on a plate, at a heading's right: green while
// `on`, red while not.
Rectangle {
    id: light

    property string word: ""
    property bool on: false

    implicitWidth: lightRow.implicitWidth + 16
    implicitHeight: 22
    radius: 11
    color: Theme.inset
    Row {
        id: lightRow
        anchors.centerIn: parent
        spacing: 6
        Rectangle {
            anchors.verticalCenter: parent.verticalCenter
            width: 6
            height: 6
            radius: 3
            color: light.on ? "#30a46c" : Theme.danger
            Behavior on color { ColorAnimation { duration: Theme.quick } }
        }
        Text {
            text: light.word
            font.pixelSize: Theme.sizeXs
            font.weight: Font.Medium
            color: light.on ? Theme.text : Theme.muted
        }
    }
}
