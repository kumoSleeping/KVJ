pragma Singleton
import QtCore
import QtQuick

// KDJ's design tokens (src/design.css): neutral ink on quiet surfaces, dark or
// light as the operator chooses with the key at the top right (the system's
// until then). The window is a canvas of cards: the canvas (`bg`), the cards
// and side bars on it (`raised`), the controls in them (`inset`). Red only for
// what is about to cut the projected picture.
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

    readonly property color bg: dark ? "#0b0d11" : "#f2f2f4"
    readonly property color raised: dark ? "#14171d" : "#ffffff"
    readonly property color inset: dark ? "#1c2027" : "#f0f0f3"
    readonly property color text: dark ? "#e4e7ec" : "#1c1c1e"
    readonly property color body: dark ? "#c3c8d0" : "#3a3a3c"
    readonly property color muted: dark ? "#8b929c" : "#6e6e73"
    readonly property color faint: dark ? "#5c636d" : "#a1a1a6"
    readonly property color line: dark ? "#262b33" : "#e3e3e8"
    readonly property color hover: dark ? "#20252d" : "#ebebef"
    // A chosen row: a touch deeper than hover.
    readonly property color selected: dark ? "#262c35" : "#e6e6eb"
    readonly property color warn: "#f59e0b"
    readonly property color danger: "#e5484d"

    readonly property int size: 14
    readonly property int sizeSm: 13
    readonly property int sizeXs: 12
    readonly property int sizeLg: 15
    readonly property int row: 34
    readonly property int control: 30
    readonly property int radius: 6
    readonly property int radiusLg: 8
    readonly property int gap: 12
    readonly property int pad: 14
}
