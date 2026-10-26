import QtCore
import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import QtQuick.Window
import KVJ

// Sender-only mode for the DJ's computer: pick the receiving computer, the
// Master input, and stream recognition features over Bluetooth. Nothing else
// runs here: no Set, no index, no video.
// A receiver is paired once (its operator allows this computer); after that
// both remember each other: it is connected to as soon as it is found, and
// sending starts by itself when it makes this computer its DJ.
ColumnLayout {
    id: panel
    spacing: 18

    property bool running: false
    property var inputs: []
    property bool autoSend: true
    property string savedInput: ""
    property int savedChannel: 0

    readonly property var link: Engine.view.bluetooth || null
    readonly property var outgoing: (Engine.view.connections && Engine.view.connections.outgoing) || []
    readonly property var knownReceivers: ((Engine.view.connections && Engine.view.connections.known) || []).filter(k => k.role === "receiver")
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

    // One row per receiving computer: connections first, then ones found
    // nearby, then remembered ones that are not around.
    readonly property var rows: {
        const rows = []
        const same = (k, d) => !!d && (k.id === d.id || k.name === d.name)
        for (const p of outgoing)
            rows.push({ name: p.device.name, device: p.device, peer: p, token: p.token, known: p.known })
        for (const d of Engine.bluetoothDevices) {
            if (outgoing.some(p => p.device.id === d.id))
                continue
            const k = knownReceivers.find(k => same(k, d))
            rows.push({ name: d.name, device: d, peer: null, token: k ? k.token : "", known: !!k })
        }
        for (const k of knownReceivers)
            if (!rows.some(r => r.token === k.token || same(k, r.device)))
                rows.push({ name: k.name, device: null, peer: null, token: k.token, known: true })
        return rows
    }

    function stateText(row) {
        const peer = row.peer
        if (!peer)
            return row.device ? (row.known ? "已记住" : "") : "已记住 · 不在附近"
        switch (peer.link.state) {
        case "connecting": return "连接中"
        case "asking": return "等待对方允许"
        case "connected": return peer.selected ? "当前 DJ" : "待命"
        case "sending": return "发送中"
        case "reconnecting": return "重新连接"
        case "refused": return "对方拒绝了"
        case "disconnected": return "已断开"
        default: return peer.link.state
        }
    }
    function start() {
        if (!granted)
            return
        savedInput = input ? input.id : ""
        savedChannel = channelBox.currentIndex
        Engine.startSending(granted.device.id, input ? input.id : "auto", channelBox.currentIndex * 2)
    }

    Settings {
        category: "send"
        property alias auto: panel.autoSend
        property alias input: panel.savedInput
        property alias channel: panel.savedChannel
    }

    // Start by itself once per grant: stopping by hand, or a failed start,
    // waits for the receiver to choose this computer again.
    property bool tried: false
    onGrantedChanged: if (!granted) tried = false
    Timer {
        interval: 400
        repeat: true
        running: panel.autoSend && !!panel.granted && !panel.running && !panel.tried && !Engine.busy
        onTriggered: {
            panel.tried = true
            panel.start()
        }
    }

    // Bluetooth is touched only once the sender is opened (the system may ask
    // for access). Receivers come and go, so the list refreshes while it is
    // shown; remembered ones found are connected to by the engine.
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
            // Only computers whose KVJ can be found are listed (they advertise
            // the KVJ service); finding them takes a few seconds.
            BusyIndicator {
                running: Engine.busy
                visible: running
                implicitWidth: 18
                implicitHeight: 18
            }
            IconButton {
                iconName: "refresh"
                tip: "查找附近的 KVJ"
                enabled: !Engine.busy
                onClicked: Engine.scanBluetooth()
            }
        }
        Repeater {
            model: panel.rows
            ItemDelegate {
                id: row
                required property var modelData
                readonly property var peer: modelData.peer
                readonly property bool ended: !!peer && (peer.link.state === "refused" || peer.link.state === "disconnected")
                Layout.fillWidth: true
                implicitHeight: 40
                topPadding: 0
                bottomPadding: 0
                leftPadding: 8
                rightPadding: 4
                ToolTip.visible: hovered && !!peer && !!peer.link.error
                ToolTip.delay: 400
                ToolTip.text: peer ? peer.link.error || "" : ""
                contentItem: RowLayout {
                    spacing: 8
                    Text {
                        Layout.fillWidth: true
                        text: row.modelData.name
                        font.pixelSize: Theme.size
                        font.weight: row.peer && row.peer.selected ? Font.DemiBold : Font.Normal
                        color: row.peer && !row.ended ? Theme.text : row.modelData.device ? Theme.body : Theme.faint
                        elide: Text.ElideRight
                    }
                    Text {
                        text: panel.stateText(row.modelData)
                        font.pixelSize: Theme.sizeXs
                        color: Theme.muted
                    }
                    IconButton {
                        visible: row.modelData.known && row.hovered && !!row.modelData.token
                        iconName: "x"
                        tip: "忘记这台接收电脑（下次需对方重新允许）"
                        enabled: !panel.running || !row.peer || !row.peer.selected
                        onClicked: Engine.forgetBluetooth(row.modelData.token)
                    }
                    TextButton {
                        visible: !!row.modelData.device
                        text: row.peer && !row.ended ? (row.peer.link.state === "asking" ? "取消" : "断开")
                                                     : row.ended ? "重试" : "连接"
                        enabled: !panel.running || !row.peer || !row.peer.selected
                        onClicked: row.peer && !row.ended ? Engine.disconnectBluetooth(row.modelData.device.id)
                                                          : Engine.connectBluetooth(row.modelData.device)
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
            // The input chosen last time, once the list is known.
            Connections {
                target: panel
                function onLocalInputsChanged() {
                    const i = panel.localInputs.findIndex(d => d.id === panel.savedInput)
                    if (i >= 0)
                        inputBox.currentIndex = i
                }
            }
        }
        Select {
            id: channelBox
            Layout.preferredWidth: 120
            enabled: !panel.running
            currentIndex: Math.min(panel.savedChannel, count - 1)
            model: {
                const channels = panel.input ? Math.max(1, panel.input.channels) : 2
                const pairs = []
                for (let i = 0; i < channels; i += 2)
                    pairs.push(i + 1 < channels ? "CH " + (i + 1) + "/" + (i + 2) : "CH " + (i + 1))
                return pairs
            }
        }
        Toggle {
            text: "被设为当前 DJ 后自动开始发送"
            checked: panel.autoSend
            onToggled: panel.autoSend = checked
        }
    }

    TextButton {
        Layout.fillWidth: true
        primary: true
        iconName: panel.running ? "square" : "send"
        text: panel.running ? "停止发送" : "开始发送"
        enabled: panel.running || (!!panel.granted && !Engine.busy)
        onClicked: {
            panel.tried = true
            if (panel.running)
                Engine.stop()
            else
                panel.start()
        }
    }

    Text {
        Layout.fillWidth: true
        visible: !panel.running && (panel.waiting || panel.outgoing.some(p => p.link.state === "asking"))
        text: panel.waiting ? "等待接收电脑把这台设为当前 DJ" : "请在接收电脑上点「允许」，之后两边都会记住对方"
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
