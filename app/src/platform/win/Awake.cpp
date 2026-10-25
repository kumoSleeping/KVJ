#include "Awake.h"

#include <windows.h>

void stayAwake(bool on)
{
    // Held by this (the GUI) thread until it is called again without them.
    SetThreadExecutionState(on ? ES_CONTINUOUS | ES_SYSTEM_REQUIRED | ES_DISPLAY_REQUIRED : ES_CONTINUOUS);
}
