#include "Awake.h"

#import <Foundation/Foundation.h>

static id<NSObject> activity;

void stayAwake(bool on)
{
    if (on && !activity) {
        activity = [[NSProcessInfo processInfo]
            beginActivityWithOptions:NSActivityUserInitiated | NSActivityIdleDisplaySleepDisabled | NSActivityLatencyCritical
                              reason:@"KVJ 投放或跟随中"];
    } else if (!on && activity) {
        [[NSProcessInfo processInfo] endActivity:activity];
        activity = nil;
    }
}
