import QtCore
import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Window
import QtQuick.Layouts
import KVJ

// The operator's one window, three regions of one sheet: the sidebar with the
// Sets and their entries, the live desk (preview, words, reactions, stickers,
// effects and the timeline), and following or sending on the raised tone.
// The projection window shows only the picture.
ApplicationWindow {
    id: app
    width: Math.min(1480, Screen.desktopAvailableWidth)
    height: Math.min(900, Screen.desktopAvailableHeight)
    minimumWidth: 1180
    minimumHeight: 680
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
    readonly property bool running: ["indexing", "permission", "listening", "matched", "searching", "connecting", "sending"].indexOf(phase) >= 0
    // 0: follow and project on this computer; 1: only send to another computer.
    // `--send` opens straight into sending, for the DJ's own computer.
    property int page: Qt.application.arguments.indexOf("--send") >= 0 ? 1 : 0
    readonly property var match: Engine.matched && Engine.matched.entry ? Engine.matched : null
    readonly property var devices: Engine.devices
    readonly property var device: devices.length ? devices[Math.min(deviceBox.currentIndex, devices.length - 1)] : null
    // Adding never waits for a Set: the first files make "Set 1".
    readonly property bool editable: !running && !Engine.importing
    // Receiving over Bluetooth: advertise for as long as it is the chosen input,
    // so the DJ's computer can find this one before following starts.
    readonly property bool receiving: page === 0 && !!device && device.id === "bluetooth"
    onReceivingChanged: Engine.listenBluetooth(receiving)

    function addUrls(urls) {
        if (!urls || urls.length === 0 || !app.editable)
            return
        if (!app.currentSet)
            Engine.createSet("Set " + (app.sets.length + 1))
        if (app.currentSet)
            Engine.importUrls(app.currentSet.id, urls)
    }

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
        // The desk's preview is up whenever this window is.
        previewing: app.visible && app.visibility !== Window.Minimized
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

    RowLayout {
        anchors.fill: parent
        spacing: 0

        // —— Sets and their entries ——
        Sidebar {
            Layout.preferredWidth: 252
            Layout.fillWidth: false
            Layout.fillHeight: true
            sets: app.sets
            currentSet: app.currentSet
            running: app.running
            editable: app.editable
            playingId: app.match ? app.match.entry.id : ""
            onSelectSet: id => app.setId = id
            onAddUrls: urls => app.addUrls(urls)
        }
        Rectangle {
            Layout.fillHeight: true
            Layout.preferredWidth: 1
            color: Theme.line
        }

        // —— The live desk ——
        Desk {
            Layout.fillWidth: true
            Layout.fillHeight: true
            Layout.margins: Theme.gap
            source: projection.surface
            entry: projection.entry
            entries: app.entries
            running: app.running
            phase: app.phase
        }

        // —— Live controls ——
        Rectangle {
            Layout.preferredWidth: 330
            Layout.fillWidth: false
            Layout.fillHeight: true
            color: Theme.raised

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: Theme.gap
                spacing: 14

                // Two jobs: follow and project here, or only send to another computer.
                RowLayout {
                    spacing: 18
                    Repeater {
                        model: ["跟随投放", "只发送"]
                        Text {
                            id: tab
                            required property int index
                            required property string modelData
                            readonly property bool current: app.page === index
                            text: modelData
                            font.pixelSize: Theme.sizeLg
                            font.weight: current ? Font.DemiBold : Font.Normal
                            color: current ? Theme.text : Theme.muted
                            MouseArea {
                                anchors.fill: parent
                                enabled: !app.running
                                cursorShape: Qt.PointingHandCursor
                                onClicked: app.page = tab.index
                            }
                        }
                    }
                }

                StackLayout {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    currentIndex: app.page

            ColumnLayout {
                spacing: 18

                // What is on the screen now. Empty while idle, and then it must
                // not take a share of the height (layouts fill by default).
                ColumnLayout {
                    Layout.fillWidth: true
                    Layout.fillHeight: false
                    spacing: 4
                    Text {
                        Layout.fillWidth: true
                        visible: text.length > 0
                        text: app.match ? app.match.entry.title : app.phaseText(app.phase)
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
                    // At least one entry on; more can be turned on while following.
                    enabled: app.running || (!!app.currentSet && app.entries.some(e => e.enabled !== false) && !Engine.importing)
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

                // Receiving over Bluetooth: the operator picks the current DJ.
                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 4
                    visible: app.page === 0 && !!app.device && app.device.id === "bluetooth"
                    Caption { text: "DJ" }
                    Repeater {
                        model: (app.view.connections && app.view.connections.incoming) || []
                        ItemDelegate {
                            id: dj
                            required property var modelData
                            Layout.fillWidth: true
                            implicitHeight: 32
                            topPadding: 0
                            bottomPadding: 0
                            leftPadding: 8
                            onClicked: Engine.selectBluetooth(modelData.selected ? "" : modelData.link.peer)
                            contentItem: RowLayout {
                                Text {
                                    Layout.fillWidth: true
                                    text: dj.modelData.device.name
                                    font.pixelSize: Theme.size
                                    font.weight: dj.modelData.selected ? Font.DemiBold : Font.Normal
                                    color: dj.modelData.selected ? Theme.text : Theme.muted
                                    elide: Text.ElideRight
                                }
                                Text {
                                    text: dj.modelData.link.state === "receiving" ? "发送中"
                                        : dj.modelData.link.state === "connected" ? "待命" : "已断开"
                                    font.pixelSize: Theme.sizeXs
                                    color: Theme.muted
                                }
                            }
                            background: Rectangle {
                                radius: Theme.radius
                                color: dj.hovered ? Theme.hover : "transparent"
                            }
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

                Text {
                    Layout.fillWidth: true
                    visible: Engine.error.length > 0
                    text: Engine.error
                    font.pixelSize: Theme.sizeSm
                    color: Theme.warn
                    wrapMode: Text.Wrap
                    MouseArea { anchors.fill: parent; onClicked: Engine.clearError() }
                }

                Item { Layout.fillHeight: true }
            }

                SendPanel {
                    running: app.running
                    inputs: app.devices
                }
                }
            }
        }
    }

    // `--add <file or folder>` adds it at start, the same way the add keys do.
    Component.onCompleted: {
        const args = Qt.application.arguments
        for (let i = 0; i + 1 < args.length; ++i)
            if (args[i] === "--add")
                app.addUrls([Engine.fileUrl(args[i + 1])])
    }

    onClosing: {
        if (app.running)
            Engine.stop()
        projection.closeOutput()
    }
}
