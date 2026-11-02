#include "Ending.h"

#include <QDeadlineTimer>
#include <QGuiApplication>
#if QT_CONFIG(sessionmanager)
#include <QSessionManager>
#endif

// Until when the session is taken to be ending (expired: it is not).
static QDeadlineTimer ending;

void watchSessionEnd()
{
#if QT_CONFIG(sessionmanager)
    // Windows asks to save first (WM_QUERYENDSESSION), then ends the session
    // (WM_ENDSESSION), where Qt quits and the windows are closed.
    QObject::connect(qGuiApp, &QGuiApplication::commitDataRequest, qGuiApp, [](QSessionManager &) {
        ending.setRemainingTime(120 * 1000);
    });
#endif
}

bool sessionEnding()
{
    // A shut down someone cancels leaves KVJ running: after a while it asks again.
    return !ending.hasExpired();
}
