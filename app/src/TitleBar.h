#pragma once

class QWindow;

// The window's own top bar in place of the system's title bar where the system
// allows it (macOS): the content runs up under a transparent title bar, beside
// the window's buttons. Elsewhere the system's title bar stays and the top bar
// sits under it.
struct TitleBarInset
{
    // Room the window's buttons take at the left, and the title bar's height,
    // in logical pixels; both 0 where the system's title bar stays.
    double left = 0;
    double height = 0;
    // A press in the title bar's row reaches the window's content (its keys
    // there work), as checked once at the start.
    bool reachesContent = false;
};
TitleBarInset unifyTitleBar(QWindow *window);
