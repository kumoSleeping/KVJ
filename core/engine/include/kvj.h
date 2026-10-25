/* KVJ engine C ABI (core/engine/src/ffi.rs). Every command is one JSON request
 * and one JSON reply: {"ok": ...} or {"error": "..."}. */
#ifndef KVJ_H
#define KVJ_H

#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct KvjEngine KvjEngine;

/* Called on the engine's worker thread with the presented View as JSON. Hand it
 * to the UI thread; never call back into the engine from inside it. */
typedef void (*KvjEventFn)(void *user, const char *json);

KvjEngine *kvj_engine_new(const char *data_dir, KvjEventFn on_event, void *user);
/* Stops any session and waits for its worker; no events arrive afterwards. */
void kvj_engine_free(KvjEngine *engine);
/* Requests: {"cmd":"document"} {"cmd":"edit","revision":n,"edit":{"kind":"create","name":"..."}}
 * {"cmd":"import","set_id":"..","revision":n,"paths":[..]} {"cmd":"devices"}
 * {"cmd":"enable","set_id":"..","entry_ids":[..],"on":true} (also while following)
 * {"cmd":"start","set_id":"..","device":"auto","channel_start":0,"prepare_only":false}
 * {"cmd":"stop"} {"cmd":"status","after_log_id":null}
 * Bluetooth (BLE): {"cmd":"bluetooth_scan"} {"cmd":"bluetooth_listen","on":true}
 * {"cmd":"bluetooth_connect","device":{"id":"..","name":".."}} {"cmd":"bluetooth_disconnect","id":".."}
 * {"cmd":"bluetooth_select","id":".."|null} {"cmd":"send_start","peer":"<id>","device":"auto","channel_start":0}.
 * Free the reply with kvj_string_free. */
char *kvj_call(KvjEngine *engine, const char *request);
void kvj_string_free(char *text);
/* Monotonic milliseconds; a match's clock_at_ms is on this clock. */
double kvj_clock_ms(void);

/* The timeline waveform of a media file: *columns columns, 100 a second, as
 * heights then R, G and B (low, mid, high strengths), one byte per column each.
 * Cached under cache_dir; the first time it decodes the file and blocks for
 * seconds, asking stop(user) now and then (true abandons). Null without audio.
 * Free with kvj_bytes_free(bytes, columns). */
typedef bool (*KvjStopFn)(void *user);
unsigned char *kvj_waveform(const char *path, const char *cache_dir, KvjStopFn stop, void *user, size_t *columns);
void kvj_bytes_free(unsigned char *bytes, size_t columns);

#ifdef __cplusplus
}
#endif

#endif
