import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import QtQuick.Window
import KVJ

// The window's top bar: on macOS it is the title bar itself, beside the
// window's own keys (`inset` leaves them room) and it moves the window; where
// the system keeps its title bar it sits under it. The name, the key of the
// Sets' drawer and what is going on at the left; at the right the way into the
// sender and the light or dark look. (No name: the window is KVJ.)
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
    // The library drawer: out or not; its key comes first in the bar.
    property bool drawerOpen: false
    // 单轨 (only 画面 1) or two tracks; its key comes next.
    property bool singleTrack: false

    signal send()
    signal toggleDrawer()
    signal toggleSingle()

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

        // The library's drawer, right after the window's own keys (on
        // Windows, at the top left). Files dragged onto it bring it out.
        IconButton {
            implicitWidth: 28
            implicitHeight: 24
            iconSize: 15
            iconName: "panel-left"
            active: top.drawerOpen
            tip: (top.drawerOpen ? "收起素材" : "素材") + "（" + (Qt.platform.os === "osx" ? "⌘B" : "Ctrl+B") + "）"
            onClicked: top.toggleDrawer()
            DropArea {
                anchors.fill: parent
                onEntered: drag => {
                    drag.accepted = false
                    if (!top.drawerOpen)
                        top.toggleDrawer()
                }
            }
        }
        // 单轨 or 双轨: the timeline's rows and the board's sources.
        IconButton {
            Layout.leftMargin: -6
            implicitWidth: 28
            implicitHeight: 24
            iconSize: 15
            iconName: top.singleTrack ? "rectangle-horizontal" : "rows-2"
            active: top.singleTrack
            tip: top.singleTrack ? "单轨：只用画面 1 · 点一下回到两条轨道"
                                 : "两条轨道 · 点一下切到单轨（画面 2 停下、移出画面，轨道上的视频保留）"
            onClicked: top.toggleSingle()
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
        Item { implicitWidth: 4 }
        // Version, updates and logs; a dot when a newer release is out.
        IconButton {
            id: aboutKey
            implicitWidth: 28
            implicitHeight: 26
            iconName: about.newer ? "circle-arrow-up" : "info"
            tip: about.newer ? "有新版本 v" + Engine.update.latest + " 待下载" : "关于 · 更新 · 日志"
            active: about.visible
            onClicked: about.visible ? about.close() : about.open()
            Rectangle {
                visible: about.newer
                x: parent.width - 9
                y: 3
                width: 7
                height: 7
                radius: 3.5
                color: Theme.text
                border.width: 1.5
                border.color: Theme.raised
            }
            About {
                id: about
                x: aboutKey.width - width
                y: aboutKey.height + 6
                onReport: report.open()
            }
        }
        IconButton {
            implicitWidth: 28
            implicitHeight: 26
            iconName: Theme.dark ? "sun" : "moon"
            tip: Theme.dark ? "切换到浅色" : "切换到深色"
            onClicked: Theme.toggle()
        }
    }

    ReportDialog {
        id: report
        parent: top.Window.window ? top.Window.window.contentItem : top
    }
}
