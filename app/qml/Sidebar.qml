import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Dialogs
import QtQuick.Layouts
import KVJ

// Everything about Sets, and only here: the Sets, and the selected Set's
// entries; above them the keys for the DJ's side of things (this computer only
// sends, or receives over Bluetooth). Each entry has a key that turns it on or
// off, at once and also during the show: an entry that is off leaves the
// timeline and is not followed. At a handover between DJs the next one is
// turned on while the last stays on, and the last is turned off once the next
// is under way. Turning off the entry on the screen asks again, in red under
// it; the second press goes on to the next entry that is on.
ColumnLayout {
    id: bar
    spacing: 0

    property var sets: []
    property var currentSet: null
    property bool running: false
    property bool editable: true
    // The entry on the screen now, if any.
    property string playingId: ""
    property bool canSend: true
    property bool receiving: false
    property bool canReceive: false
    // The entry on the screen whose key was pressed once to turn it off.
    property string confirmId: ""

    signal selectSet(string id)
    signal addUrls(var urls)
    // This computer is the DJ's: only send.
    signal send()
    signal receive(bool on)
    // The entry on the screen is turned off, confirmed.
    signal dropPlaying(string id)

    readonly property var entries: currentSet ? currentSet.entries : []
    readonly property int enabledCount: entries.filter(e => e.enabled !== false).length

    function clock(seconds) {
        const s = Math.max(0, Math.floor(seconds))
        const m = Math.floor(s / 60)
        return m + ":" + (s % 60 < 10 ? "0" : "") + (s % 60)
    }
    // The list is rebuilt from the new document; keep it where it was.
    function enable(ids, on) {
        const y = entryList.contentY
        Engine.enableEntries(bar.currentSet.id, ids, on)
        entryList.contentY = y
        Qt.callLater(() => entryList.contentY = y)
    }
    function enableAll(on) {
        const ids = bar.entries.filter(e => (e.enabled !== false) !== on).map(e => e.id)
        // All off keeps the one on the screen: it is turned off on its own key.
        enable(on ? ids : ids.filter(id => id !== bar.playingId), on)
    }
    // A key pressed on an entry. Off for the one on the screen asks first.
    function press(entry, on) {
        if (!on && entry.id === bar.playingId && entry.enabled !== false) {
            if (bar.confirmId !== entry.id) {
                bar.confirmId = entry.id
                confirmTimer.restart()
                return
            }
            bar.confirmId = ""
            const y = entryList.contentY
            bar.dropPlaying(entry.id)
            entryList.contentY = y
            Qt.callLater(() => entryList.contentY = y)
            return
        }
        bar.confirmId = ""
        enable([entry.id], on)
    }
    onPlayingIdChanged: confirmId = ""
    Timer {
        id: confirmTimer
        interval: 6000
        onTriggered: bar.confirmId = ""
    }

    FileDialog {
        id: fileDialog
        fileMode: FileDialog.OpenFiles
        nameFilters: ["视频 (*.mp4 *.m4v *.mkv *.mov *.webm)"]
        onAccepted: bar.addUrls(selectedFiles)
    }
    FolderDialog {
        id: folderDialog
        onAccepted: bar.addUrls([selectedFolder])
    }

    // —— This computer's part: only sending, or receiving over Bluetooth ——
    RowLayout {
        Layout.fillWidth: true
        Layout.topMargin: 12
        Layout.leftMargin: 10
        Layout.rightMargin: 8
        spacing: 6
        TextButton {
            iconName: "send"
            text: "发送"
            enabled: bar.canSend
            ToolTip.visible: hovered
            ToolTip.delay: 600
            ToolTip.text: "这台是 DJ 电脑：收起播放器，打开只采集 Master、经蓝牙发给投影电脑的小窗"
            onClicked: bar.send()
        }
        TextButton {
            iconName: "bluetooth"
            text: "蓝牙"
            primary: bar.receiving
            implicitHeight: Theme.control
            enabled: bar.canReceive || bar.receiving
            ToolTip.visible: hovered
            ToolTip.delay: 600
            ToolTip.text: bar.receiving ? "正在等 DJ 电脑经蓝牙发来声音特征；再点回到本机声音输入"
                                        : "接收 DJ 电脑经蓝牙发来的声音特征（声音输入改为蓝牙接收）"
            onClicked: bar.receive(!bar.receiving)
        }
        Item { Layout.fillWidth: true }
    }

    // —— Sets ——
    RowLayout {
        Layout.fillWidth: true
        Layout.topMargin: 8
        Layout.leftMargin: 18
        Layout.rightMargin: 8
        Caption { text: "Set"; Layout.fillWidth: true }
        IconButton {
            iconName: "plus"
            tip: "新建 Set"
            enabled: !bar.running
            onClicked: Engine.createSet("Set " + (bar.sets.length + 1))
        }
    }
    ListView {
        Layout.fillWidth: true
        Layout.preferredHeight: Math.min(contentHeight, 33 * 5)
        Layout.leftMargin: 10
        Layout.rightMargin: 8
        clip: true
        spacing: 1
        model: bar.sets
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
        delegate: ItemDelegate {
            id: setRow
            required property var modelData
            readonly property bool current: !!bar.currentSet && bar.currentSet.id === modelData.id
            width: ListView.view.width
            height: 32
            topPadding: 0
            bottomPadding: 0
            leftPadding: 8
            rightPadding: 8
            enabled: !bar.running || current
            onClicked: bar.selectSet(modelData.id)
            contentItem: RowLayout {
                Text {
                    Layout.fillWidth: true
                    text: setRow.modelData.name
                    font.pixelSize: Theme.size
                    font.weight: setRow.current ? Font.DemiBold : Font.Normal
                    color: setRow.current ? Theme.text : Theme.muted
                    elide: Text.ElideRight
                }
                Text {
                    text: setRow.modelData.entries.length
                    font.pixelSize: Theme.sizeXs
                    font.features: { "tnum": 1 }
                    color: Theme.faint
                }
            }
            background: Rectangle {
                radius: Theme.radius
                color: setRow.current ? Theme.hover : setRow.hovered ? Theme.hover : "transparent"
            }
        }
    }

    Rectangle {
        Layout.fillWidth: true
        Layout.topMargin: 10
        Layout.preferredHeight: 1
        color: Theme.line
    }

    // —— The selected Set ——
    RowLayout {
        Layout.fillWidth: true
        Layout.topMargin: 12
        Layout.leftMargin: 18
        Layout.rightMargin: 8
        spacing: 0
        Text {
            Layout.fillWidth: true
            text: bar.currentSet ? bar.currentSet.name : "还没有 Set"
            font.pixelSize: Theme.sizeLg
            font.weight: Font.DemiBold
            color: bar.currentSet ? Theme.text : Theme.muted
            elide: Text.ElideRight
        }
        IconButton { iconName: "file-plus"; tip: "添加视频"; enabled: bar.editable; onClicked: fileDialog.open() }
        IconButton { iconName: "folder-plus"; tip: "添加文件夹里的视频"; enabled: bar.editable; onClicked: folderDialog.open() }
        IconButton {
            iconName: "trash"
            tip: "删除这个 Set"
            enabled: bar.editable && !!bar.currentSet
            onClicked: Engine.deleteSet(bar.currentSet.id)
        }
    }
    RowLayout {
        Layout.fillWidth: true
        Layout.leftMargin: 18
        Layout.rightMargin: 10
        Layout.bottomMargin: 4
        visible: bar.entries.length > 0
        spacing: 10
        Text {
            Layout.fillWidth: true
            text: bar.enabledCount + "/" + bar.entries.length + " 启用"
            font.pixelSize: Theme.sizeXs
            font.features: { "tnum": 1 }
            color: Theme.muted
        }
        Repeater {
            model: [{ label: "全开", on: true }, { label: "全关", on: false }]
            Text {
                id: all
                required property var modelData
                readonly property bool useful: modelData.on ? bar.enabledCount < bar.entries.length : bar.enabledCount > 0
                text: modelData.label
                font.pixelSize: Theme.sizeXs
                color: useful ? (allTap.containsMouse ? Theme.text : Theme.muted) : Theme.faint
                MouseArea {
                    id: allTap
                    anchors.fill: parent
                    anchors.margins: -4
                    hoverEnabled: true
                    enabled: all.useful
                    cursorShape: Qt.PointingHandCursor
                    onClicked: bar.enableAll(all.modelData.on)
                }
            }
        }
    }

    ListView {
        id: entryList
        Layout.fillWidth: true
        Layout.fillHeight: true
        Layout.leftMargin: 6
        Layout.rightMargin: 6
        clip: true
        model: bar.entries
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
        delegate: Column {
            id: slot
            required property var modelData
            required property int index
            width: ListView.view.width
            readonly property bool asking: bar.confirmId === modelData.id
            ItemDelegate {
                id: row
                readonly property var modelData: slot.modelData
                readonly property int index: slot.index
                readonly property bool on: modelData.enabled !== false
                readonly property bool playing: bar.playingId === modelData.id
                width: slot.width
                height: Theme.row
                topPadding: 0
                bottomPadding: 0
                leftPadding: 6
                rightPadding: 4
                // The whole row is the key: one tap at the booth, no aiming.
                onClicked: bar.press(modelData, !on)
                contentItem: RowLayout {
                    spacing: 8
                    Toggle {
                        padding: 0
                        checked: row.on
                        onToggled: {
                            // The document says whether it is on; a press only asks.
                            checked = Qt.binding(() => row.on)
                            bar.press(row.modelData, !row.on)
                        }
                    }
                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 0
                        Text {
                            Layout.fillWidth: true
                            text: row.modelData.title
                            font.pixelSize: Theme.sizeSm
                            font.weight: row.playing ? Font.DemiBold : Font.Normal
                            color: row.playing ? Theme.text : row.on ? Theme.body : Theme.faint
                            elide: Text.ElideRight
                        }
                        Text {
                            text: (row.index + 1) + " · " + bar.clock(row.modelData.duration)
                                  + (row.modelData.video ? "" : " · 音频") + (row.playing ? " · 正在投放" : "")
                            font.pixelSize: 11
                            font.features: { "tnum": 1 }
                            color: row.playing ? Theme.muted : Theme.faint
                        }
                    }
                    IconButton {
                        iconName: "x"
                        tip: "移出 Set"
                        implicitWidth: 24
                        implicitHeight: 24
                        opacity: row.hovered && bar.editable ? 1 : 0
                        enabled: opacity > 0
                        onClicked: Engine.removeEntry(bar.currentSet.id, row.modelData.id)
                    }
                }
                background: Rectangle {
                    radius: Theme.radius
                    color: row.hovered ? Theme.hover : "transparent"
                    // The entry on the screen: an ink edge.
                    Rectangle {
                        visible: row.playing
                        width: 3
                        height: parent.height - 12
                        anchors.verticalCenter: parent.verticalCenter
                        radius: 1.5
                        color: Theme.text
                    }
                }
            }
            // Turning off the entry on the screen, asked in place.
            Rectangle {
                visible: slot.asking
                x: 6
                width: slot.width - 12
                height: visible ? warning.implicitHeight + 12 : 0
                radius: Theme.radius
                color: Theme.danger
                Text {
                    id: warning
                    anchors.fill: parent
                    anchors.margins: 6
                    anchors.leftMargin: 8
                    text: "正在播放这个视频。再点一次取消勾选，画面将跳到下一个启用视频的开头。"
                    font.pixelSize: Theme.sizeXs
                    font.weight: Font.Medium
                    color: "white"
                    wrapMode: Text.Wrap
                    verticalAlignment: Text.AlignVCenter
                }
                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: bar.confirmId = ""
                }
            }
        }
        Text {
            anchors.centerIn: parent
            width: parent.width - 32
            visible: entryList.count === 0
            text: bar.running ? "" : "把视频或文件夹拖进来"
            font.pixelSize: Theme.sizeSm
            color: Theme.faint
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.Wrap
        }
        DropArea {
            anchors.fill: parent
            enabled: bar.editable
            onDropped: drop => {
                if (drop.hasUrls)
                    bar.addUrls(drop.urls)
            }
        }
    }

    // Foot: what the Set holds in all.
    Rectangle {
        Layout.fillWidth: true
        Layout.preferredHeight: 30
        color: Theme.raised
        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: 18
            anchors.rightMargin: 10
            Text {
                Layout.fillWidth: true
                visible: !!bar.currentSet
                text: {
                    let total = 0
                    for (const e of bar.entries)
                        total += e.duration
                    return bar.entries.length + " 个素材 · " + bar.clock(total)
                }
                font.pixelSize: Theme.sizeXs
                font.features: { "tnum": 1 }
                color: Theme.muted
            }
            BusyIndicator {
                running: Engine.importing
                visible: running
                implicitWidth: 18
                implicitHeight: 18
                palette.dark: Theme.muted
            }
        }
    }
}
