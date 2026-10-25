import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import KVJ

// The sender on its own, for the DJ's computer: a small window that only
// captures the Master and keeps the Bluetooth link to the projecting computer.
// The player's window is put away meanwhile; closing this brings it back.
ApplicationWindow {
    id: sender
    width: 380
    height: 520
    minimumWidth: 340
    minimumHeight: 440
    title: "KVJ 发送"
    // A window of its own (not the player's child), so it keeps its place in
    // the Dock or taskbar while the player is put away.
    transientParent: null
    color: Theme.raised
    font.pixelSize: Theme.size
    palette.window: Theme.raised
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

    property bool running: false
    property var inputs: []
    // Closed: the player comes back.
    signal leaving()

    onClosing: sender.leaving()

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: Theme.gap
        spacing: 16

        ColumnLayout {
            Layout.fillWidth: true
            spacing: 4
            Text {
                text: "只发送"
                font.pixelSize: Theme.sizeLg
                font.weight: Font.DemiBold
                color: Theme.text
            }
            Text {
                Layout.fillWidth: true
                text: "采集 Master，转成识别特征经蓝牙发给投影电脑。这里不放视频，也不建索引。"
                font.pixelSize: Theme.sizeSm
                color: Theme.muted
                wrapMode: Text.Wrap
            }
        }

        SendPanel {
            Layout.fillWidth: true
            running: sender.running
            inputs: sender.inputs
        }

        Item { Layout.fillHeight: true }

        Text {
            Layout.fillWidth: true
            visible: Engine.error.length > 0
            text: Engine.error
            font.pixelSize: Theme.sizeSm
            color: Theme.warn
            wrapMode: Text.Wrap
            MouseArea { anchors.fill: parent; onClicked: Engine.clearError() }
        }

        RowLayout {
            Layout.fillWidth: true
            Text {
                Layout.fillWidth: true
                text: sender.running ? "关闭窗口会停止发送" : ""
                font.pixelSize: Theme.sizeXs
                color: Theme.faint
                elide: Text.ElideRight
            }
            TextButton {
                iconName: "play"
                text: "回到播放器"
                onClicked: sender.close()
            }
        }
    }
}
