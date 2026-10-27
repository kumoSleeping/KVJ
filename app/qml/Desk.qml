import QtCore
import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Controls.impl
import QtQuick.Dialogs
import QtQuick.Layouts
import QtQuick.Window
import KVJ

// The program monitor (PGM), in the main window: what the audience sees, edge
// to edge, the effects and the stickers on the air included. Under it, the
// output in one row (where the picture goes, the key that projects it, and the
// picture's sound in a popover). It also keeps the window's light copy of
// every picture source and their textures, for the monitors here.
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
    // The monitor as tall as the picture's shape at this width (less when the
    // column is short), and the output under it.
    implicitHeight: monitor.implicitHeight + Theme.gap + outputCard.implicitHeight

    ColumnLayout {
        anchors.fill: parent
        spacing: Theme.gap

        Item {
            id: monitor
            Layout.fillWidth: true
            Layout.fillHeight: true
            implicitHeight: width / Math.max(0.2, desk.aspect)
            Layout.maximumHeight: implicitHeight

            Rectangle {
                id: screen
                // Edge to edge: no stage round it here; that is the preview's.
                width: Math.min(monitor.width, monitor.height * desk.aspect)
                height: width / Math.max(0.2, desk.aspect)
                anchors.centerIn: parent
                color: "black"
                radius: Theme.radiusLg
                clip: true
                // Each source's light copy, under the picture (z below the
                // screen's own black) and as large as it: the monitors here
                // draw them through `textures`, never these items themselves.
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
                        z: -1
                        width: screen.width
                        height: screen.height
                        // Sharp enough for the monitors, which show it at most this large.
                        rows: 540
                        fps: 24
                        source: {
                            desk.projection ? desk.projection.sourceRevision : 0
                            return desk.projection ? desk.projection.sourceItem(key) : null
                        }
                    }
                }
                Stage {
                    id: deskStage
                    anchors.fill: parent
                    lite: true
                    entry: desk.entry
                    // What is on the air, as the projection composes it.
                    Program {
                        anchors.fill: parent
                        now: deskStage.now
                        textures: textures
                        operator: true
                    }
                }
                Text {
                    anchors.centerIn: parent
                    visible: !desk.entry
                    text: "观众看到的画面在这里"
                    font.pixelSize: Theme.sizeSm
                    color: Theme.faint
                }
                // Whose it is, at the top right, out of the way of the drawer's key.
                Rectangle {
                    anchors.top: parent.top
                    anchors.right: parent.right
                    anchors.margins: 8
                    width: pgm.implicitWidth + 12
                    height: 18
                    radius: 5
                    color: desk.projection && desk.projection.visible ? Theme.danger : "#8c000000"
                    Text {
                        id: pgm
                        anchors.centerIn: parent
                        text: desk.projection && desk.projection.visible ? "PGM · 投屏中" : "PGM"
                        font.pixelSize: 10
                        font.weight: Font.DemiBold
                        color: "white"
                    }
                }
            }
        }

        Card {
            id: outputCard
            Layout.fillWidth: true
            implicitHeight: controls.implicitHeight + 20
            ColumnLayout {
                id: controls
                anchors.fill: parent
                anchors.margins: 10
                anchors.leftMargin: Theme.gap
                anchors.rightMargin: Theme.gap
                spacing: 8

                // The output: which screen, how, and the key that projects. Lower
                // quality is lighter on a machine that also runs the DJ software.
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8
                    Select {
                        id: screenBox
                        Layout.fillWidth: true
                        Layout.preferredWidth: 160
                        Layout.minimumWidth: 70
                        model: Qt.application.screens.map((s, i) => (s.name || ("屏幕 " + (i + 1))) + " · " + s.width + "×" + s.height)
                        currentIndex: Qt.application.screens.length > 1 ? 1 : 0
                    }
                    Select {
                        id: heightBox
                        Layout.fillWidth: true
                        Layout.preferredWidth: 92
                        Layout.maximumWidth: 110
                        Layout.minimumWidth: 84
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
                        Layout.preferredWidth: 92
                        Layout.maximumWidth: 110
                        Layout.minimumWidth: 84
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
                    TextButton {
                        primary: true
                        iconName: desk.projection && desk.projection.visible ? "square" : "monitor"
                        text: desk.projection && desk.projection.visible ? "收起投屏" : "打开投屏"
                        onClicked: desk.projection.visible ? desk.projection.closeOutput()
                                                           : desk.projection.openOn(screenBox.currentIndex, fullscreen.checked)
                    }
                    // The picture's sound, in a popover: it is set once before a show.
                    TextButton {
                        id: soundKey
                        outlined: true
                        iconName: desk.soundOn ? "volume-2" : "volume-x"
                        text: desk.soundOn ? Math.round(desk.soundVolume * 100) + "%" : "关"
                        leftPadding: 8
                        rightPadding: 10
                        ToolTip.visible: hovered && !soundPop.visible
                        ToolTip.delay: 600
                        ToolTip.text: "播放画面本身的声音：开关、输出设备、音量"
                        onClicked: soundPop.visible ? soundPop.close() : soundPop.open()
                        Rectangle {
                            visible: desk.soundOn && !!desk.sound && desk.sound.error.length > 0
                            x: parent.width - 9
                            y: 3
                            width: 7
                            height: 7
                            radius: 3.5
                            color: Theme.warn
                        }
                        Popup {
                            id: soundPop
                            x: soundKey.width - width
                            y: -height - 6
                            width: 380
                            padding: 12
                            background: Rectangle {
                                radius: Theme.radiusLg
                                color: Theme.raised
                                border.width: 1
                                border.color: Theme.line
                            }
                            contentItem: ColumnLayout {
                                spacing: 8
                                // The picture's sound, off by default (the room hears the DJ), on an
                                // output of its own: headphones to listen in, or the speakers. Where
                                // and how loud can be set before it is turned on.
                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: 8
                                    Toggle {
                                        text: "播放声音"
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
                                    Seek {
                                        Layout.preferredWidth: 96
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
                            }
                        }
                    }
                }


            }
        }
    }
}
