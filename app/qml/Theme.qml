pragma Singleton
import QtQuick

// KDJ's design tokens (src/design.css): neutral ink on the panel colour, dark by
// default for the DJ booth, light when the system asks for it. No red anywhere.
QtObject {
    readonly property bool dark: Qt.styleHints.colorScheme !== Qt.ColorScheme.Light

    readonly property color bg: dark ? "#0d1117" : "#ffffff"
    readonly property color raised: dark ? "#151b23" : "#f7f7f8"
    readonly property color inset: dark ? "#010409" : "#ffffff"
    readonly property color text: dark ? "#d1d7e0" : "#1c1c1e"
    readonly property color body: dark ? "#c9d1d9" : "#3a3a3c"
    readonly property color muted: dark ? "#9198a1" : "#6e6e73"
    readonly property color faint: dark ? "#656c76" : "#8e8e93"
    readonly property color line: dark ? "#30363d" : "#e5e7eb"
    readonly property color hover: dark ? "#1a212b" : "#efeff1"
    readonly property color warn: "#f59e0b"

    readonly property int size: 14
    readonly property int sizeSm: 13
    readonly property int sizeXs: 12
    readonly property int sizeLg: 16
    readonly property int row: 36
    readonly property int control: 30
    readonly property int radius: 6
    readonly property int gap: 16
}
