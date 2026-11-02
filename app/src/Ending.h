#pragma once

// The computer is logging out, restarting or shutting down. KVJ then quits
// without asking (Main.qml's onClosing): a question would hold the logout up,
// and on macOS a window that refuses to close cancels it. Call from the GUI
// thread; watchSessionEnd() once, after the application object exists.
void watchSessionEnd();
bool sessionEnding();
