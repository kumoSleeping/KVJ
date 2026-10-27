import QtQuick

// A region of the canvas. The canvas is one plain ground, so a card draws no
// box of its own: it only holds its content (and its radius, for what clips).
Rectangle {
    color: "transparent"
    radius: Theme.radiusLg
}
