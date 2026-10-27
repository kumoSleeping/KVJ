import QtCore
import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Controls.impl
import QtQuick.Layouts
import KVJ

// Words for the audience, folded to one line until opened: one field, which
// sends at once as danmaku or words in the middle, or makes a text sticker in
// the middle of the board (`composer`), on the air with it.
ColumnLayout {
    id: bar

    property var composer
    // Open or folded; folded at first.
    property bool open: false
    // The words in the field, at once: scrolling, held at the top or the
    // foot, or large in the middle.
    function send(text) {
        if (bar.mode < 3)
            Live.say(text, "", { mode: ["scroll", "top", "bottom"][bar.mode], size: Live.sizes[bar.size] })
        else
            Live.showCaption(text)
    }
    // The words as a sticker in the middle of the board, chosen, to be moved
    // and sized there; on the air with the board.
    function stick(text) {
        const words = text.trim()
        if (words.length)
            bar.composer.postAt({ kind: "text", text: words, name: words }, 0.5, 0.5)
    }
    property int mode: 0
    property int size: 1

    Settings {
        category: "desk"
        property alias wordMode: bar.mode
        property alias wordSize: bar.size
        property alias wordsOpen: bar.open
    }

    spacing: 6

    // The fold: a press opens or closes it.
    Item {
        Layout.fillWidth: true
        implicitHeight: 24
        Row {
            anchors.verticalCenter: parent.verticalCenter
            spacing: 4
            ColorImage {
                anchors.verticalCenter: parent.verticalCenter
                source: "icons/chevron-right.svg"
                sourceSize: Qt.size(14, 14)
                color: Theme.faint
                rotation: bar.open ? 90 : 0
                Behavior on rotation { NumberAnimation { duration: 120; easing.type: Easing.OutQuad } }
            }
            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: "文字"
                font.pixelSize: Theme.sizeSm
                font.weight: Font.DemiBold
                color: foldArea.containsMouse || bar.open ? Theme.text : Theme.muted
            }
        }
        MouseArea {
            id: foldArea
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: {
                bar.open = !bar.open
                if (bar.open)
                    words.forceActiveFocus()
            }
            ToolTip.visible: containsMouse
            ToolTip.delay: 600
            ToolTip.text: bar.open ? "收起" : "弹幕、居中文字、文字贴图"
        }
    }

    Field {
        id: words
        visible: bar.open
        Layout.fillWidth: true
        placeholderText: bar.mode < 3 ? "回车发弹幕" : "回车居中发出"
        // ⌘ / Ctrl + Enter: a sticker instead.
        Keys.onPressed: event => {
            if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter) && (event.modifiers & Qt.ControlModifier)) {
                bar.stick(text)
                clear()
                event.accepted = true
            }
        }
        onAccepted: {
            if (text.trim().length)
                bar.send(text)
            clear()
        }
    }
    // How the words go at once and how large, on one line (the sizes
    // kept in place, dimmed, for the words in the middle).
    RowLayout {
        visible: bar.open
        Layout.fillWidth: true
        spacing: 0
        Repeater {
            model: ["滚动", "顶部", "底部", "居中"]
            TextButton {
                required property string modelData
                required property int index
                implicitHeight: 24
                // As wide as its word, not a key's usual width: seven fit.
                implicitWidth: implicitContentWidth + leftPadding + rightPadding
                leftPadding: 5
                rightPadding: 5
                font.pixelSize: Theme.sizeXs
                flat: bar.mode !== index
                font.weight: bar.mode === index ? Font.DemiBold : Font.Medium
                text: modelData
                onClicked: bar.mode = index
            }
        }
        Item { Layout.fillWidth: true }
        Repeater {
            model: ["小", "中", "大"]
            TextButton {
                required property string modelData
                required property int index
                implicitHeight: 24
                // As wide as its word, not a key's usual width: seven fit.
                implicitWidth: implicitContentWidth + leftPadding + rightPadding
                leftPadding: 5
                rightPadding: 5
                font.pixelSize: Theme.sizeXs
                enabled: bar.mode < 3
                flat: bar.size !== index
                font.weight: bar.size === index ? Font.DemiBold : Font.Medium
                text: modelData
                onClicked: bar.size = index
            }
        }
    }
    // The two ways up, as keys too.
    RowLayout {
        visible: bar.open
        Layout.fillWidth: true
        spacing: 6
        TextButton {
            Layout.fillWidth: true
            // Half the row each, whatever their words.
            Layout.preferredWidth: 1
            Layout.minimumWidth: 0
            leftPadding: 6
            rightPadding: 6
            implicitHeight: 28
            outlined: true
            iconName: "image"
            text: "贴到画板"
            enabled: words.text.trim().length > 0
            onClicked: {
                bar.stick(words.text)
                words.clear()
            }
            ToolTip.visible: hovered
            ToolTip.delay: 600
            ToolTip.text: "做成文字贴图，贴在画板中间，随投放上屏（" + (Qt.platform.os === "osx" ? "⌘" : "Ctrl+") + "回车）"
        }
        TextButton {
            Layout.fillWidth: true
            // Half the row each, whatever their words.
            Layout.preferredWidth: 1
            Layout.minimumWidth: 0
            leftPadding: 6
            rightPadding: 6
            implicitHeight: 28
            outlined: true
            iconName: "send"
            text: bar.mode < 3 ? "发弹幕" : "居中发出"
            enabled: words.text.trim().length > 0
            onClicked: words.accepted()
            ToolTip.visible: hovered
            ToolTip.delay: 600
            ToolTip.text: "直接发到观众画面（回车）"
        }
    }
}
