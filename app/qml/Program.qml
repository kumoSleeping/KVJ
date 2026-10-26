import QtQuick
import KVJ

// What is on the air (Switcher.program), over this item's whole extent, and,
// while a dissolve lasts (Switcher.transition), the layout before it on top
// of it, fading out by the clock. Both are drawn live. The end is a matter of
// time alone: past born + ms the old layout is no longer drawn, in every
// window at once, whoever clears the transition and when.
//
// `now`: Date.now() milliseconds, driven by the host (Stage's clock, which
// runs while Switcher.fading).
Item {
    id: program

    property real now: Date.now()
    property SourceTextures textures: null
    property var sourceItem: null
    property bool operator: false

    readonly property var transition: Switcher.transition
    readonly property bool fading: !!transition && now < transition.born + transition.ms
    readonly property real progress: !transition ? 1
                                     : Math.max(0, Math.min(1, (now - transition.born) / Math.max(1, transition.ms)))

    readonly property SourceTextures feed: textures || own
    SourceTextures {
        id: own
        sourceItem: program.textures ? null : program.sourceItem
        ids: program.textures ? [] : Switcher.sourcesOf(Switcher.program).concat(
                 program.transition ? Switcher.sourcesOf(program.transition.from) : [])
    }

    Compositor {
        anchors.fill: parent
        layout: Switcher.program
        textures: program.feed
        operator: program.operator
    }
    // The layout before, on black (so the dissolve is one picture into the
    // other, not through what either leaves open), as one layer fading out.
    Item {
        anchors.fill: parent
        visible: program.fading
        opacity: 1 - program.progress
        layer.enabled: visible
        Rectangle {
            anchors.fill: parent
            color: "black"
        }
        Compositor {
            anchors.fill: parent
            layout: program.fading ? program.transition.from : null
            textures: program.feed
            operator: program.operator
        }
    }
}
