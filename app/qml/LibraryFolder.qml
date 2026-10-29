import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Controls.impl
import Qt.labs.folderlistmodel
import KVJ

// One folder in Library's file list: its row (a press opens or closes it),
// then, open, what is in it: its folders (each one of these, loaded only
// when opened) and its videos and pictures. Rows are chosen and dragged
// through `lib` (Library).
Column {
    id: node

    property var lib
    property string url
    property string name
    property int depth: 0
    // A root (one of the folders added): open at first, a menu to take it off.
    property bool root: false
    readonly property bool open: !!lib && lib.isOpen(url, root)

    width: parent ? parent.width : 0

    Item {
        id: head
        width: node.width
        height: 26
        Rectangle {
            anchors.fill: parent
            color: headArea.containsMouse ? Theme.hover : "transparent"
            radius: Theme.radius
        }
        MouseArea {
            id: headArea
            anchors.fill: parent
            hoverEnabled: true
            acceptedButtons: Qt.LeftButton | Qt.RightButton
            cursorShape: Qt.PointingHandCursor
            onClicked: mouse => {
                if (mouse.button === Qt.RightButton && node.root)
                    lib.rootMenu(node.url, head, mouse.x, mouse.y)
                else if (mouse.button === Qt.LeftButton)
                    lib.setOpen(node.url, !node.open)
            }
        }
        Row {
            anchors.fill: parent
            Item { width: 6 + node.depth * 12; height: 1 }
            ColorImage {
                anchors.verticalCenter: parent.verticalCenter
                source: "icons/chevron-right.svg"
                sourceSize: Qt.size(12, 12)
                color: Theme.faint
                rotation: node.open ? 90 : 0
                Behavior on rotation { NumberAnimation { duration: 120; easing.type: Easing.OutQuad } }
            }
            Item { width: 4; height: 1 }
            ColorImage {
                anchors.verticalCenter: parent.verticalCenter
                source: node.open ? "icons/folder-open.svg" : "icons/folder.svg"
                sourceSize: Qt.size(14, 14)
                color: Theme.muted
            }
            Item { width: 6; height: 1 }
            Text {
                anchors.verticalCenter: parent.verticalCenter
                width: head.width - x - 8
                text: node.name
                font.pixelSize: Theme.sizeSm
                font.weight: node.root ? Font.DemiBold : Font.Medium
                color: Theme.text
                elide: Text.ElideMiddle
            }
        }
    }

    // What is in it, only while it is open: each list of a folder keeps a
    // thread and a watch of its own, and a closed one must hold none.
    Loader {
        active: node.open
        // Closed, it takes no room: a Loader keeps its last size, but a
        // Column skips what is not visible. (No height of its own: a Loader
        // squeezes what it loads into one.)
        visible: node.open
        width: node.width
        sourceComponent: Column {
            width: node.width
            Repeater {
                model: FolderListModel {
                    id: files
                    folder: node.url
                    showDirsFirst: true
                    showDotAndDotDot: false
                    showHidden: false
                    caseSensitive: false
                    sortCaseSensitive: false
                    nameFilters: node.lib ? node.lib.filters : []
                }
                Loader {
                    id: entry
                    required property int index
                    required property string fileName
                    required property url fileUrl
                    required property bool fileIsDir
                    width: node.width
                    // A folder in it, as one of these (loaded by name: a type may not hold itself).
                    Component.onCompleted: {
                        if (fileIsDir)
                            setSource("LibraryFolder.qml", { lib: node.lib, url: String(fileUrl), name: fileName, depth: node.depth + 1 })
                        else
                            sourceComponent = fileRow
                    }
                    Component {
                        id: fileRow
                        Rectangle {
                            id: rowBox
                            readonly property string url: String(entry.fileUrl)
                            readonly property bool video: lib.isVideo(url)
                            readonly property bool chosen: !!lib.selected[url]
                            readonly property var tracks: lib.placedTracks(url)
                            readonly property string alike: lib.alikeOf(url)
                            width: node.width
                            height: 26
                            radius: Theme.radius
                            color: chosen ? Theme.selected : area.containsMouse ? Theme.hover : "transparent"
                            Row {
                                anchors.fill: parent
                                Item { width: 6 + (node.depth + 1) * 12 + 16; height: 1 }
                                ColorImage {
                                    anchors.verticalCenter: parent.verticalCenter
                                    source: rowBox.video ? "icons/film.svg" : "icons/image.svg"
                                    sourceSize: Qt.size(14, 14)
                                    color: rowBox.video ? Theme.body : Theme.muted
                                }
                                Item { width: 6; height: 1 }
                                Text {
                                    id: nameText
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: Math.min(implicitWidth, rowBox.width - x - tag.width - 10 - (alikeMark.visible ? 20 : 0))
                                    text: entry.fileName
                                    font.pixelSize: Theme.sizeSm
                                    color: Theme.text
                                    elide: Text.ElideMiddle
                                }
                                // Sounds like another entry on its track: following cannot tell them apart.
                                Item {
                                    id: alikeMark
                                    visible: rowBox.alike !== ""
                                    width: visible ? 20 : 0
                                    height: rowBox.height
                                    ColorImage {
                                        anchors.centerIn: parent
                                        source: "icons/circle-alert.svg"
                                        sourceSize: Qt.size(14, 14)
                                        color: Theme.warn
                                    }
                                    HoverHandler { id: alikeHover }
                                    ToolTip.visible: alikeHover.hovered
                                    ToolTip.delay: 200
                                    ToolTip.text: rowBox.alike + "\n声学追踪分不清声音相同的素材，可能停在另一个上"
                                }
                            }
                            // On a track already: which picture it is in.
                            Text {
                                id: tag
                                anchors.right: parent.right
                                anchors.rightMargin: 6
                                anchors.verticalCenter: parent.verticalCenter
                                visible: rowBox.tracks.length > 0
                                width: visible ? implicitWidth : 0
                                text: rowBox.tracks.map(t => "画面 " + (t + 1)).join(" · ")
                                font.pixelSize: 10
                                font.weight: Font.DemiBold
                                color: Theme.muted
                            }
                            MouseArea {
                                id: area
                                anchors.fill: parent
                                hoverEnabled: true
                                preventStealing: true
                                cursorShape: Qt.PointingHandCursor
                                property point from
                                property bool dragging: false
                                onPressed: mouse => {
                                    from = Qt.point(mouse.x, mouse.y)
                                    dragging = false
                                }
                                onPositionChanged: mouse => {
                                    if (!pressed || dragging || Math.hypot(mouse.x - from.x, mouse.y - from.y) < 6)
                                        return
                                    dragging = true
                                    lib.beginDrag(rowBox.url, mapToItem(null, mouse.x, mouse.y))
                                }
                                onClicked: mouse => {
                                    if (dragging)
                                        return
                                    lib.choose(rowBox.url, files, entry.index, mouse.modifiers)
                                }
                                onDoubleClicked: lib.use(rowBox.url)
                                ToolTip.visible: containsMouse && !pressed
                                ToolTip.delay: 900
                                ToolTip.text: rowBox.video ? "拖到画面 1 或画面 2：左半边替换，右半边追加 · 双击放到空的画面"
                                                           : "拖到上面的预备，或直接拖进画面贴出 · 双击放进预备"
                            }
                        }
                    }
                }
            }
        }
    }
}
