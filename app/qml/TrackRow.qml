import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Controls.impl
import QtQuick.Layouts
import KVJ

// One row of the timeline, as an editor's track: at its left the header (the
// source's own small picture, which a press puts in the preview's chosen
// slot; its name; an ear while following listens to it; ⋯), and across the
// rest the row's own play bar over its lane. The bar drives this track's
// player: play and pause, where it is, a seek track over the whole row
// (press or drag moves the picture there), the speed with − / + and 复原,
// and what happens after its last entry. Its keys rest while following
// leads that player. The lane lays the row's entries end to end (TrackPiece)
// with the row's playhead; on the main row a press only sets the cursor, on
// an aux row it moves that track's picture there at once, playing or paused
// as it was. A camera has no timeline: its lane just says it is live. Entries
// dragged from the drawer, or files from the desktop, can be dropped anywhere
// on a track's row; the row lights up while they hover.
//
//   view    the Timeline (the shared view, the main player's state)
//   spec    { key, kind, track, cameraId, name, entries, player }
//   layout  { clips, total }: the row's entries end to end, from the view
Item {
    id: row

    property var view: null
    property var spec: ({})
    property var layout: ({ clips: [], total: 0 })

    readonly property string key: spec.key || ""
    readonly property bool camera: spec.kind === "camera"
    readonly property int track: spec.track || 0
    readonly property bool main: !camera && track === 0
    readonly property var player: main ? view.player : spec.player || null
    readonly property string name: spec.name || (camera ? "相机" : "画面 " + (track + 1))
    readonly property var clips: layout.clips || []
    readonly property real total: layout.total || 0
    readonly property var entries: spec.entries || []
    readonly property string emptyText: entries.length ? "素材都关着 · 把素材拖到这里" : "把素材拖到这里"

    // What the row's player shows, where, how fast. The main row's comes from
    // the view, which knows whether this Set is parked and who leads.
    readonly property string playingId: main ? view.playingId : player && player.entry ? player.entry.id : ""
    readonly property real position: main ? view.position : player ? player.playhead : 0
    readonly property var playClip: main ? view.playClip : clips.find(c => c.entry.id === playingId) || null
    readonly property real playT: main ? view.playT : playClip ? playClip.start + Math.min(position, playClip.length) : -1
    readonly property var shown: main ? view.shown : player ? player.entry : null
    // The keys a hand may use: none of them while following leads the player.
    readonly property bool canSeek: main ? view.manualSeek : !!player && !player.lead
    readonly property bool canTempo: main ? view.manualTempo : !!player && !player.lead
    readonly property bool playing: main ? !view.parked && (!!view.match || (!!view.transport && view.transport.playing))
                                         : !!player && player.playing
    readonly property bool canPlay: main ? view.manualSeek && (view.parked ? !!view.shown : !!view.transport && !!view.transport.entry)
                                         : canSeek && clips.length > 0
    // The speed played (the main one bent while a nudge key is held), and the setting it comes back to.
    readonly property real speed: main ? view.speed : player ? player.effectiveSpeed : 1
    readonly property real setting: main ? view.tempo : player ? player.speed : 1
    readonly property real minSpeed: main ? (view.transport ? view.transport.minTempo : 0.5) : player ? player.minSpeed : 0.5
    readonly property real maxSpeed: main ? (view.transport ? view.transport.maxTempo : 1.5) : player ? player.maxSpeed : 1.5
    readonly property bool bending: main && view.bending !== 0
    readonly property bool loop: main ? !!view.player && view.player.loopOn : !!player && player.loop
    readonly property bool followed: !camera && view.followTrack === track
    readonly property bool onAir: view.onAir.indexOf(key) >= 0
    readonly property bool inPreview: view.inPreview.indexOf(key) >= 0
    readonly property var texture: {
        view.textures ? view.textures.revision : 0
        view.textures ? view.textures.map : null
        return view.textures && key ? view.textures.texture(key) : null
    }
    readonly property real ratio: view.textures && key ? view.textures.aspect(key) : 16 / 9

    readonly property int barHeight: 24

    function togglePlay() {
        if (main)
            view.parked ? view.player.play(view.shown, 0) : view.player.toggle()
        else if (player)
            player.toggle()
    }
    // The picture to `t` seconds along the row: the main track as a jump does
    // (another entry starts playing, within the one shown it stays as it
    // was), an aux track playing or paused as it was.
    function seekTo(t) {
        if (!canSeek || !clips.length)
            return
        t = Math.max(0, Math.min(total - 0.001, t))
        for (const c of clips) {
            if (t < c.start + c.length) {
                const at = Math.max(0, Math.min(c.entry.duration, t - c.start))
                if (main)
                    view.player.play(c.entry, at)
                else
                    player.seek(c.entry, at)
                break
            }
        }
    }
    function nudgeSpeed(step) {
        if (!canTempo)
            return
        if (main)
            view.player.nudgeTempo(step)
        else
            player.setSpeed(player.speed + step)
    }
    function setSpeedTo(value) {
        if (!canTempo)
            return
        if (main)
            view.transport.setTempo(value)
        else
            player.setSpeed(value)
    }
    function resetSpeed() {
        if (!canTempo)
            return
        if (main)
            view.player.resetTempo()
        else
            player.setSpeed(1)
    }
    function flipLoop() {
        if (main)
            view.player.loopOn = !view.player.loopOn
        else if (player)
            player.loop = !player.loop
    }

    // —— The header ——
    Item {
        id: header
        width: row.view.headerWidth - 8
        height: row.height

        RowLayout {
            id: title
            width: parent.width
            height: row.barHeight
            spacing: 4
            ColorImage {
                visible: row.followed
                source: "icons/ear.svg"
                sourceSize: Qt.size(13, 13)
                color: Theme.text
                HoverHandler { id: earHover }
                ToolTip.visible: earHover.hovered
                ToolTip.delay: 500
                ToolTip.text: "音频对位跟随这条轨道"
            }
            Text {
                Layout.fillWidth: true
                text: row.name
                font.pixelSize: Theme.sizeSm
                font.weight: Font.DemiBold
                color: row.camera || row.clips.length ? Theme.text : Theme.muted
                elide: Text.ElideRight
            }
            IconButton {
                id: moreKey
                visible: !row.main
                implicitWidth: 22
                implicitHeight: 22
                iconSize: 13
                iconName: "ellipsis"
                tip: row.camera ? "这个相机" : "这条轨道"
                active: trackMenu.visible || cameraMenu.visible
                onClicked: (row.camera ? cameraMenu : trackMenu).popup(moreKey, 0, moreKey.height + 2)
            }
        }
        PopMenu {
            id: trackMenu
            PopAction {
                enabled: !!row.player
                text: row.player && row.player.followMain ? "不再跟随主轨速度" : "跟随主轨速度"
                onTriggered: row.player.followMain = !row.player.followMain
            }
            MenuSeparator {}
            PopAction {
                // A track with entries is emptied first, by moving them on.
                enabled: row.entries.length === 0
                text: row.entries.length === 0 ? "移除轨道" : "移除轨道（先把素材移走）"
                risky: row.onAir
                onTriggered: row.view.removeRow(row.key)
            }
        }
        PopMenu {
            id: cameraMenu
            PopAction {
                text: "移除轨道"
                risky: row.onAir
                onTriggered: row.view.removeRow(row.key)
            }
        }

        // The source's own picture, fitted; on the air an ink edge, in the preview a faint one.
        Rectangle {
            id: picture
            readonly property real room: row.height - row.barHeight - 4
            y: row.barHeight + 2
            width: Math.min(parent.width, room * 16 / 9)
            height: Math.min(room, width * 9 / 16)
            radius: Theme.radius
            color: "black"
            ShaderEffect {
                readonly property real fit: Math.min(parent.width / Math.max(0.01, row.ratio), parent.height)
                width: fit * row.ratio
                height: fit
                anchors.centerIn: parent
                visible: !!row.texture
                property var source: row.texture
            }
            Text {
                anchors.centerIn: parent
                visible: !row.texture
                text: "无画面"
                font.pixelSize: Theme.sizeXs
                color: "#80ffffff"
            }
            Rectangle {
                anchors.fill: parent
                radius: parent.radius
                color: "transparent"
                border.width: row.onAir ? 2 : row.inPreview ? 1.5 : 0
                border.color: row.onAir ? Theme.text : Theme.muted
            }
            Rectangle {
                visible: row.onAir || row.inPreview
                x: 4
                y: parent.height - height - 4
                width: tag.implicitWidth + 8
                height: 15
                radius: 3
                color: row.onAir ? Theme.text : "#99000000"
                Text {
                    id: tag
                    anchors.centerIn: parent
                    text: row.onAir ? "PGM" : "PVW"
                    font.pixelSize: 9
                    font.weight: Font.DemiBold
                    color: row.onAir ? Theme.bg : "white"
                }
            }
            MouseArea {
                id: pictureArea
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: row.view.pickSource(row.key)
                ToolTip.visible: containsMouse
                ToolTip.delay: 700
                ToolTip.text: "放进合成预览（PVW）选中的位置"
            }
        }
    }

    // —— The play bar and the lane ——
    Item {
        id: body
        x: row.view.headerWidth
        width: row.width - x
        height: row.height

        // A camera: live, without a timeline.
        Rectangle {
            visible: row.camera
            anchors.fill: parent
            radius: Theme.radius
            color: Theme.inset
            Row {
                anchors.centerIn: parent
                spacing: 8
                Rectangle {
                    anchors.verticalCenter: parent.verticalCenter
                    width: 7
                    height: 7
                    radius: 3.5
                    color: row.texture ? Theme.text : Theme.faint
                }
                Text {
                    text: row.texture ? "实时画面" : "实时画面 · 相机没有画面"
                    font.pixelSize: Theme.sizeSm
                    color: Theme.muted
                }
            }
        }

        RowLayout {
            id: bar
            visible: !row.camera
            width: parent.width
            height: row.barHeight
            spacing: 2

            IconButton {
                implicitWidth: 22
                implicitHeight: 22
                iconSize: 12
                iconName: row.playing ? "pause" : "play"
                active: row.playing
                enabled: row.canPlay
                tip: row.main && row.view.parked ? "从这个 Set 的开头播放（画面切过来）"
                     : (row.playing ? "暂停" : "播放") + row.name
                onClicked: row.togglePlay()
            }
            Text {
                Layout.preferredWidth: 112
                text: row.playClip ? (row.clips.length > 1 ? row.playClip.n + " · " : "")
                                     + row.view.clock(row.position, true) + " / " + row.view.clock(row.playClip.entry.duration, false)
                      : row.clips.length ? "—" : ""
                font.pixelSize: Theme.sizeXs
                font.features: { "tnum": 1 }
                color: row.canSeek ? Theme.body : Theme.muted
                elide: Text.ElideRight
            }

            // The row's whole timeline at a glance: where its picture is, a
            // notch where one entry meets the next and, on the main row, the
            // cursor as a hollow ball. A press or drag moves the picture.
            Item {
                id: seek
                Layout.fillWidth: true
                Layout.minimumWidth: 60
                Layout.preferredHeight: row.barHeight
                readonly property real share: row.total > 0 && row.playT >= 0 ? Math.max(0, Math.min(1, row.playT / row.total)) : 0
                function timeAt(x) {
                    return Math.max(0, Math.min(1, x / width)) * row.total
                }
                Rectangle {
                    id: groove
                    anchors.verticalCenter: parent.verticalCenter
                    width: parent.width
                    height: 4
                    radius: 2
                    color: Theme.line
                    Rectangle {
                        width: parent.width * seek.share
                        height: parent.height
                        radius: 2
                        color: row.canSeek ? Theme.text : Theme.muted
                    }
                    Repeater {
                        model: row.clips.filter(c => c.start > 0)
                        Rectangle {
                            required property var modelData
                            x: groove.width * modelData.start / Math.max(1, row.total) - 1
                            width: 2
                            height: groove.height
                            color: Theme.raised
                        }
                    }
                }
                Rectangle {
                    visible: row.main && row.view.markT >= 0 && row.total > 0
                    x: seek.width * row.view.markT / Math.max(1, row.total) - width / 2
                    anchors.verticalCenter: parent.verticalCenter
                    width: 9
                    height: 9
                    radius: 4.5
                    color: Theme.raised
                    border.width: 2
                    border.color: Theme.muted
                }
                Rectangle {
                    visible: row.playT >= 0
                    x: seek.width * seek.share - width / 2
                    anchors.verticalCenter: parent.verticalCenter
                    width: 11
                    height: 11
                    radius: 5.5
                    color: row.canSeek && !(row.main && row.view.parked) ? Theme.text : Theme.muted
                    scale: seekArea.pressed ? 1.15 : 1
                }
                // Where a press would take the picture.
                Rectangle {
                    visible: seekArea.containsMouse && !seekArea.pressed && seekArea.enabled
                    x: seekArea.mouseX - width / 2
                    anchors.verticalCenter: parent.verticalCenter
                    width: 11
                    height: 11
                    radius: 5.5
                    color: "transparent"
                    border.width: 1.5
                    border.color: Theme.faint
                }
                MouseArea {
                    id: seekArea
                    anchors.fill: parent
                    enabled: row.canSeek && row.clips.length > 0
                    hoverEnabled: true
                    preventStealing: true
                    cursorShape: Qt.PointingHandCursor
                    onPressed: mouse => row.seekTo(seek.timeAt(mouse.x))
                    onPositionChanged: mouse => {
                        if (pressed)
                            row.seekTo(seek.timeAt(mouse.x))
                    }
                    onWheel: wheel => row.view.scroll(wheel, row.view.laneWidth / 2)
                    ToolTip.visible: containsMouse && !pressed
                    ToolTip.delay: 900
                    ToolTip.text: row.main ? (row.view.parked ? "按下或拖动：画面跳到这里（切到这个 Set）" : "按下或拖动：画面跳到这里")
                                           : "按下或拖动：这条轨道的画面到这里，播放或暂停照旧"
                }
            }

            Item { Layout.preferredWidth: 6 }
            // The speed: a percent a key, the bar, 复原 (or a double-click on the readout).
            IconButton {
                implicitWidth: 22
                implicitHeight: 22
                iconSize: 12
                iconName: "minus"
                tip: "慢 1%"
                autoRepeat: true
                enabled: row.canTempo && row.setting > row.minSpeed + 1e-6
                onClicked: row.nudgeSpeed(-0.01)
            }
            Seek {
                Layout.preferredWidth: 72
                Layout.minimumWidth: 40
                implicitHeight: 22
                from: (row.minSpeed - 1) * 100
                to: (row.maxSpeed - 1) * 100
                value: (row.setting - 1) * 100
                enabled: row.canTempo
                onMoved: row.setSpeedTo(1 + value / 100)
                TapHandler {
                    enabled: row.canTempo
                    onDoubleTapped: row.resetSpeed()
                }
            }
            IconButton {
                implicitWidth: 22
                implicitHeight: 22
                iconSize: 12
                iconName: "plus"
                tip: "快 1%"
                autoRepeat: true
                enabled: row.canTempo && row.setting < row.maxSpeed - 1e-6
                onClicked: row.nudgeSpeed(0.01)
            }
            Text {
                Layout.preferredWidth: 50
                horizontalAlignment: Text.AlignRight
                text: "×" + row.speed.toFixed(3)
                font.pixelSize: Theme.sizeSm
                font.weight: Font.DemiBold
                font.features: { "tnum": 1 }
                color: row.bending ? Theme.warn : row.shown ? Theme.text : Theme.faint
                MouseArea { anchors.fill: parent; enabled: row.canTempo; onDoubleClicked: row.resetSpeed() }
            }
            Text {
                Layout.preferredWidth: 46
                text: row.view.signed(row.speed)
                font.pixelSize: Theme.sizeXs
                font.features: { "tnum": 1 }
                color: row.bending ? Theme.warn : Theme.body
                MouseArea { anchors.fill: parent; enabled: row.canTempo; onDoubleClicked: row.resetSpeed() }
            }
            TextButton {
                flat: true
                implicitHeight: 22
                leftPadding: 6
                rightPadding: 6
                font.pixelSize: Theme.sizeXs
                text: "复原"
                enabled: row.canTempo && Math.abs(row.setting - 1) > 1e-6
                onClicked: row.resetSpeed()
                ToolTip.visible: hovered
                ToolTip.delay: 600
                ToolTip.text: "回到素材原速（也可双击速度）"
            }
            // Who sets the speed: following, a held key, the hand; for an aux track, the main one's pace.
            Text {
                Layout.maximumWidth: 104
                text: row.main ? (row.view.match ? (row.view.match.rate_confidence >= 0.7 ? "智能 · 已稳定" : "智能 · 校准中")
                                  : row.view.player && row.view.player.aiLeads ? (row.view.player.tempoPaused ? "智能跳转 · 手动速度" : "智能调速 · 不跳转")
                                  : row.bending ? (row.view.speed > row.view.tempo ? "按住加速" : "按住减速")
                                  : row.view.manual ? "手动" : "智能跟随")
                      : row.player && row.player.lead ? "智能跟随"
                      : row.player && row.player.followMain ? "跟主轨速度" : "手动"
                font.pixelSize: 11
                color: Theme.faint
                elide: Text.ElideRight
            }
            Item { Layout.preferredWidth: 4 }
            // What happens after the row's last entry.
            TextButton {
                flat: true
                implicitHeight: 22
                leftPadding: 6
                rightPadding: 8
                font.pixelSize: Theme.sizeXs
                iconName: row.loop ? "refresh" : ""
                text: row.loop ? "循环" : "播完即停"
                enabled: row.main ? !!row.view.player : !!row.player
                onClicked: row.flipLoop()
                ToolTip.visible: hovered
                ToolTip.delay: 600
                ToolTip.text: row.loop ? "循环播放：放完" + (row.main ? " Set" : "这条轨道") + "的最后一个素材后从第一个重来；点一下改为播完即停"
                                       : "播完即停：放完" + (row.main ? " Set" : "这条轨道") + "的最后一个素材后停在最后一帧；点一下改为循环播放"
            }
        }

        // The entries end to end, the row's playhead and, on the main row, the cursor.
        Item {
            id: lane
            visible: !row.camera
            y: row.barHeight
            width: parent.width
            height: parent.height - y
            clip: true
            readonly property int tempoHeight: 16
            readonly property int waveHeight: Math.round((height - tempoHeight - 1) * 0.42)
            readonly property int filmHeight: height - tempoHeight - 1 - waveHeight

            Rectangle {
                anchors.fill: parent
                visible: !row.clips.length
                radius: Theme.radius
                color: Theme.inset
                Text {
                    anchors.centerIn: parent
                    text: row.emptyText
                    font.pixelSize: Theme.sizeSm
                    color: Theme.faint
                }
            }
            // By place, not by clip: the clips are made afresh whenever the
            // Set or the entry on the screen changes (every cut), and a model
            // of them would build every strip anew each time.
            Repeater {
                model: row.clips.length
                TrackPiece {
                    required property int index
                    view: row.view
                    clip: row.clips[index]
                    stripWidth: lane.width
                    tempoHeight: lane.tempoHeight
                    filmHeight: lane.filmHeight
                    waveHeight: lane.waveHeight
                    playingId: row.playingId
                    position: row.position
                    dimOff: row.main ? !row.view.manual : true
                    dimSilent: row.main ? !row.view.manual : false
                    numbered: row.clips.length > 1
                    small: !row.main
                }
            }
            Rectangle {
                visible: laneArea.containsMouse && !laneArea.pressed && row.clips.length > 0
                x: laneArea.mouseX
                width: 1
                height: lane.height
                color: "#80ffffff"
            }
            // The cursor, on the main row.
            Rectangle {
                readonly property real t: row.view.markT
                visible: row.main && t >= row.view.viewLeft && t <= row.view.viewLeft + row.view.span
                x: (t - row.view.viewLeft) * row.view.pps - 1.5
                width: 3
                height: lane.height
                color: "#99000000"
                Rectangle {
                    x: 1
                    width: 1
                    height: parent.height
                    color: "white"
                }
            }
            Item {
                visible: row.playT >= row.view.viewLeft && row.playT <= row.view.viewLeft + row.view.span
                x: (row.playT - row.view.viewLeft) * row.view.pps
                height: lane.height
                Rectangle {
                    x: -2
                    width: 4
                    height: lane.height
                    radius: 1
                    color: "#99000000"
                    Rectangle {
                        x: 1
                        width: 2
                        height: parent.height
                        color: row.main && row.view.parked ? Theme.muted : Theme.text
                    }
                }
            }
            // The main row: press or drag sets the cursor, never the picture
            // (跳至光标处 or Enter plays from it). An aux row: its picture
            // goes there. The wheel and a pinch move and zoom the shared view.
            MouseArea {
                id: laneArea
                anchors.fill: parent
                hoverEnabled: true
                preventStealing: true
                cursorShape: row.clips.length && (row.main || row.canSeek) ? Qt.PointingHandCursor : Qt.ArrowCursor
                function at(x) {
                    x = Math.max(0, Math.min(width, x))
                    if (row.main)
                        row.view.setMark(x)
                    else
                        row.seekTo(row.view.viewLeft + x / row.view.pps)
                    row.view.touch()
                }
                onPressed: mouse => at(mouse.x)
                onPositionChanged: mouse => {
                    if (pressed)
                        at(mouse.x)
                }
                onWheel: wheel => row.view.scroll(wheel, wheel.x)
            }
            PinchHandler {
                target: null
                onScaleChanged: delta => row.view.zoomAt(centroid.position.x, delta)
            }
        }
    }

    // Entries from the drawer, files from the desktop: onto this track.
    DropArea {
        id: drop
        anchors.fill: parent
        enabled: !row.camera
        keys: ["text/x-kvj-entry", "text/uri-list"]
        onDropped: event => {
            const ids = (event.getDataAsString("text/x-kvj-entry") || "").split(",").map(s => s.trim()).filter(s => s.length > 0)
            if (ids.length) {
                row.view.dropEntries(ids, row.track)
                event.acceptProposedAction()
            } else if (event.hasUrls) {
                row.view.dropFiles(event.urls, row.track)
                event.acceptProposedAction()
            }
        }
    }
    Rectangle {
        visible: drop.containsDrag
        anchors.fill: parent
        anchors.margins: -2
        radius: Theme.radius + 2
        color: Theme.dark ? "#14ffffff" : "#0d000000"
        border.width: 2
        border.color: Theme.text
        Rectangle {
            anchors.centerIn: parent
            width: dropLabel.implicitWidth + 20
            height: 26
            radius: 13
            color: Theme.text
            Text {
                id: dropLabel
                anchors.centerIn: parent
                text: "放到" + row.name
                font.pixelSize: Theme.sizeSm
                font.weight: Font.DemiBold
                color: Theme.bg
            }
        }
    }
}
