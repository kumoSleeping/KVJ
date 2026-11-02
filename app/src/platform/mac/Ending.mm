#include "Ending.h"

#import <AppKit/AppKit.h>
#import <CoreServices/CoreServices.h>

// When the workspace said it is powering off (logout, restart, shut down).
static NSDate *poweringOff;

void watchSessionEnd()
{
    [[NSWorkspace sharedWorkspace].notificationCenter addObserverForName:NSWorkspaceWillPowerOffNotification
                                                                  object:nil
                                                                   queue:[NSOperationQueue mainQueue]
                                                              usingBlock:^(NSNotification *) {
                                                                  poweringOff = [NSDate date];
                                                              }];
}

bool sessionEnding()
{
    // A logout another app cancels leaves KVJ running: after a while it asks again.
    if (poweringOff && -poweringOff.timeIntervalSinceNow < 120)
        return true;
    // Cmd+Q and the Dock's 退出 send no reason; the system's quit says why
    // (log out, restart, shut down). Qt closes the windows from inside it.
    NSAppleEventDescriptor *event = [NSAppleEventManager sharedAppleEventManager].currentAppleEvent;
    if (!event || event.eventClass != kCoreEventClass || event.eventID != kAEQuitApplication)
        return false;
    return [event paramDescriptorForKeyword:kAEQuitReason] || [event attributeDescriptorForKeyword:kAEQuitReason];
}
