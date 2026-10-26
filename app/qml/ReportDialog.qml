import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import KVJ

// Report an error to the developer, as in KDJ: describe it, build a scrubbed
// preview of the whole report, read it, agree to send this one report, send.
// Editing the description throws the preview (and the agreement) away.
Popup {
    id: dialog
    // Centred on the window (KVJ's own Overlay type hides Qt's attached one).
    anchors.centerIn: parent
    width: Math.min(760, parent ? parent.width * 0.9 : 760)
    height: Math.min(implicitHeight, parent ? parent.height * 0.85 : 600)
    padding: 18
    modal: true
    focus: true
    closePolicy: busy ? Popup.NoAutoClose : Popup.CloseOnEscape

    property var preview: null
    property bool busy: false
    property string error: ""
    property string sent: ""

    function reset() {
        preview = null
        busy = false
        error = ""
        sent = ""
        agree.checked = false
    }
    onOpened: {
        reset()
        note.text = ""
        note.forceActiveFocus()
    }

    Connections {
        target: Engine
        enabled: dialog.visible
        function onReportReady(preview) {
            dialog.busy = false
            dialog.preview = preview
        }
        function onReportSent(id) {
            dialog.busy = false
            dialog.sent = id
        }
        function onReportFailed(error) {
            dialog.busy = false
            dialog.error = error
        }
    }

    background: Rectangle {
        radius: Theme.radiusLg
        color: Theme.raised
        border.width: 1
        border.color: Theme.line
    }

    contentItem: ColumnLayout {
        spacing: 10
        Text {
            text: "将错误上报至开发者"
            font.pixelSize: Theme.sizeLg
            font.weight: Font.Bold
            color: Theme.text
        }
        Text {
            Layout.fillWidth: true
            text: "仅在确认上传时发送到 bug.kvj.kumo.ltd，保存 30 天。包含最近两天的运行日志、软件版本、系统与 CPU 线程数，不附带素材、Set、设置或蓝牙配对信息。"
            font.pixelSize: Theme.sizeXs
            color: Theme.muted
            wrapMode: Text.Wrap
        }
        Text {
            Layout.fillWidth: true
            text: "已自动隐藏常见凭证、路径（连同素材文件名）、网址、邮箱和 IP；自动脱敏无法保证识别所有私人内容，请核对下方完整报告。Cloudflare 处理连接时仍会接触来源 IP，本收集器不将其存入报告。"
            font.pixelSize: Theme.sizeXs
            color: Theme.muted
            wrapMode: Text.Wrap
        }
        Caption { text: "问题描述" }
        ScrollView {
            Layout.fillWidth: true
            Layout.preferredHeight: 72
            TextArea {
                id: note
                enabled: !dialog.busy && !dialog.sent
                wrapMode: TextArea.Wrap
                placeholderText: "发生了什么、在做什么时出现（可留空）"
                font.pixelSize: Theme.sizeSm
                color: Theme.text
                placeholderTextColor: Theme.faint
                background: Rectangle {
                    radius: Theme.radius
                    color: Theme.inset
                    border.width: 1
                    border.color: note.activeFocus ? Theme.muted : Theme.inset
                }
                onTextChanged: {
                    if (length > 2000)
                        remove(2000, length)
                    if (dialog.preview && !dialog.sent)
                        dialog.reset()
                }
            }
        }
        ScrollView {
            Layout.fillWidth: true
            Layout.fillHeight: true
            Layout.preferredHeight: 280
            visible: !!dialog.preview
            TextArea {
                readOnly: true
                selectByMouse: true
                text: dialog.preview ? dialog.preview.body : ""
                font.family: Qt.platform.os === "windows" ? "Consolas" : "Menlo"
                font.pixelSize: 11
                color: Theme.body
                wrapMode: TextArea.WrapAnywhere
                background: Rectangle { radius: Theme.radius; color: Theme.inset }
            }
        }
        Toggle {
            id: agree
            visible: !!dialog.preview && !dialog.sent
            enabled: !dialog.busy
            text: dialog.preview ? "已核对内容，同意仅上传本次报告（" + Math.ceil(dialog.preview.bytes / 1024) + " KB）" : ""
        }
        Text {
            Layout.fillWidth: true
            visible: !!dialog.error
            text: dialog.error
            font.pixelSize: Theme.sizeSm
            color: Theme.danger
            wrapMode: Text.Wrap
        }
        Text {
            Layout.fillWidth: true
            visible: !!dialog.sent
            text: "上报成功 · " + dialog.sent
            font.pixelSize: Theme.sizeSm
            font.weight: Font.DemiBold
            color: Theme.text
        }
        RowLayout {
            Layout.fillWidth: true
            spacing: 8
            Item { Layout.fillWidth: true }
            TextButton {
                text: dialog.sent ? "完成" : "取消"
                enabled: !dialog.busy
                onClicked: dialog.close()
            }
            TextButton {
                visible: !dialog.sent && !dialog.preview
                primary: true
                text: dialog.busy ? "处理中" : "生成脱敏预览"
                enabled: !dialog.busy
                onClicked: {
                    dialog.error = ""
                    dialog.busy = true
                    Engine.prepareReport(note.text)
                }
            }
            TextButton {
                visible: !dialog.sent && !!dialog.preview
                primary: true
                text: dialog.busy ? "处理中" : "确认上传"
                enabled: agree.checked && !dialog.busy
                onClicked: {
                    dialog.error = ""
                    dialog.busy = true
                    Engine.submitReport(dialog.preview.id)
                }
            }
        }
    }
}
