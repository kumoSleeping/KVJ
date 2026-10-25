import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Dialogs
import QtQuick.Layouts
import KVJ

// Everything about Sets, and only here: the Sets, and the selected Set's
// entries. Each entry has a key that turns it on or off for following, also
// during the show: at a handover between DJs the next one is turned on while the
// last stays on, and the last is turned off once the next is under way.
ColumnLayout {
    id: bar
    spacing: 0

    property var sets: []
    property var currentSet: null
    property bool running: false
    property bool editable: true
    // The entry on the screen now, if any.
    property string playingId: ""

    signal selectSet(string id)
    signal addUrls(var urls)

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
        enable(bar.entries.filter(e => (e.enabled !== false) !== on).map(e => e.id), on)
    }

    FileDialog {
        id: fileDialog
        fileMode: FileDialog.OpenFiles
        nameFilters: ["音视频 (*.mp4 *.m4v *.mkv *.mov *.webm *.mp3 *.m4a *.flac *.wav *.aac *.ogg *.opus)"]
        onAccepted: bar.addUrls(selectedFiles)
    }
    FolderDialog {
        id: folderDialog
        onAccepted: bar.addUrls([selectedFolder])
    }

    // —— Sets ——
    RowLayout {
        Layout.fillWidth: true
        Layout.topMargin: 14
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
        IconButton { iconName: "file-plus"; tip: "添加文件"; enabled: bar.editable; onClicked: fileDialog.open() }
        IconButton { iconName: "folder-plus"; tip: "添加文件夹"; enabled: bar.editable; onClicked: folderDialog.open() }
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
        delegate: ItemDelegate {
            id: row
            required property var modelData
            required property int index
            readonly property bool on: modelData.enabled !== false
            readonly property bool playing: bar.playingId === modelData.id
            width: ListView.view.width
            height: Theme.row
            topPadding: 0
            bottomPadding: 0
            leftPadding: 6
            rightPadding: 4
            // The whole row is the key: one tap at the booth, no aiming.
            onClicked: bar.enable([modelData.id], !on)
            contentItem: RowLayout {
                spacing: 8
                Toggle {
                    padding: 0
                    checked: row.on
                    onToggled: bar.enable([row.modelData.id], checked)
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
