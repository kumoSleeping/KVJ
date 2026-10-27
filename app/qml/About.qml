import QtCore
import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import KVJ

// Version, software updates, and the logs (open the folder, or report an
// error to the developer). Opens under the top bar's key. Updates are checked
// once at start and every 30 minutes while 自动检测更新 is on; nothing is ever
// downloaded or installed here: a newer release opens its download page.
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
    signal report()

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
                Layout.fillWidth: true
                spacing: 8
                Text {
                    Layout.fillWidth: true
                    text: Engine.checkingUpdate ? "检查中…"
                        : Engine.updateError ? Engine.updateError
                        : about.newer ? "发现新版本 v" + about.update.latest + "（当前 v" + Engine.version + "）"
                        : about.update && about.update.current ? "已是最新 v" + Engine.version
                        : "当前 v" + Engine.version
                    font.pixelSize: Theme.sizeSm
                    color: about.newer ? Theme.text : Engine.updateError ? Theme.danger : Theme.muted
                    wrapMode: Text.Wrap
                }
                TextButton {
                    primary: about.newer
                    text: about.newer ? "去下载页" : Engine.checkingUpdate ? "检查中" : "检查更新"
                    enabled: about.newer || !Engine.checkingUpdate
                    onClicked: about.newer ? Qt.openUrlExternally(about.update.url) : Engine.checkUpdate(false)
                }
            }
            Toggle {
                text: "自动检测更新"
                checked: about.autoCheck
                onToggled: about.autoCheck = checked
                ToolTip.visible: hovered
                ToolTip.delay: 500
                ToolTip.text: "启动时检查一次，之后每 30 分钟静默检查 GitHub；关掉后只保留手动检查"
            }
        }

        // Logs.
        ColumnLayout {
            Layout.fillWidth: true
            spacing: 6
            Caption { text: "日志" }
            Text {
                Layout.fillWidth: true
                text: "每次监听、跟随和发送都记在日志里（保留两周）。遇到问题可以把脱敏后的日志发给开发者。"
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
        }
    }
}
