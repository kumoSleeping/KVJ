import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import QtQuick.Window
import KVJ

// Sender-only mode for the DJ's computer: pick the receiving computer, the
// Master input, and stream recognition features over Bluetooth. Nothing else
// runs here: no Set, no index, no video.
ColumnLayout {
    id: panel
    spacing: 18

    property bool running: false
    property var inputs: []

    readonly property var link: Engine.view.bluetooth || null
    readonly property var outgoing: (Engine.view.connections && Engine.view.connections.outgoing) || []
    // The receiver has made this computer its current DJ.
    readonly property var granted: {
        for (const p of outgoing)
            if (p.selected && (p.link.state === "connected" || p.link.state === "sending"))
                return p
        return null
    }
    // Connected, but the receiving computer has not made this one its DJ yet.
    readonly property bool waiting: !granted && outgoing.some(p => p.link.state === "connected")
    readonly property var localInputs: inputs.filter(d => d.kind !== "bluetooth")
    readonly property var input: localInputs.length ? localInputs[Math.min(inputBox.currentIndex, localInputs.length - 1)] : null

    function statusOf(id) {
        for (const p of outgoing)
            if (p.device.id === id)
                return p
        return null
    }
    function stateText(peer) {
        if (!peer)
            return ""
        switch (peer.link.state) {
        case "connecting": return "连接中"
        case "connected": return peer.selected ? "当前 DJ" : "待命"
        case "sending": return "发送中"
        case "reconnecting": return "重新连接"
        case "disconnected": return "已断开"
        default: return peer.link.state
        }
    }

    // Bluetooth is touched only once the sender is opened (the system may ask
    // for access). Receivers come and go, so the list refreshes while it is shown.
    Timer {
        interval: 8000
        repeat: true
        triggeredOnStart: true
        running: panel.visible && !!panel.Window.window && panel.Window.window.visible && !panel.running
        onTriggered: Engine.scanBluetooth()
    }

    ColumnLayout {
        Layout.fillWidth: true
        spacing: 6
        RowLayout {
            Layout.fillWidth: true
            Caption { text: "接收电脑"; Layout.fillWidth: true }
            // Only computers whose KVJ is receiving are listed (they advertise
            // the KVJ service); finding them takes a few seconds.
            BusyIndicator {
                running: Engine.busy
                visible: running
                implicitWidth: 18
                implicitHeight: 18
            }
            IconButton {
                iconName: "refresh"
                tip: "查找正在接收的 KVJ"
                enabled: !Engine.busy
                onClicked: Engine.scanBluetooth()
            }
        }
        Repeater {
            model: Engine.bluetoothDevices
            ItemDelegate {
                id: row
                required property var modelData
                readonly property var peer: panel.statusOf(modelData.id)
                Layout.fillWidth: true
                implicitHeight: 40
                topPadding: 0
                bottomPadding: 0
                leftPadding: 8
                rightPadding: 4
                contentItem: RowLayout {
                    spacing: 8
                    Text {
                        Layout.fillWidth: true
                        text: row.modelData.name
                        font.pixelSize: Theme.size
                        font.weight: row.peer && row.peer.selected ? Font.DemiBold : Font.Normal
                        color: row.peer ? Theme.text : Theme.body
                        elide: Text.ElideRight
                    }
                    Text {
                        text: panel.stateText(row.peer)
                        font.pixelSize: Theme.sizeXs
                        color: Theme.muted
                    }
                    TextButton {
                        text: row.peer ? "断开" : "连接"
                        enabled: !panel.running || !row.peer
                        onClicked: row.peer ? Engine.disconnectBluetooth(row.modelData.id)
                                            : Engine.connectBluetooth(row.modelData)
                    }
                }
                background: Rectangle {
                    radius: Theme.radius
                    color: row.hovered ? Theme.hover : "transparent"
                }
            }
        }
    }

    ColumnLayout {
        Layout.fillWidth: true
        spacing: 8
        Caption { text: "Master 输入" }
        Select {
            id: inputBox
            Layout.fillWidth: true
            enabled: !panel.running
            model: panel.localInputs.map(d => d.label + (d.error ? "（不可用）" : ""))
        }
        Select {
            id: channelBox
            Layout.preferredWidth: 120
            enabled: !panel.running
            model: {
                const channels = panel.input ? Math.max(1, panel.input.channels) : 2
                const pairs = []
                for (let i = 0; i < channels; i += 2)
                    pairs.push(i + 1 < channels ? "CH " + (i + 1) + "/" + (i + 2) : "CH " + (i + 1))
                return pairs
            }
        }
    }

    TextButton {
        Layout.fillWidth: true
        primary: true
        iconName: panel.running ? "square" : "send"
        text: panel.running ? "停止发送" : "开始发送"
        enabled: panel.running || (!!panel.granted && !Engine.busy)
        onClicked: panel.running ? Engine.stop()
                                 : Engine.startSending(panel.granted.device.id,
                                                       panel.input ? panel.input.id : "auto",
                                                       channelBox.currentIndex * 2)
    }

    Text {
        Layout.fillWidth: true
        visible: !panel.running && panel.waiting
        text: "等待接收电脑把这台设为当前 DJ"
        font.pixelSize: Theme.sizeSm
        color: Theme.muted
        wrapMode: Text.Wrap
    }

    Text {
        Layout.fillWidth: true
        visible: !!panel.link && panel.running
        text: panel.link ? "已发送 " + panel.link.packets + " 包"
                           + (panel.link.rtt_ms !== null && panel.link.rtt_ms !== undefined
                              ? " · 往返 " + panel.link.rtt_ms.toFixed(0) + " ms" : "") : ""
        font.pixelSize: Theme.sizeSm
        font.features: { "tnum": 1 }
        color: Theme.muted
    }
}
