pragma Singleton
import QtCore
import QtQuick

// KDJ's design tokens (src/design.css): neutral ink on quiet surfaces, dark or
// light as the operator chooses with the key at the top right (the system's
// until then). The window is one plain ground (`bg`, the same tone as what
// floats over it, `raised`): no boxes of another tone, the keys drawn
// straight on it, a hairline (`line`) or space keeping regions apart; the
// controls' own plates (`inset`) are barely off it. Red only for what is about to cut the projected picture.
QtObject {
    id: theme

    // "dark", "light", or "" to follow the system.
    property string scheme: ""
    // `--look light|dark` at start shows that look without keeping it (for
    // snapshots).
    readonly property string forced: {
        const args = Qt.application.arguments
        const at = args.indexOf("--look")
        return at >= 0 && at + 1 < args.length ? args[at + 1] : ""
    }
    readonly property bool systemDark: Qt.styleHints.colorScheme !== Qt.ColorScheme.Light
    readonly property bool dark: forced ? forced === "dark" : scheme === "dark" || (scheme === "" && systemDark)
    function toggle() {
        scheme = dark ? "light" : "dark"
    }
    property Settings store: Settings {
        category: "look"
        property alias scheme: theme.scheme
    }

    readonly property color bg: dark ? "#14171d" : "#ffffff"
    readonly property color raised: dark ? "#14171d" : "#ffffff"
    readonly property color inset: dark ? "#1a1e25" : "#f6f6f8"
    readonly property color text: dark ? "#e4e7ec" : "#1c1c1e"
    readonly property color body: dark ? "#c3c8d0" : "#3a3a3c"
    readonly property color muted: dark ? "#8b929c" : "#6e6e73"
    readonly property color faint: dark ? "#5c636d" : "#a1a1a6"
    readonly property color line: dark ? "#262b33" : "#e6e6ea"
    readonly property color hover: dark ? "#20252d" : "#efeff2"
    // A chosen row: a touch deeper than hover.
    readonly property color selected: dark ? "#262c35" : "#e8e8ed"
    readonly property color warn: "#f59e0b"
    readonly property color danger: "#e5484d"
    // Under what floats over the canvas (the Sets drawer, popups).
    readonly property color shadow: dark ? "#8c000000" : "#24000000"

    readonly property int size: 14
    readonly property int sizeSm: 13
    readonly property int sizeXs: 12
    readonly property int sizeLg: 15
    readonly property int row: 34
    readonly property int control: 30
    readonly property int radius: 7
    readonly property int radiusLg: 12
    readonly property int gap: 12
    readonly property int pad: 14
    // Motion: a press or hover answers at once, a panel moves in a breath.
    readonly property int quick: 160
    readonly property int calm: 360
}
