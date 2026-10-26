import QtQuick
import QtQuick.Shapes
import KVJ

// A layout (Switcher.qml) drawn over this item's whole extent: each slot, in
// the order of its z, its source's picture fitted or cropped into it and cut
// to its mask (shaders/mask.frag). The same layout looks the same at any size.
//
// The pictures come from `textures` (a SourceTextures shared by everything in
// the window), or, without one, from `sourceItem` (id → Item) through a
// SourceTextures of its own.
//
// `operator`: a slot with no picture shows as a dark plate with its state, for
// the operator's monitors; the audience's never does.
Item {
    id: compositor

    property var layout: null
    property SourceTextures textures: null
    property var sourceItem: null
    property bool operator: false

    readonly property SourceTextures feed: textures || own
    SourceTextures {
        id: own
        sourceItem: compositor.textures ? null : compositor.sourceItem
        ids: compositor.textures ? [] : Switcher.sourcesOf(compositor.layout)
    }

    readonly property var slots: layout && layout.slots ? layout.slots : []
    // Slot indexes from the bottom up: by z, then by place in the list.
    readonly property var order: slots.map((s, i) => i).sort((a, b) => (slots[a].z - slots[b].z) || (a - b))
    readonly property bool shaders: GraphicsInfo.api !== GraphicsInfo.Software

    Repeater {
        // A count, so a slot moved or changed is changed in place.
        model: compositor.slots.length
        Item {
            id: cell
            required property int index
            readonly property int at: index < compositor.order.length ? compositor.order[index] : -1
            readonly property var slot: at >= 0 ? compositor.slots[at] : null
            readonly property var mask: slot ? slot.mask : null
            readonly property var tex: slot ? compositor.feed.texture(slot.source) : null
            readonly property Item origin: slot ? compositor.feed.item(slot.source) : null
            readonly property bool live: !!tex && !!origin && origin.hasFrame !== false
            readonly property real ratio: slot ? compositor.feed.aspect(slot.source) : 1
            readonly property real own: width / Math.max(1, height)
            readonly property bool cover: !!slot && slot.fit === "cover"
            readonly property real shortSide: Math.min(width, height)

            visible: !!slot
            x: slot ? slot.x * compositor.width : 0
            y: slot ? slot.y * compositor.height : 0
            width: slot ? slot.w * compositor.width : 0
            height: slot ? slot.h * compositor.height : 0
            z: index

            // The operator's plate where there is no picture yet.
            Rectangle {
                anchors.fill: parent
                visible: compositor.operator && !cell.live
                color: "#1d2129"
                radius: !cell.mask ? 0 : cell.mask.shape === "circle" ? cell.shortSide / 2
                      : cell.mask.shape === "round" ? Math.min(cell.mask.radius, 0.5) * cell.shortSide : 0
                Text {
                    anchors.centerIn: parent
                    width: parent.width - 8
                    horizontalAlignment: Text.AlignHCenter
                    elide: Text.ElideRight
                    text: !cell.slot || !cell.slot.source ? "未选画面" : cell.tex ? "无画面" : "无源"
                    font.pixelSize: Math.max(9, Math.min(13, cell.shortSide / 6))
                    color: "#6b7280"
                    visible: cell.shortSide > 24
                }
            }

            // A drawn curve's shape, rendered once into a texture the shader
            // reads.
            Loader {
                id: curve
                active: !!cell.mask && cell.mask.shape === "path" && cell.mask.points.length >= 3
                sourceComponent: Item {
                    readonly property alias texture: shot
                    width: cell.width
                    height: cell.height
                    Shape {
                        id: drawn
                        anchors.fill: parent
                        preferredRendererType: Shape.CurveRenderer
                        ShapePath {
                            fillColor: "white"
                            strokeWidth: -1
                            strokeColor: "transparent"
                            PathPolyline {
                                path: Switcher.curve(cell.mask.points, 12).map(p => Qt.point(p[0] * cell.width, p[1] * cell.height))
                            }
                        }
                    }
                    ShaderEffectSource {
                        id: shot
                        sourceItem: drawn
                        hideSource: true
                        visible: false
                        // Levels to blur from (mask.frag).
                        mipmap: true
                    }
                }
            }

            // The software renderer has no shaders: the picture without its
            // mask, fitted or cropped the same way, from a capture of its own.
            Loader {
                active: !compositor.shaders && cell.live
                sourceComponent: ShaderEffectSource {
                    readonly property Item from: cell.origin
                    // The picture inside its source's box, as SourceTextures takes it.
                    readonly property rect picture: cell.tex && cell.tex.sourceRect.width > 0 ? cell.tex.sourceRect
                                                    : Qt.rect(0, 0, from ? from.width : 0, from ? from.height : 0)
                    readonly property real across: cell.own / Math.max(0.0001, cell.ratio)
                    sourceItem: from
                    hideSource: true
                    sourceRect: {
                        if (!cell.cover)
                            return picture
                        const w = picture.width * Math.min(1, across)
                        const h = picture.height * Math.min(1, 1 / across)
                        return Qt.rect(picture.x + (picture.width - w) / 2, picture.y + (picture.height - h) / 2, w, h)
                    }
                    width: cell.cover ? cell.width : cell.width / Math.max(1, across)
                    height: cell.cover ? cell.height : cell.height / Math.max(1, 1 / across)
                    x: (cell.width - width) / 2
                    y: (cell.height - height) / 2
                }
            }

            ShaderEffect {
                anchors.fill: parent
                visible: compositor.shaders && !!cell.tex && width > 0 && height > 0
                fragmentShader: "qrc:/qt/qml/KVJ/shaders/mask.frag.qsb"
                property var source: cell.tex
                // Bound to something either way; read only for a curve.
                property var maskSource: curve.item ? curve.item.texture : cell.tex
                property real shape: !cell.mask ? 0 : cell.mask.shape === "path" ? (curve.item ? 3 : 0)
                                     : Switcher.shapes.indexOf(cell.mask.shape)
                property real radius: cell.mask ? cell.mask.radius : 0
                property real feather: cell.mask ? cell.mask.feather : 0
                property real aspect: cell.own
                // Filling the slot crops the picture's longer way; showing it
                // whole leaves bands (outside 0..1, drawn as nothing).
                property vector2d uvScale: {
                    const across = cell.own / Math.max(0.0001, cell.ratio)
                    return cell.cover ? Qt.vector2d(Math.min(1, across), Math.min(1, 1 / across))
                                      : Qt.vector2d(Math.max(1, across), Math.max(1, 1 / across))
                }
            }
        }
    }
}
