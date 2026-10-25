import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import QtQuick.Window
import KVJ

// The window's top bar: on macOS it is the title bar itself, beside the
// window's own keys (`inset` leaves them room) and it moves the window; where
// the system keeps its title bar it sits under it. The name and what is going
// on at the left; at the right the way into the sender and the light or dark
// look.
Rectangle {
    id: top
    color: Theme.raised

    // Room the window's keys take at the left, and the system title bar's
    // height, when the bar stands in for it.
    property real inset: 0
    property real titleHeight: 0
    readonly property bool unified: titleHeight > 0
    // What is going on, in a word or two, and whether it is live.
    property string status: ""
    property bool live: false
    property bool canSend: true

    signal send()

    implicitHeight: unified ? Math.max(32, titleHeight) : 36

    // The bare bar moves the window and zooms it on a double-click, as a title bar does.
    MouseArea {
        anchors.fill: parent
        enabled: top.unified
        onPressed: top.Window.window.startSystemMove()
        onDoubleClicked: {
            const w = top.Window.window
            w.visibility = w.visibility === Window.Maximized ? Window.Windowed : Window.Maximized
        }
    }

    RowLayout {
        anchors.fill: parent
        anchors.leftMargin: top.unified && top.inset > 0 ? top.inset + 14 : 16
        anchors.rightMargin: 8
        spacing: 10

        Text {
            text: "KVJ"
            font.pixelSize: Theme.sizeSm
            font.weight: Font.Bold
            font.letterSpacing: 0.6
            color: Theme.text
        }
        // What is going on: listening, following, projecting.
        Rectangle {
            visible: top.status.length > 0
            implicitWidth: statusText.implicitWidth + 22
            implicitHeight: 20
            radius: 10
            color: Theme.inset
            Rectangle {
                id: dot
                x: 8
                anchors.verticalCenter: parent.verticalCenter
                width: 6
                height: 6
                radius: 3
                color: top.live ? Theme.danger : Theme.muted
                SequentialAnimation on opacity {
                    running: top.live && top.visible
                    loops: Animation.Infinite
                    NumberAnimation { to: 0.35; duration: 700; easing.type: Easing.InOutSine }
                    NumberAnimation { to: 1; duration: 700; easing.type: Easing.InOutSine }
                    onStopped: dot.opacity = 1
                }
            }
            Text {
                id: statusText
                x: 18
                anchors.verticalCenter: parent.verticalCenter
                text: top.status
                font.pixelSize: Theme.sizeXs
                font.weight: Font.Medium
                color: Theme.body
            }
        }
        Item { Layout.fillWidth: true }

        TextButton {
            implicitHeight: 26
            flat: true
            iconName: "send"
            text: "发送端"
            enabled: top.canSend
            ToolTip.visible: hovered
            ToolTip.delay: 600
            ToolTip.text: "这台是 DJ 电脑：收起播放器，打开只采集 Master、经蓝牙发给投影电脑的小窗"
            onClicked: top.send()
        }
        Rectangle {
            implicitWidth: 1
            implicitHeight: 16
            color: Theme.line
        }
        IconButton {
            implicitWidth: 28
            implicitHeight: 26
            iconName: Theme.dark ? "sun" : "moon"
            tip: Theme.dark ? "切换到浅色" : "切换到深色"
            onClicked: Theme.toggle()
        }
    }

    Rectangle {
        anchors.bottom: parent.bottom
        width: parent.width
        height: 1
        color: Theme.line
    }
}
