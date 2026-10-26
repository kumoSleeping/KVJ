import QtQuick
import QtQuick.Layouts
import KVJ

// The layouts to start from, each a key with a small drawing of itself:
// pressed, it becomes the preview (PVW), the sources taken in their order.
// 画中画 puts its inset in the corner of the key that is pressed.
//
//   sources: [{ id, name }] in the order they are used
//   aspect:  the projected picture's width / height
GridLayout {
    id: presets

    property var sources: []
    property real aspect: 16 / 9
    columns: 2
    columnSpacing: 8
    rowSpacing: 8

    // The preset (and corner) the preview was made from, by its name.
    readonly property string current: Switcher.preview ? Switcher.preview.name : ""

    Repeater {
        model: Switcher.presets
        Rectangle {
            id: key
            required property var modelData
            readonly property bool pip: modelData.key === "pip"
            // The corner the pointer is over (画中画 only), else the one
            // the preview has.
            property string hovered: ""
            readonly property string corner: hovered || (chosen && Switcher.presetKey(presets.current) ? Switcher.presetKey(presets.current).corner : "") || "br"
            readonly property var sample: Switcher.preset(modelData.key, ["a", "b", "c", "d"], corner)
            readonly property bool chosen: presets.current === modelData.name
                                           || (pip && presets.current.indexOf(modelData.name) === 0)
            Layout.fillWidth: true
            Layout.preferredWidth: 100
            implicitHeight: drawing.height + label.implicitHeight + 22
            radius: Theme.radius
            color: area.pressed ? Theme.selected : chosen ? Theme.selected : area.containsMouse ? Theme.hover : Theme.inset
            Behavior on color { ColorAnimation { duration: 90 } }

            // The layout in small: the picture, its slots.
            Rectangle {
                id: drawing
                x: 10
                y: 10
                width: parent.width - 20
                height: width / Math.max(0.2, presets.aspect)
                radius: 3
                color: Theme.dark ? "#0b0d11" : "#d9d9de"
                clip: true
                Repeater {
                    model: key.sample ? key.sample.slots : []
                    Rectangle {
                        required property var modelData
                        required property int index
                        readonly property real shortSide: Math.min(width, height)
                        x: modelData.x * drawing.width + 1
                        y: modelData.y * drawing.height + 1
                        width: modelData.w * drawing.width - 2
                        height: modelData.h * drawing.height - 2
                        z: modelData.z
                        radius: modelData.mask.shape === "round" ? modelData.mask.radius * shortSide : 2
                        color: index === 0 ? (key.chosen ? Theme.muted : Theme.faint)
                                           : (key.chosen ? Theme.text : Theme.muted)
                        opacity: index === 0 ? 0.7 : 1
                    }
                }
            }
            Text {
                id: label
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.top: drawing.bottom
                anchors.topMargin: 6
                width: parent.width - 12
                horizontalAlignment: Text.AlignHCenter
                elide: Text.ElideRight
                text: key.pip && (area.containsMouse || key.chosen) ? key.sample.name : key.modelData.name
                font.pixelSize: Theme.sizeXs
                font.weight: key.chosen ? Font.DemiBold : Font.Medium
                color: key.chosen ? Theme.text : Theme.body
            }
            MouseArea {
                id: area
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onPositionChanged: mouse => {
                    if (key.pip)
                        key.hovered = (mouse.y < height / 2 ? "t" : "b") + (mouse.x < width / 2 ? "l" : "r")
                }
                onExited: key.hovered = ""
                onClicked: Switcher.setPreviewPreset(key.modelData.key, (presets.sources || []).map(s => s.id), key.corner)
            }
        }
    }
}
