import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import KVJ

// The picture sources, one tile each, in a column that scrolls: the main
// track (画面 1), the aux tracks that have entries (画面 2..4, each with its
// own play key and what it plays) and the cameras taken in. Pressing a tile
// puts that source in the preview's chosen slot (PVW); 应用 puts it on the
// air. A tile on the air has an ink edge, one in the preview a faint one.
//
//   sources:  [{ id, name, kind: "track" | "camera", track, player }]
//   textures: the window's SourceTextures (Desk.textures)
//   slot:     the preview's chosen slot index (SwitcherPanel.selected)
//   cameraIds: the cameras taken in; addCamera(id) / removeCamera(id) ask
//             the host to change them
Card {
    id: column

    property var sources: []
    property SourceTextures textures: null
    property int slot: 0
    property var cameraIds: []
    signal addCamera(string id)
    signal removeCamera(string id)

    readonly property var onAir: Switcher.sourcesOf(Switcher.program)
    readonly property var inPreview: Switcher.sourcesOf(Switcher.preview)

    function take(id) {
        const slots = Switcher.preview && Switcher.preview.slots ? Switcher.preview.slots : []
        if (slots.length === 0)
            Switcher.addSlot(id)
        else
            Switcher.updateSlot(Math.max(0, Math.min(column.slot, slots.length - 1)), { source: id })
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: Theme.gap
        spacing: 8

        RowLayout {
            Layout.fillWidth: true
            spacing: 2
            Heading {
                Layout.fillWidth: true
                text: "画面"
            }
            // The cameras are listed only once asked for: nothing touches the
            // camera stack before.
            IconButton {
                id: addKey
                implicitWidth: 26
                implicitHeight: 26
                iconName: "plus"
                iconSize: 14
                tip: "添加相机画面"
                onClicked: cameraMenu.popup(addKey, 0, addKey.height + 2)
            }
        }
        PopMenu {
            id: cameraMenu
            Instantiator {
                model: cameraMenu.visible ? (Cameras.list.length ? Cameras.list : [{ id: "", name: "没有找到相机" }]) : []
                delegate: PopAction {
                    required property var modelData
                    text: modelData.name
                    enabled: !!modelData.id && column.cameraIds.indexOf(modelData.id) < 0
                    onTriggered: column.addCamera(modelData.id)
                }
                onObjectAdded: (index, object) => cameraMenu.insertAction(index, object)
                onObjectRemoved: (index, object) => cameraMenu.removeAction(object)
            }
        }

        Flickable {
            id: list
            Layout.fillWidth: true
            Layout.fillHeight: true
            contentWidth: width
            contentHeight: tiles.implicitHeight
            clip: true
            interactive: contentHeight > height
            boundsBehavior: Flickable.StopAtBounds
            ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

            Column {
                id: tiles
                width: list.width
                spacing: 10
                Repeater {
                    model: column.sources
                    Item {
                        id: tile
                        required property var modelData
                        readonly property string key: modelData.id
                        readonly property var player: modelData.player || null
                        readonly property bool aux: modelData.kind === "track" && modelData.track > 0
                        readonly property var texture: {
                            column.textures ? column.textures.revision : 0
                            column.textures ? column.textures.map : null
                            return column.textures ? column.textures.texture(key) : null
                        }
                        readonly property real ratio: column.textures ? column.textures.aspect(key) : 16 / 9
                        width: tiles.width
                        height: picture.height + caption.implicitHeight + 6

                        Rectangle {
                            id: picture
                            width: parent.width
                            height: Math.round(width * 9 / 16)
                            radius: Theme.radius
                            color: "black"
                            border.width: column.onAir.indexOf(tile.key) >= 0 ? 2 : column.inPreview.indexOf(tile.key) >= 0 ? 1 : 0
                            border.color: column.onAir.indexOf(tile.key) >= 0 ? Theme.text : Theme.muted
                            // The source's own picture, fitted.
                            ShaderEffect {
                                readonly property real fit: Math.min(parent.width / Math.max(0.01, tile.ratio), parent.height)
                                width: fit * tile.ratio
                                height: fit
                                anchors.centerIn: parent
                                visible: !!tile.texture
                                property var source: tile.texture
                            }
                            Text {
                                anchors.centerIn: parent
                                visible: !tile.texture
                                text: "无画面"
                                font.pixelSize: Theme.sizeXs
                                color: "#80ffffff"
                            }
                            MouseArea {
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                onClicked: column.take(tile.key)
                                ToolTip.visible: containsMouse
                                ToolTip.delay: 700
                                ToolTip.text: "放进合成预览选中的位置"
                                hoverEnabled: true
                            }
                        }
                        RowLayout {
                            id: caption
                            y: picture.height + 6
                            width: parent.width
                            spacing: 4
                            IconButton {
                                visible: tile.aux && !!tile.player
                                implicitWidth: 22
                                implicitHeight: 22
                                iconSize: 13
                                iconName: tile.player && tile.player.playing ? "pause" : "play"
                                tip: tile.player && tile.player.playing ? "暂停这条轨道" : "播放这条轨道"
                                onClicked: tile.player.toggle()
                            }
                            Text {
                                Layout.fillWidth: true
                                text: tile.modelData.name
                                      + (tile.aux && tile.player && tile.player.entry ? " · " + tile.player.entry.title : "")
                                font.pixelSize: Theme.sizeXs
                                font.weight: column.onAir.indexOf(tile.key) >= 0 ? Font.DemiBold : Font.Normal
                                color: Theme.body
                                elide: Text.ElideRight
                            }
                            IconButton {
                                visible: tile.modelData.kind === "camera"
                                implicitWidth: 22
                                implicitHeight: 22
                                iconSize: 13
                                iconName: "x"
                                tip: "移除这个相机"
                                onClicked: column.removeCamera(tile.key.substring(7))
                            }
                        }
                    }
                }
            }
        }
    }
}
