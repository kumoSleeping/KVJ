import QtQuick

// A card on the canvas: the raised tone, a hairline edge, gently rounded. The
// desk's regions are cards of one kind, so none stands apart.
Rectangle {
    color: Theme.raised
    radius: Theme.radiusLg
    border.width: 1
    border.color: Theme.line
}
