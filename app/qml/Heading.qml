import QtQuick

// A card's title: the size of the text around it, carried by weight.
Text {
    font.pixelSize: Theme.sizeLg
    font.weight: Font.DemiBold
    color: Theme.text
    elide: Text.ElideRight
}
