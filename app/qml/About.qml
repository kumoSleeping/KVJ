import QtCore
import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import KVJ

// Version, software updates, and the logs (open the folder, or report an
// error to the developer). Opens under the top bar's key. Updates are checked
// once at start and every 30 minutes while 自动检测更新 is on; nothing is
// downloaded unasked. 下载并更新 fetches the newer release, checks it and,
// once it is ready, restarts into it after a short countdown, or, while a
// show is on (following, projecting: Engine.keepAwake), only when
// asked again. A build that cannot update itself (a developer's, or one in a
// place KVJ may not write to) says why and opens the download page instead.
Popup {
    id: about
    padding: 14
    width: 320
    modal: false
    focus: true
    // A press on its own key toggles it, not closes-and-reopens it.
    closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutsideParent

    property bool autoCheck: true
    readonly property var update: Engine.update
    readonly property bool newer: !!update && update.newer === true
    readonly property var job: Engine.updateJob
    readonly property string phase: job && job.phase ? job.phase : ""
    readonly property bool fetching: ["downloading", "verifying", "unpacking"].indexOf(phase) >= 0
    readonly property bool ready: phase === "ready"
    // A show is on: nothing restarts unless asked.
    readonly property bool showOn: Engine.keepAwake
    // Seconds left before a ready update restarts KVJ by itself (0: not counting).
    property int countdown: 0
    signal report()

    function megabytes(bytes) { return (bytes / 1e6).toFixed(1) }
    function restart() {
        countdown = 0
        Engine.installUpdate()
    }
    onReadyChanged: {
        if (!ready) {
            countdown = 0
        } else if (!showOn) {
            countdown = 5
            open()
        }
    }
    // A show starting stops the countdown: it waits to be asked.
    onShowOnChanged: if (showOn) countdown = 0
    Timer {
        interval: 1000
        repeat: true
        running: about.countdown > 0
        onTriggered: {
            if (about.countdown <= 1)
                about.restart()
            else
                about.countdown -= 1
        }
    }
    // What the last update did is said once, after the restart.
    readonly property string notice: Engine.updateNotice
    onNoticeChanged: if (notice) open()

    Settings {
        category: "update"
        property alias auto: about.autoCheck
    }
    property bool checkedOnce: false
    Timer {
        // The first check waits a little: start-up has more urgent work.
        interval: about.checkedOnce ? 30 * 60 * 1000 : 4000
        repeat: true
        running: about.autoCheck
        onTriggered: {
            about.checkedOnce = true
            Engine.checkUpdate(true)
        }
    }

    background: Rectangle {
        radius: Theme.radiusLg
        color: Theme.raised
        border.width: 1
        border.color: Theme.line
    }

    contentItem: ColumnLayout {
        spacing: 12
        RowLayout {
            Layout.fillWidth: true
            Text {
                text: "KVJ"
                font.pixelSize: Theme.sizeLg
                font.weight: Font.Bold
                color: Theme.text
            }
            Text {
                Layout.fillWidth: true
                text: "v" + Engine.version
                font.pixelSize: Theme.sizeSm
                font.features: { "tnum": 1 }
                color: Theme.muted
            }
        }

        // Software update.
        ColumnLayout {
            Layout.fillWidth: true
            spacing: 6
            Caption { text: "软件更新" }
            RowLayout {
                visible: !!Engine.updateNotice
                Layout.fillWidth: true
                spacing: 8
                Text {
                    Layout.fillWidth: true
                    text: Engine.updateNotice
                    font.pixelSize: Theme.sizeSm
                    color: Engine.updateNotice.indexOf("没有成功") >= 0 ? Theme.danger : Theme.text
                    wrapMode: Text.Wrap
                }
                TextButton {
                    flat: true
                    text: "知道了"
                    onClicked: Engine.dismissUpdateNotice()
                }
            }
            RowLayout {
                Layout.fillWidth: true
                spacing: 8
                Text {
                    Layout.fillWidth: true
                    text: about.fetching ? (about.phase === "downloading"
                            ? "下载 v" + about.job.version + "　" + about.megabytes(about.job.received) + " / " + about.megabytes(about.job.total) + " MB"
                            : about.phase === "verifying" ? "校验 v" + about.job.version + "…" : "准备 v" + about.job.version + "…")
                        : about.ready ? (about.countdown > 0 ? "v" + about.job.version + " 已就绪，" + about.countdown + " 秒后重启"
                            : about.showOn ? "v" + about.job.version + " 已就绪。正在演出：重启会中断跟随和投影"
                            : "v" + about.job.version + " 已就绪，重启即可完成更新")
                        : about.phase === "installing" ? "正在重启…"
                        : about.phase === "failed" ? "更新失败：" + about.job.error
                        : Engine.checkingUpdate ? "检查中…"
                        : Engine.updateError ? Engine.updateError
                        : about.newer ? "发现新版本 v" + about.update.latest + "（当前 v" + Engine.version + "）"
                            + (about.update.size > 0 ? "，" + about.megabytes(about.update.size) + " MB" : "")
                        : about.update && about.update.current ? "已是最新 v" + Engine.version
                        : "当前 v" + Engine.version
                    font.pixelSize: Theme.sizeSm
                    font.features: { "tnum": 1 }
                    color: about.phase === "failed" || (!about.phase && Engine.updateError) ? Theme.danger
                        : about.newer || about.phase ? Theme.text : Theme.muted
                    wrapMode: Text.Wrap
                }
                TextButton {
                    visible: about.fetching || about.ready
                    flat: true
                    // 稍后 keeps what is ready for a restart whenever wanted.
                    text: about.ready ? "稍后" : "取消"
                    enabled: about.phase !== "unpacking"
                    onClicked: {
                        if (about.ready) {
                            about.countdown = 0
                            about.close()
                        } else {
                            Engine.cancelUpdate()
                        }
                    }
                }
                TextButton {
                    visible: !about.fetching && about.phase !== "installing"
                    primary: about.newer || about.ready
                    text: about.ready ? (about.showOn ? "中断并重启" : "重启并更新")
                        : about.newer && about.update.installable ? (about.phase === "failed" ? "重试" : "下载并更新")
                        : about.newer ? "去下载页"
                        : Engine.checkingUpdate ? "检查中" : "检查更新"
                    enabled: about.ready || about.newer || !Engine.checkingUpdate
                    onClicked: {
                        if (about.ready)
                            about.restart()
                        else if (about.newer && about.update.installable)
                            Engine.downloadUpdate()
                        else if (about.newer)
                            Qt.openUrlExternally(about.update.url)
                        else
                            Engine.checkUpdate(false)
                    }
                }
            }
            // How far the download is.
            Rectangle {
                visible: about.fetching
                Layout.fillWidth: true
                implicitHeight: 4
                radius: 2
                color: Theme.inset
                Rectangle {
                    width: about.job && about.job.total > 0 ? parent.width * Math.min(1, about.job.received / about.job.total) : 0
                    height: parent.height
                    radius: 2
                    color: Theme.text
                }
            }
            // Why this KVJ cannot update itself, or a way around a failed update.
            Text {
                visible: about.newer && !about.fetching && !about.ready
                    && (!about.update.installable || about.phase === "failed")
                Layout.fillWidth: true
                text: !about.update.installable ? about.update.blocked + "。请从下载页手动更新。"
                    : "也可以<a href=\"" + about.update.url + "\">从下载页手动更新</a>"
                textFormat: about.update.installable ? Text.StyledText : Text.PlainText
                linkColor: Theme.text
                onLinkActivated: link => Qt.openUrlExternally(link)
                font.pixelSize: Theme.sizeXs
                color: Theme.muted
                wrapMode: Text.Wrap
            }
            Toggle {
                text: "自动检测更新"
                checked: about.autoCheck
                onToggled: about.autoCheck = checked
                ToolTip.visible: hovered
                ToolTip.delay: 500
                ToolTip.text: "启动时检查一次，之后每 30 分钟静默检查 GitHub；关掉后只保留手动检查。只有点了「下载并更新」才会下载"
            }
        }

        // Logs.
        ColumnLayout {
            Layout.fillWidth: true
            spacing: 6
            Caption { text: "日志" }
            Text {
                Layout.fillWidth: true
                text: "每次监听和跟随都记在日志里（保留两周）。遇到问题可以把脱敏后的日志发给开发者。"
                font.pixelSize: Theme.sizeXs
                color: Theme.muted
                wrapMode: Text.Wrap
            }
            RowLayout {
                Layout.fillWidth: true
                spacing: 8
                TextButton {
                    iconName: "folder-open"
                    text: "打开日志文件夹"
                    onClicked: Qt.openUrlExternally(Engine.fileUrl(Engine.dataDir + "/logs"))
                }
                TextButton {
                    iconName: "send"
                    text: "将错误上报至开发者"
                    onClicked: {
                        about.close()
                        about.report()
                    }
                }
            }
            // Off at every start: it writes a few lines a second.
            Toggle {
                text: "详细日志"
                checked: Engine.detailLog
                onToggled: Engine.detailLog = checked
                ToolTip.visible: hovered
                ToolTip.delay: 500
                ToolTip.text: "记下声学追踪每一轮的得分和耗时，以及画面跟时钟差多少，写进日志文件夹里的 detail-日期.log。每次启动都是关着的"
            }
        }
    }
}
