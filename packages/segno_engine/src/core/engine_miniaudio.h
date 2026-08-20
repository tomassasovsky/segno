/*
 * engine_miniaudio.h — the miniaudio device backend (le_device_backend.h).
 *
 * Exposes the cross-platform device backend (Core Audio on macOS, ALSA/etc. on
 * Linux): it owns the miniaudio device lifecycle (context init, pin/loopback
 * resolution, ma_device_init/start/uninit, and the data / notification
 * callbacks) behind the le_device_backend vtable. The portable core (engine.c)
 * drives it through le_select_backend and never touches ma_device_* directly.
 *
 * Purely internal: NOT part of the FFI surface (segno_engine_api.h) or ffigen.
 */
#ifndef SEGNO_ENGINE_MINIAUDIO_H
#define SEGNO_ENGINE_MINIAUDIO_H

#include <stdint.h>

#include "le_device_backend.h"

#ifdef __cplusplus
extern "C" {
#endif

/* The miniaudio device backend. Returned by le_select_backend for every backend
 * choice in this build (no ASIO backend exists yet). */
extern const le_device_backend le_miniaudio_backend;

/* Resolves the SEGNO_ALSA_PERIODS env value (the raw string, or NULL when the
 * variable is unset) to the period count to use. Unset/empty keeps `fallback`;
 * anything else is parsed and CLAMPED into [2, 8], with a stderr line whenever
 * the value had to be clamped (#736: an ignored out-of-range value used to fall
 * back to 2 — the shallowest buffer, the opposite of what the operator asked
 * for). Pure apart from the log line, so the clamp is testable on every host
 * even though the only call site is Linux-gated. */
uint32_t le_alsa_periods_from_env(const char* value, uint32_t fallback);

#ifdef __cplusplus
}
#endif

#endif /* SEGNO_ENGINE_MINIAUDIO_H */
