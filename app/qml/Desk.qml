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
    // The tracks' own sound (an AudioFollower each). `soundLive` is the
    // sound key: on or off. What on plays is set in the popover: the top
    // layer's track (顶层声音, the default), or 画面 1 and 画面 2 by their own
    // switches (both on, the same videos make a cue mix), each at its own
    // volume, on one output (an id from their devices, empty for the
    // system's default).
    property var sound: null
    property var sound2: null
    property bool soundLive: false
    property bool soundOn: false
    property bool soundOn2: false
    // 顶层声音: only the track whose layer is on top on the air is heard
    // (each its own volume); the switches of the tracks wait meanwhile.
    property bool soundTopOnly: true
    // The one track shown in 单轨 (-1 with both): only its sound is heard,
    // by its own switch and volume, so switching keeps the sound as it was.
    property int solo: -1
    // With nothing chosen, on still plays something: the top layer's.
    readonly property bool topOnly: soundTopOnly || (!soundOn && !soundOn2)
    // The source on top on the air (Timeline.onTop), set by the host.
    property string topSource: ""
    readonly property bool hears1: soundLive && solo !== 1 && (topOnly ? topSource === "track:0" : soundOn)
    readonly property bool hears2: soundLive && solo !== 0 && (topOnly ? topSource === "track:1" : soundOn2)
    readonly property bool anySound: soundLive && (topOnly || hears1 || hears2)
    property string soundDevice: ""
    property real soundVolume: 0.8
    property real soundVolume2: 0.8
    readonly property string soundError: hears1 && sound && sound.error ? sound.error
                                       : hears2 && sound2 && sound2.error ? sound2.error : ""

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
        // New keys: what on plays starts at 顶层声音 once on every computer,
        // whatever was kept before; the key itself starts as the sound was.
        property alias topSound: desk.soundTopOnly
        property alias soundLive: desk.soundLive
        property bool soundLiveKept: false
        // The old ones, read once to carry the sound on as it was.
        property bool soundTopOnly: false
        Component.onCompleted: {
            if (!soundLiveKept) {
                desk.soundLive = desk.soundOn || desk.soundOn2 || soundTopOnly
                soundLiveKept = true
            }
        }
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
                    ToolTip.text: "推荐：投屏画面 " + desk.outputRows + " 行" + (fullscreen.checked ? "（全屏）" : "（窗口）")
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

    // Under the sound key (opened by the small key beside it); a second
    // press puts it away.
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

    // What the sound key plays when on: the top layer's track or the tracks
    // chosen, how loud and where.
    Popup {
        id: soundPop
        width: 340
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
            Caption {
                Layout.fillWidth: true
                text: "开声音时播放"
            }
            Toggle {
                text: "顶层声音"
                checked: desk.soundTopOnly
                onToggled: desk.soundTopOnly = checked
                ToolTip.visible: hovered
                ToolTip.delay: 600
                ToolTip.text: "只听观众画面最上层那条轨道的声音，换到另一条在最上层时声音跟着换（各自的音量照旧）。关掉它再选画面 1、画面 2"
            }
            // Each track's sound, off by default (the room hears the DJ), on
            // an output of its own: headphones to listen in, or the speakers.
            // Both on, they mix there (a cue mix of the same videos). How loud
            // and where can be set before it is turned on.
            // By number, not by a list of values: a list made anew at each
            // step of a drag would make the slider anew under the finger.
            Repeater {
                model: desk.solo < 0 ? 2 : 1
                RowLayout {
                    id: soundRow
                    required property int index
                    // The track: both in turn, or the one shown.
                    readonly property int track: desk.solo < 0 ? index : desk.solo
                    readonly property bool on: track === 0 ? desk.soundOn : desk.soundOn2
                    readonly property real volume: track === 0 ? desk.soundVolume : desk.soundVolume2
                    function setVolume(v) {
                        v = Math.round(Math.max(0, Math.min(1, v)) * 100) / 100
                        if (track === 0)
                            desk.soundVolume = v
                        else
                            desk.soundVolume2 = v
                    }
                    Layout.fillWidth: true
                    spacing: 4
                    Toggle {
                        Layout.rightMargin: 4
                        enabled: !desk.soundTopOnly
                        text: "画面 " + (soundRow.track + 1)
                        checked: soundRow.on
                        onToggled: soundRow.track === 0 ? desk.soundOn = checked : desk.soundOn2 = checked
                    }
                    // 1 % a press (held, it goes on); the slider drags and,
                    // under the wheel, steps by 1 %.
                    IconButton {
                        implicitWidth: 22
                        implicitHeight: 22
                        iconSize: 12
                        iconName: "minus"
                        tip: "音量 −1%"
                        autoRepeat: true
                        onClicked: soundRow.setVolume(soundRow.volume - 0.01)
                    }
                    Seek {
                        Layout.fillWidth: true
                        from: 0
                        to: 1
                        stepSize: 0.01
                        wheelEnabled: true
                        value: soundRow.volume
                        onMoved: soundRow.setVolume(value)
                    }
                    IconButton {
                        implicitWidth: 22
                        implicitHeight: 22
                        iconSize: 12
                        iconName: "plus"
                        tip: "音量 +1%"
                        autoRepeat: true
                        onClicked: soundRow.setVolume(soundRow.volume + 0.01)
                    }
                    Text {
                        Layout.preferredWidth: 38
                        horizontalAlignment: Text.AlignRight
                        text: Math.round(soundRow.volume * 100) + "%"
                        font.pixelSize: Theme.sizeSm
                        font.features: { "tnum": 1 }
                        color: (desk.topOnly ? (soundRow.track === 0 ? desk.hears1 : desk.hears2) : soundRow.on) ? Theme.body : Theme.faint
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
