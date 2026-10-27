import QtCore
import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Controls.impl
import QtQuick.Dialogs
import QtQuick.Layouts
import QtQuick.Window
import KVJ

// The output, without a monitor of its own (the board, Composer, shows what
// the audience sees): where the picture goes, how sharp, the key that projects
// it and the picture's sound, in a popover opened from the board's head
// (openOutput). It also keeps the window's light copy of every picture source
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
    // The picture's own sound (AudioFollower): whether it plays, on which output
    // (an id from its devices, empty for the system's default) and how loud.
    property var sound: null
    property bool soundOn: false
    property string soundDevice: ""
    property real soundVolume: 0.8

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

    function openOutput(item) {
        outputPop.parent = item
        outputPop.x = item.width - outputPop.width
        outputPop.y = item.height + 6
        outputPop.open()
    }
    readonly property bool outputOpen: outputPop.visible

    // The output: which screen, how, the key that projects, and the picture's
    // sound. Lower quality is lighter on a machine that also runs the DJ
    // software. Set once before a show.
    Popup {
        id: outputPop
        width: 400
        padding: 14
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
            Rectangle {
                Layout.fillWidth: true
                implicitHeight: 1
                color: Theme.line
            }
            // The picture's sound, off by default (the room hears the DJ), on an
            // output of its own: headphones to listen in, or the speakers. Where
            // and how loud can be set before it is turned on.
            RowLayout {
                Layout.fillWidth: true
                spacing: 8
                Toggle {
                    text: "画面声音"
                    checked: desk.soundOn
                    onToggled: desk.soundOn = checked
                }
                Select {
                    id: outputBox
                    readonly property var outputs: desk.sound ? desk.sound.devices : []
                    Layout.fillWidth: true
                    Layout.minimumWidth: 90
                    model: ["系统默认输出"].concat(outputs.map(d => d.name))
                    currentIndex: outputs.findIndex(d => d.id === desk.soundDevice) + 1
                    onActivated: index => desk.soundDevice = index > 0 ? outputs[index - 1].id : ""
                }
            }
            RowLayout {
                Layout.fillWidth: true
                spacing: 8
                Caption { text: "音量" }
                Seek {
                    Layout.fillWidth: true
                    from: 0
                    to: 1
                    value: desk.soundVolume
                    onMoved: desk.soundVolume = value
                }
                Text {
                    Layout.preferredWidth: 34
                    horizontalAlignment: Text.AlignRight
                    text: Math.round(desk.soundVolume * 100) + "%"
                    font.pixelSize: Theme.sizeSm
                    font.features: { "tnum": 1 }
                    color: Theme.body
                }
            }
            Text {
                Layout.fillWidth: true
                visible: desk.soundOn && !!desk.sound && desk.sound.error.length > 0
                text: desk.sound ? desk.sound.error : ""
                font.pixelSize: Theme.sizeXs
                color: Theme.warn
                elide: Text.ElideRight
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
}
