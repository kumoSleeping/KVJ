import QtQuick

// A card on the canvas: the raised tone, rounded, flat. Light needs no edge
// (white on grey); dark keeps a faint one. The desk's regions are cards of one
// kind, so none stands apart.
Rectangle {
    color: Theme.raised
    radius: Theme.radiusLg
    border.width: Theme.dark ? 1 : 0
    border.color: Theme.line
}
