import QtCore
import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Controls.impl
import QtQuick.Dialogs
import QtQuick.Layouts
import QtQuick.Window
import KVJ

// The output, without a monitor of its own: where the picture goes, how sharp
// and the key that projects it, in a popover opened from the board's head
// (openOutput), and the picture's sound in another (openSound). It also keeps the window's light copy of every picture source
// and their textures, for the board and the timeline. It takes no room: place
// it anywhere in the window.
Item {
    id: desk

    // The projected surface the preview copies its picture from.
    property VideoSurface source
    // The picture sources the operator sees here (the 画面 column's), besides
    // those the layouts use.
    property var sourceIds: []
    readonly property var allIds: {
        const ids = sourceIds.slice()
        const add = list => list.forEach(id => { if (ids.indexOf(id) < 0) ids.push(id) })
        add(Switcher.sourcesOf(Switcher.program))
        add(Switcher.sourcesOf(Switcher.preview))
        if (Switcher.transition)
            add(Switcher.sourcesOf(Switcher.transition.from))
        return ids
    }
    // This window's light copy of a source (a PreviewSurface), or null.
    function previewItem(id) {
        for (let i = 0; i < bank.count; ++i) {
            const item = bank.itemAt(i)
            if (item && item.key === id)
                return item
        }
        return null
    }
    // Every source of this window as a texture, for the monitors and tiles.
    readonly property alias textures: textures
    SourceTextures {
        id: textures
        sourceItem: desk.previewItem
        ids: desk.allIds
    }
    property var entry: null
    // The projection window the output keys open and put away.
    property var projection: null
    // The output's quality: frames at most this tall (0 = source) and this many
    // a second (0 = the material's own). The first choice of each is the one
    // recommended for the chosen screen and the video now on it.
    readonly property int maxHeight: heightBox.currentIndex > 0 ? [480, 720, 1080, 0][heightBox.currentIndex - 1] ?? 720 : recommendedHeight
    readonly property int maxFps: fpsBox.currentIndex > 0 ? [24, 30, 60, 0][fpsBox.currentIndex - 1] ?? 30 : recommendedFps
    readonly property var targetScreen: Qt.application.screens[Math.min(screenBox.currentIndex, Qt.application.screens.length - 1)] || null
    // Pixel rows the output shows: the whole screen, or a window 960 wide.
    readonly property int screenRows: targetScreen ? Math.round(targetScreen.height * targetScreen.devicePixelRatio) : 1080
    readonly property int outputRows: fullscreen.checked ? screenRows
                                      : Math.min(screenRows, Math.round(540 * (targetScreen ? targetScreen.devicePixelRatio : 1)))
    readonly property size videoSize: source ? source.sourceSize : Qt.size(0, 0)
    readonly property real videoFps: source ? source.sourceFps : 0
    // As sharp as the screen shows and the video holds, no sharper: the lighter
    // the better on a computer that also runs the DJ software.
    readonly property int recommendedHeight: {
        const need = videoSize.height > 0 ? Math.min(outputRows, videoSize.height) : outputRows
        return need <= 500 ? 480 : need <= 760 ? 720 : need <= 1600 ? 1080 : 0
    }
    // Every frame the video has, up to 60.
    readonly property int recommendedFps: videoFps <= 0 ? 30 : videoFps <= 24.5 ? 24 : videoFps <= 30.5 ? 30 : 60
    function heightText(h) {
        return h > 0 ? h + "p" : "原始"
    }
    // The tracks' own sound (an AudioFollower each): whether each plays and
    // how loud, on one output (an id from their devices, empty for the
    // system's default). Both on, the same videos make a cue mix.
    property var sound: null
    property var sound2: null
    property bool soundOn: false
    property bool soundOn2: false
    readonly property bool anySound: soundOn || soundOn2
    property string soundDevice: ""
    property real soundVolume: 0.8
    property real soundVolume2: 0.8
    readonly property string soundError: soundOn && sound && sound.error ? sound.error
                                       : soundOn2 && sound2 && sound2.error ? sound2.error : ""

    // The picture's shape, the projection's (Projection.aspect): the monitors,
    // the stickers and the danmaku lanes all take it.
    readonly property real aspect: projection ? projection.aspect : 16 / 9

    Settings {
        category: "output"
        property alias quality: heightBox.currentIndex
        property alias frames: fpsBox.currentIndex
        property alias fullscreen: fullscreen.checked
        property alias sound: desk.soundOn
        property alias soundDevice: desk.soundDevice
        property alias soundVolume: desk.soundVolume
        property alias sound2: desk.soundOn2
        property alias soundVolume2: desk.soundVolume2
    }
    // The shape the projection will have before it opens: the chosen screen's
    // when it fills it, else its 16:9 window.
    Binding {
        target: desk.projection
        property: "fullscreenNext"
        value: fullscreen.checked
    }
    Binding {
        target: desk.projection
        property: "screenNext"
        value: desk.targetScreen
    }
    Binding {
        target: Live
        property: "aspect"
        value: desk.aspect
    }
    // How large the light copies are drawn: as large as the board shows a
    // source at most (`monitorWidth`, the board's picture).
    property real monitorWidth: 640
    readonly property real bankWidth: Math.max(320, monitorWidth)
    width: 0
    height: 0

    // Each source's light copy, never seen itself: the board and the tiles
    // draw them through `textures`.
    IdList {
        id: bankIds
        ids: desk.allIds
    }
    Repeater {
        id: bank
        model: bankIds.model
        onItemAdded: textures.refresh()
        onItemRemoved: textures.refresh()
        PreviewSurface {
            required property string key
            width: desk.bankWidth
            height: desk.bankWidth / Math.max(0.2, desk.aspect)
            // Sharp enough for the board, which shows it at most this large.
            rows: 540
            fps: 24
            source: {
                desk.projection ? desk.projection.sourceRevision : 0
                return desk.projection ? desk.projection.sourceItem(key) : null
            }
        }
    }

    // A second press on the key that opened it puts it away (a press on
    // the key does not count as outside it).
    function openOutput(item) {
        if (outputPop.visible && outputPop.parent === item) {
            outputPop.close()
            return
        }
        outputPop.parent = item
        outputPop.x = item.width - outputPop.width
        outputPop.y = item.height + 6
        outputPop.open()
    }
    readonly property bool outputOpen: outputPop.visible

    // The output: which screen, how, and the key that projects. Lower quality is lighter on a machine that also runs the DJ
    // software. Set once before a show.
    Popup {
        id: outputPop
        width: 400
        padding: 14
        margins: 8
        closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutsideParent
        background: Rectangle {
            radius: Theme.radiusLg
            color: Theme.raised
            border.width: 1
            border.color: Theme.line
        }
        contentItem: ColumnLayout {
            spacing: 10
            Caption { text: "投到哪个屏幕" }
            Select {
                id: screenBox
                Layout.fillWidth: true
                model: Qt.application.screens.map((s, i) => (s.name || ("屏幕 " + (i + 1))) + " · " + s.width + "×" + s.height)
                currentIndex: Qt.application.screens.length > 1 ? 1 : 0
            }
            RowLayout {
                Layout.fillWidth: true
                spacing: 8
                Select {
                    id: heightBox
                    Layout.fillWidth: true
                    model: ["推荐", "480p", "720p", "1080p", "原始"]
                    currentIndex: 0
                    displayText: currentIndex === 0 ? desk.heightText(desk.recommendedHeight) : currentText
                    ToolTip.visible: hovered && !popup.visible
                    ToolTip.delay: 600
                    ToolTip.text: "推荐：投放画面 " + desk.outputRows + " 行" + (fullscreen.checked ? "（全屏）" : "（窗口）")
                                  + (desk.videoSize.height > 0 ? "，视频 " + desk.videoSize.width + "×" + desk.videoSize.height : "")
                                  + " → " + desk.heightText(desk.recommendedHeight)
                }
                Select {
                    id: fpsBox
                    Layout.fillWidth: true
                    model: ["推荐", "24 帧", "30 帧", "60 帧", "原帧率"]
                    currentIndex: 0
                    displayText: currentIndex === 0 ? desk.recommendedFps + " 帧" : currentText
                    ToolTip.visible: hovered && !popup.visible
                    ToolTip.delay: 600
                    ToolTip.text: "推荐：" + (desk.videoFps > 0 ? "视频 " + desk.videoFps.toFixed(2).replace(/\.?0+$/, "") + " 帧，" : "")
                                  + "每帧都放，最多 60 → " + desk.recommendedFps + " 帧"
                }
                Toggle {
                    id: fullscreen
                    text: "全屏"
                    checked: Qt.application.screens.length > 1
                }
            }
            TextButton {
                Layout.fillWidth: true
                primary: true
                iconName: desk.projection && desk.projection.visible ? "square" : "monitor"
                text: desk.projection && desk.projection.visible ? "收起投屏" : "打开投屏"
                onClicked: {
                    desk.projection.visible ? desk.projection.closeOutput()
                                            : desk.projection.openOn(screenBox.currentIndex, fullscreen.checked)
                    outputPop.close()
                }
            }
        }
    }

    // Under its key, the on/off switch first, right under the pointer
    // that opened it; a second press on the key puts it away.
    function openSound(item) {
        if (soundPop.visible && soundPop.parent === item) {
            soundPop.close()
            return
        }
        soundPop.parent = item
        soundPop.x = -4
        soundPop.y = item.height + 4
        soundPop.open()
    }
    readonly property bool soundOpen: soundPop.visible

    // The picture's own sound: on or off, where and how loud.
    Popup {
        id: soundPop
        width: 300
        padding: 12
        margins: 8
        closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutsideParent
        background: Rectangle {
            radius: Theme.radiusLg
            color: Theme.raised
            border.width: 1
            border.color: Theme.line
        }
        contentItem: ColumnLayout {
            spacing: 8
            // Each track's sound, off by default (the room hears the DJ), on
            // an output of its own: headphones to listen in, or the speakers.
            // Both on, they mix there (a cue mix of the same videos). How loud
            // and where can be set before it is turned on.
            Repeater {
                model: [{ name: "画面 1", on: desk.soundOn, volume: desk.soundVolume },
                        { name: "画面 2", on: desk.soundOn2, volume: desk.soundVolume2 }]
                RowLayout {
                    required property var modelData
                    required property int index
                    Layout.fillWidth: true
                    spacing: 8
                    Toggle {
                        text: parent.modelData.name
                        checked: parent.modelData.on
                        onToggled: parent.index === 0 ? desk.soundOn = checked : desk.soundOn2 = checked
                    }
                    Seek {
                        Layout.fillWidth: true
                        from: 0
                        to: 1
                        value: parent.modelData.volume
                        onMoved: parent.index === 0 ? desk.soundVolume = value : desk.soundVolume2 = value
                    }
                    Text {
                        Layout.preferredWidth: 34
                        horizontalAlignment: Text.AlignRight
                        text: Math.round(parent.modelData.volume * 100) + "%"
                        font.pixelSize: Theme.sizeSm
                        font.features: { "tnum": 1 }
                        color: parent.modelData.on ? Theme.body : Theme.faint
                    }
                }
            }
            Select {
                id: outputBox
                readonly property var outputs: desk.sound ? desk.sound.devices : []
                Layout.fillWidth: true
                model: ["系统默认输出"].concat(outputs.map(d => d.name))
                currentIndex: outputs.findIndex(d => d.id === desk.soundDevice) + 1
                onActivated: index => desk.soundDevice = index > 0 ? outputs[index - 1].id : ""
            }
            Text {
                Layout.fillWidth: true
                visible: desk.soundError.length > 0
                text: desk.soundError
                font.pixelSize: Theme.sizeXs
                color: Theme.warn
                elide: Text.ElideRight
            }
        }
    }
}
