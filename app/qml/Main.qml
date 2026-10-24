import QtCore
import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Dialogs
import QtQuick.Layouts
import KVJ

// The operator's window, three regions of one sheet: the Sets, the selected
// Set's entries on a foot bar, and the live controls on the raised tone.
// The projection window shows only the picture.
ApplicationWindow {
    id: app
    width: 1080
    height: 680
    minimumWidth: 880
    minimumHeight: 540
    visible: true
    title: "KVJ"
    color: Theme.bg
    font.pixelSize: Theme.size
    palette.window: Theme.bg
    palette.windowText: Theme.text
    palette.base: Theme.inset
    palette.text: Theme.text
    palette.button: Theme.raised
    palette.buttonText: Theme.text
    palette.highlight: Theme.line
    palette.highlightedText: Theme.text
    palette.toolTipBase: Theme.raised
    palette.toolTipText: Theme.text
    palette.mid: Theme.line
    palette.dark: Theme.muted

    readonly property var sets: Engine.document.sets || []
    property string setId: ""
    readonly property var currentSet: {
        for (const s of sets)
            if (s.id === setId)
                return s
        return sets.length ? sets[0] : null
    }
    readonly property var entries: currentSet ? currentSet.entries : []
    readonly property var view: Engine.view
    readonly property string phase: view.phase || ""
    readonly property bool running: ["indexing", "permission", "listening", "matched", "searching"].indexOf(phase) >= 0
    readonly property var match: Engine.matched && Engine.matched.entry ? Engine.matched : null
    readonly property var devices: Engine.devices
    readonly property var device: devices.length ? devices[Math.min(deviceBox.currentIndex, devices.length - 1)] : null
    readonly property bool editable: !!currentSet && !running && !Engine.busy

    function clock(seconds, tenths) {
        const s = Math.max(0, seconds)
        const m = Math.floor(s / 60)
        const rest = s - m * 60
        const text = tenths ? rest.toFixed(1) : Math.floor(rest).toString()
        return m + ":" + (rest < 10 ? "0" : "") + text
    }
    function phaseText(p) {
        switch (p) {
        case "indexing": return "建立索引 " + (view.indexed || 0) + "/" + (view.total || 0)
        case "permission": return "等待录音权限"
        case "listening": return "监听中"
        case "matched": return "跟随中"
        case "searching": return "重新搜索"
        case "prepared": return "索引就绪"
        case "failed": return "失败"
        case "stopped": return "已停止"
        default: return ""
        }
    }

    readonly property var heights: [480, 720, 1080, 0]
    readonly property var rates: [24, 30, 60, 0]

    Projection {
        id: projection
        offsetMs: offset.value
        maxHeight: app.heights[heightBox.currentIndex] ?? 720
        maxFps: app.rates[fpsBox.currentIndex] ?? 30
    }
    Settings {
        category: "output"
        property alias height: heightBox.currentIndex
        property alias fps: fpsBox.currentIndex
        property alias offset: offset.value
        property alias fullscreen: fullscreen.checked
    }
    FileDialog {
        id: fileDialog
        fileMode: FileDialog.OpenFiles
        nameFilters: ["音视频 (*.mp4 *.m4v *.mkv *.mov *.webm *.mp3 *.m4a *.flac *.wav *.aac *.ogg *.opus)"]
        onAccepted: if (app.currentSet) Engine.importUrls(app.currentSet.id, selectedFiles)
    }
    FolderDialog {
        id: folderDialog
        onAccepted: if (app.currentSet) Engine.importUrls(app.currentSet.id, [selectedFolder])
    }

    RowLayout {
        anchors.fill: parent
        spacing: 0

        // —— Sets ——
        ColumnLayout {
            Layout.preferredWidth: 188
            Layout.maximumWidth: 188
            Layout.fillWidth: false
            Layout.fillHeight: true
            Layout.topMargin: 14
            Layout.leftMargin: 10
            Layout.rightMargin: 6
            spacing: 6

            RowLayout {
                Layout.fillWidth: true
                Layout.leftMargin: 8
                Caption { text: "Set"; Layout.fillWidth: true }
                IconButton {
                    iconName: "plus"
                    tip: "新建 Set"
                    enabled: !app.running
                    onClicked: Engine.createSet("Set " + (app.sets.length + 1))
                }
            }
            ListView {
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true
                spacing: 1
                model: app.sets
                delegate: ItemDelegate {
                    id: setRow
                    required property var modelData
                    readonly property bool current: !!app.currentSet && app.currentSet.id === modelData.id
                    width: ListView.view.width
                    height: 32
                    leftPadding: 8
                    enabled: !app.running || current
                    onClicked: app.setId = modelData.id
                    contentItem: Text {
                        text: setRow.modelData.name
                        font.pixelSize: Theme.size
                        font.weight: setRow.current ? Font.DemiBold : Font.Normal
                        color: setRow.current ? Theme.text : Theme.muted
                        verticalAlignment: Text.AlignVCenter
                        elide: Text.ElideRight
                    }
                    background: Rectangle {
                        radius: Theme.radius
                        color: setRow.hovered ? Theme.hover : "transparent"
                    }
                }
            }
        }

        // —— Entries of the selected Set ——
        ColumnLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: 0

            RowLayout {
                Layout.fillWidth: true
                Layout.topMargin: 12
                Layout.leftMargin: 12
                Layout.rightMargin: 12
                Layout.bottomMargin: 6
                spacing: 2
                Text {
                    Layout.fillWidth: true
                    text: app.currentSet ? app.currentSet.name : ""
                    font.pixelSize: Theme.sizeLg
                    font.weight: Font.DemiBold
                    color: Theme.text
                    elide: Text.ElideRight
                }
                IconButton { iconName: "file-plus"; tip: "添加文件"; enabled: app.editable; onClicked: fileDialog.open() }
                IconButton { iconName: "folder-plus"; tip: "添加文件夹"; enabled: app.editable; onClicked: folderDialog.open() }
                IconButton {
                    iconName: "trash"
                    tip: "删除这个 Set"
                    enabled: app.editable
                    onClicked: Engine.deleteSet(app.currentSet.id)
                }
            }

            ListView {
                id: entryList
                Layout.fillWidth: true
                Layout.fillHeight: true
                Layout.leftMargin: 6
                Layout.rightMargin: 6
                clip: true
                model: app.entries
                ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
                delegate: ItemDelegate {
                    id: row
                    required property var modelData
                    required property int index
                    readonly property bool playing: !!app.match && app.match.entry.id === modelData.id
                    width: ListView.view.width
                    height: Theme.row
                    leftPadding: 10
                    rightPadding: 6
                    contentItem: RowLayout {
                        spacing: 10
                        Text {
                            Layout.preferredWidth: 22
                            text: row.index + 1
                            font.pixelSize: Theme.sizeXs
                            font.features: { "tnum": 1 }
                            color: Theme.faint
                            horizontalAlignment: Text.AlignRight
                        }
                        Text {
                            Layout.fillWidth: true
                            text: row.modelData.title
                            font.pixelSize: Theme.size
                            font.weight: row.playing ? Font.DemiBold : Font.Normal
                            color: row.playing ? Theme.text : Theme.body
                            elide: Text.ElideRight
                        }
                        Text {
                            visible: !row.modelData.video
                            text: "音频"
                            font.pixelSize: Theme.sizeXs
                            color: Theme.faint
                        }
                        Text {
                            text: app.clock(row.modelData.duration, false)
                            font.pixelSize: Theme.sizeSm
                            font.features: { "tnum": 1 }
                            color: Theme.muted
                        }
                        IconButton {
                            iconName: "x"
                            tip: "移出 Set"
                            implicitWidth: 24
                            implicitHeight: 24
                            opacity: row.hovered && !app.running ? 1 : 0
                            enabled: opacity > 0
                            onClicked: Engine.removeEntry(app.currentSet.id, row.modelData.id)
                        }
                    }
                    background: Rectangle {
                        radius: Theme.radius
                        color: row.hovered ? Theme.hover : "transparent"
                    }
                }
                DropArea {
                    anchors.fill: parent
                    enabled: app.editable
                    onDropped: drop => {
                        if (drop.hasUrls)
                            Engine.importUrls(app.currentSet.id, drop.urls)
                    }
                }
            }

            // Foot bar: where the list is and what it holds.
            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: 30
                color: Theme.raised
                RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: 16
                    anchors.rightMargin: 12
                    Text {
                        Layout.fillWidth: true
                        visible: !!app.currentSet
                        text: {
                            let total = 0
                            for (const e of app.entries)
                                total += e.duration
                            return app.entries.length + " 个素材 · " + app.clock(total, false)
                        }
                        font.pixelSize: Theme.sizeXs
                        font.features: { "tnum": 1 }
                        color: Theme.muted
                    }
                    BusyIndicator {
                        running: Engine.busy
                        visible: running
                        implicitWidth: 18
                        implicitHeight: 18
                        palette.dark: Theme.muted
                    }
                }
            }
        }

        // —— Live controls ——
        Rectangle {
            Layout.preferredWidth: 340
            Layout.fillWidth: false
            Layout.fillHeight: true
            color: Theme.raised

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: Theme.gap
                spacing: 18

                // What is on the screen now.
                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 4
                    Text {
                        Layout.fillWidth: true
                        text: app.match ? app.match.entry.title : (app.phaseText(app.phase) || "KVJ")
                        font.pixelSize: 18
                        font.weight: Font.DemiBold
                        color: app.match ? Theme.text : Theme.muted
                        elide: Text.ElideRight
                    }
                    Text {
                        Layout.fillWidth: true
                        visible: !!app.match
                        text: app.match ? app.phaseText(app.phase) + " · " + app.clock(app.match.position, true)
                                          + " · ×" + app.match.rate.toFixed(3) : ""
                        font.pixelSize: Theme.sizeSm
                        font.features: { "tnum": 1 }
                        color: Theme.muted
                    }
                    // Input level of the selected channels.
                    Rectangle {
                        Layout.fillWidth: true
                        Layout.topMargin: 6
                        Layout.preferredHeight: 3
                        radius: 1.5
                        color: Theme.line
                        visible: app.running
                        Rectangle {
                            readonly property real db: app.view.input && app.view.input.rms_dbfs !== null ? app.view.input.rms_dbfs : -70
                            width: parent.width * Math.max(0, Math.min(1, (db + 70) / 70))
                            height: parent.height
                            radius: 1.5
                            color: Theme.text
                            Behavior on width { NumberAnimation { duration: 120 } }
                        }
                    }
                }

                TextButton {
                    Layout.fillWidth: true
                    primary: true
                    iconName: app.running ? "square" : "play"
                    text: app.running ? "停止" : "开始跟随"
                    enabled: app.running || (!!app.currentSet && app.entries.length > 0 && !Engine.busy)
                    onClicked: {
                        if (app.running) {
                            Engine.stop()
                            return
                        }
                        Engine.start(app.currentSet.id, app.device ? app.device.id : "auto", channelBox.currentIndex * 2)
                        if (!projection.visible)
                            projection.openOn(screenBox.currentIndex, fullscreen.checked)
                    }
                }

                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 8
                    Caption { text: "声音输入" }
                    Select {
                        id: deviceBox
                        Layout.fillWidth: true
                        enabled: !app.running
                        model: app.devices.map(d => d.label + (d.error ? "（不可用）" : ""))
                    }
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 6
                        Select {
                            id: channelBox
                            Layout.preferredWidth: 120
                            enabled: !app.running
                            model: {
                                const channels = app.device ? Math.max(1, app.device.channels) : 2
                                const pairs = []
                                for (let i = 0; i < channels; i += 2)
                                    pairs.push(i + 1 < channels ? "CH " + (i + 1) + "/" + (i + 2) : "CH " + (i + 1))
                                return pairs
                            }
                        }
                        Item { Layout.fillWidth: true }
                        IconButton {
                            iconName: "refresh"
                            tip: "刷新设备"
                            enabled: !app.running && !Engine.busy
                            onClicked: Engine.refreshDevices()
                        }
                    }
                }

                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 8
                    Caption { text: "画面输出" }
                    Select {
                        id: screenBox
                        Layout.fillWidth: true
                        model: Qt.application.screens.map((s, i) => (s.name || ("屏幕 " + (i + 1))) + " · " + s.width + "×" + s.height)
                        currentIndex: Qt.application.screens.length > 1 ? 1 : 0
                    }
                    RowLayout {
                        Layout.fillWidth: true
                        Toggle {
                            id: fullscreen
                            text: "全屏"
                            checked: Qt.application.screens.length > 1
                        }
                        Item { Layout.fillWidth: true }
                        TextButton {
                            iconName: "monitor"
                            text: projection.visible ? "收起投放" : "投放"
                            onClicked: projection.visible ? projection.closeOutput()
                                                          : projection.openOn(screenBox.currentIndex, fullscreen.checked)
                        }
                    }
                    // Lower is lighter on a machine that also runs the DJ software.
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 6
                        Select {
                            id: heightBox
                            Layout.fillWidth: true
                            model: ["480p", "720p", "1080p", "原始分辨率"]
                            currentIndex: 1
                        }
                        Select {
                            id: fpsBox
                            Layout.fillWidth: true
                            model: ["24 帧", "30 帧", "60 帧", "跟随素材"]
                            currentIndex: 1
                        }
                    }
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 8
                        Text { text: "画面偏移"; font.pixelSize: Theme.sizeSm; color: Theme.muted }
                        Seek {
                            id: offset
                            Layout.fillWidth: true
                            from: -400
                            to: 400
                            stepSize: 10
                            value: 0
                        }
                        Text {
                            Layout.preferredWidth: 58
                            horizontalAlignment: Text.AlignRight
                            text: (offset.value > 0 ? "+" : "") + offset.value.toFixed(0) + " ms"
                            font.pixelSize: Theme.sizeSm
                            font.features: { "tnum": 1 }
                            color: offset.value === 0 ? Theme.muted : Theme.text
                            MouseArea { anchors.fill: parent; onDoubleClicked: offset.value = 0 }
                        }
                    }
                }

                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 8
                    Caption { text: "弹幕" }
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 6
                        Field {
                            id: words
                            Layout.fillWidth: true
                            onAccepted: {
                                projection.overlay.say(text)
                                clear()
                            }
                        }
                        IconButton {
                            iconName: "send"
                            tip: "发到画面上"
                            enabled: words.text.trim().length > 0
                            onClicked: words.accepted()
                        }
                    }
                    Flow {
                        Layout.fillWidth: true
                        spacing: 2
                        Repeater {
                            model: ["🎉", "👏", "❤️", "🔥", "😂", "✨", "🙌", "🎶"]
                            ToolButton {
                                id: emoji
                                required property string modelData
                                implicitWidth: 36
                                implicitHeight: 36
                                padding: 0
                                onClicked: projection.overlay.pop(modelData)
                                contentItem: Text {
                                    text: emoji.modelData
                                    font.pixelSize: 20
                                    horizontalAlignment: Text.AlignHCenter
                                    verticalAlignment: Text.AlignVCenter
                                }
                                background: Rectangle {
                                    radius: Theme.radius
                                    color: emoji.down ? Theme.line : emoji.hovered ? Theme.hover : "transparent"
                                }
                            }
                        }
                    }
                }

                Text {
                    Layout.fillWidth: true
                    visible: Engine.error.length > 0
                    text: Engine.error
                    font.pixelSize: Theme.sizeSm
                    color: Theme.warn
                    wrapMode: Text.Wrap
                    MouseArea { anchors.fill: parent; onClicked: Engine.clearError() }
                }

                ListView {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    clip: true
                    model: Engine.logs
                    onCountChanged: positionViewAtEnd()
                    delegate: Text {
                        required property string modelData
                        width: ListView.view.width
                        text: modelData
                        font.pixelSize: 11
                        color: Theme.faint
                        elide: Text.ElideRight
                        topPadding: 1
                        bottomPadding: 1
                    }
                }
            }
        }
    }

    onClosing: {
        if (app.running)
            Engine.stop()
        projection.closeOutput()
    }
}
