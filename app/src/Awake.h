#pragma once

// The computer and its screens stay awake (no idle sleep, no screen going dark,
// no App Nap on macOS) while `on`: during a show nobody may touch the computer
// for an hour. Call from the GUI thread.
void stayAwake(bool on);
