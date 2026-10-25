// macOS: a transparent title bar over content that fills the whole window, so
// the window's top bar shares its row with the close, minimise and zoom keys.

#include "../../TitleBar.h"

#include <QGuiApplication>
#include <QWindow>

#import <AppKit/AppKit.h>

TitleBarInset unifyTitleBar(QWindow *window)
{
    // Only a Cocoa window has an NSView behind it (not, say, an offscreen one).
    if (QGuiApplication::platformName() != QLatin1String("cocoa"))
        return {};
    NSView *view = (__bridge NSView *)reinterpret_cast<void *>(window->winId());
    NSWindow *ns = view.window;
    if (!ns)
        return {};
    ns.styleMask |= NSWindowStyleMaskFullSizeContentView;
    ns.titlebarAppearsTransparent = YES;
    ns.titleVisibility = NSWindowTitleHidden;
    if (@available(macOS 11.0, *))
        ns.titlebarSeparatorStyle = NSTitlebarSeparatorStyleNone;
    TitleBarInset inset;
    if (NSButton *zoom = [ns standardWindowButton:NSWindowZoomButton])
        inset.left = NSMaxX([zoom convertRect:zoom.bounds toView:nil]);
    inset.height = NSHeight(ns.frame) - NSHeight(ns.contentLayoutRect);
    // Near the right end of the title bar's row, where the top bar's keys are.
    const NSPoint point = NSMakePoint(NSWidth(ns.frame) - 40, NSHeight(ns.frame) - inset.height / 2);
    NSView *hit = [ns.contentView.superview hitTest:point];
    inset.reachesContent = hit && (hit == ns.contentView || [hit isDescendantOf:ns.contentView]);
    return inset;
}
