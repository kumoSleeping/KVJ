import QtQuick

// The picture sources of one window as textures, each source drawn into one
// once however many slots, monitors or layers of a dissolve show it. Place one
// anywhere in the window (it takes no room) and give it to every Compositor
// and Program there; the source items themselves are hidden (they are drawn
// only through these).
//
//   sourceItem: function (id) → the Item that shows that source, or null
//   ids:        the source ids wanted (Switcher.sourcesOf(layout), joined)
//
// A source that draws its picture fitted inside its own box (VideoSurface,
// CameraSurface, PreviewSurface) gives the picture's shape through
// `sourceSize` (or its `source`'s): only the picture is taken, without the
// bands around it. Anything else is taken whole.
Item {
    id: textures

    property var sourceItem: null
    property var ids: []
    // Bump when sourceItem would now answer differently for the same ids.
    property int revision: 0
    function refresh() {
        revision += 1
    }

    // id → its ShaderEffectSource, or null (also while the source has no item).
    property var map: ({})
    function texture(id) {
        const t = map[id]
        return t && t.sourceItem ? t : null
    }
    // The picture's width / height (1.778 until it is known).
    function aspect(id) {
        const t = map[id]
        return t ? t.ratio : 16 / 9
    }
    // The Item behind a source, or null.
    function item(id) {
        const t = map[id]
        return t ? t.sourceItem : null
    }
    // A source's own picture size, or null when it has none to tell.
    function contentSize(item) {
        if (!item)
            return null
        const own = item.sourceSize
        if (own && own.width > 0 && own.height > 0)
            return own
        const from = item.source
        const theirs = from && typeof from === "object" ? from.sourceSize : null
        if (theirs && theirs.width > 0 && theirs.height > 0)
            return theirs
        return null
    }

    // Kept as a list model changed in place, so a source added or dropped
    // does not make the others' textures anew.
    ListModel { id: wanted }
    function sync() {
        const want = (ids || []).filter((id, i, all) => typeof id === "string" && id && all.indexOf(id) === i)
        for (let i = wanted.count - 1; i >= 0; --i)
            if (want.indexOf(wanted.get(i).key) < 0)
                wanted.remove(i)
        for (const id of want) {
            let found = false
            for (let i = 0; i < wanted.count && !found; ++i)
                found = wanted.get(i).key === id
            if (!found)
                wanted.append({ key: id })
        }
    }
    onIdsChanged: sync()
    Component.onCompleted: sync()

    width: 0
    height: 0
    Repeater {
        model: wanted
        onItemAdded: (index, item) => {
            const next = Object.assign({}, textures.map)
            next[item.key] = item
            textures.map = next
        }
        onItemRemoved: (index, item) => {
            if (textures.map[item.key] !== item)
                return
            const next = Object.assign({}, textures.map)
            delete next[item.key]
            textures.map = next
        }
        ShaderEffectSource {
            required property string key
            readonly property size content: {
                const s = textures.contentSize(sourceItem)
                return s ? Qt.size(s.width, s.height) : Qt.size(0, 0)
            }
            readonly property real boxW: sourceItem ? sourceItem.width : 0
            readonly property real boxH: sourceItem ? sourceItem.height : 0
            readonly property real ratio: content.width > 0 ? content.width / content.height
                                          : boxW > 0 && boxH > 0 ? boxW / boxH : 16 / 9
            sourceItem: {
                textures.revision
                const found = textures.sourceItem ? textures.sourceItem(key) : null
                return found || null
            }
            // The picture inside its box, fitted and centred as it is drawn.
            sourceRect: {
                if (!(content.width > 0) || !(boxW > 0) || !(boxH > 0))
                    return Qt.rect(0, 0, 0, 0)
                const w = Math.min(boxW, boxH * ratio)
                const h = w / ratio
                return Qt.rect((boxW - w) / 2, (boxH - h) / 2, w, h)
            }
            hideSource: true
            visible: false
            width: 0
            height: 0
        }
    }
}
