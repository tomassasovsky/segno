/*
 * engine_platform.h — lifecycle hooks the portable core (engine.c) calls at
 * well-defined points; implemented once per OS in engine_<os>.c. Most are no-ops
 * on most platforms — this is a seam for per-OS *capabilities* (CoreAudio
 * channel labels on macOS; JACK port-pinning + PipeWire quantum forcing on
 * Linux; opt-in ASIO on Windows later), not a generic backend vtable.
 *
 * Purely internal: NOT part of the FFI surface (segno_engine_api.h), the Dart
 * loader, or ffigen.
 */
#ifndef SEGNO_ENGINE_PLATFORM_H
#define SEGNO_ENGINE_PLATFORM_H

#include <stddef.h>
#include <stdint.h>

#include "engine_private.h"  /* struct le_engine; le_config re-exported via its
                              * own segno_engine_api.h include */
#include "miniaudio.h"       /* ma_backend, ma_uint32, ma_device_id */

#ifdef __cplusplus
extern "C" {
#endif

/* Backend preference list passed to ma_context_init. Linux returns
 * {jack, pulseaudio, alsa}; macOS/Windows return (NULL, 0) = miniaudio default. */
void le_platform_backends(const ma_backend** out_list, ma_uint32* out_count);

/* Backend list for a TRANSIENT PROBE context (enumeration / loopback detection).
 *
 * NOT the same question as le_platform_backends, and deliberately a separate
 * seam. The streaming list is a PREFERENCE — miniaudio takes the first backend
 * that initialises, so ordering it {jack, pulseaudio, alsa} changes which
 * backend a probe lands on, and a probe on JACK reports one synthetic "Default
 * Playback Device" instead of the host's real cards. A probe must therefore
 * pin only when a backend has to be positively EXCLUDED, never merely preferred.
 *
 * Returns (NULL, 0) — miniaudio's own default backend order, exactly what the
 * probe call sites passed before #721 — everywhere except the one case that
 * needs an exclusion: Linux under SEGNO_ALSA_ONLY, where the appliance ships no
 * PulseAudio server and every attempted Pulse connection leaked a memfd. There
 * it returns {alsa}. macOS/Windows always return (NULL, 0). */
void le_platform_probe_backends(const ma_backend** out_list,
                                ma_uint32* out_count);

/* TEST SEAM. Forces the appliance ALSA-only pin on (1) or off (0), or restores
 * reading it from SEGNO_ALSA_ONLY (any negative value — the default, and the
 * state of every shipping process). No-op on macOS/Windows, which have no pin.
 *
 * It exists because the pin is otherwise unaskable twice: Linux reads the
 * variable once into a function-static and caches it for the process, so a test
 * that wants the other value cannot get it by setting the environment (too
 * late) or by fork()ing (the child inherits the primed cache). Both approaches
 * fail SILENTLY — the assertion still runs, against whichever value happened to
 * be frozen first — which is exactly the kind of green-but-vacuous test this
 * seam replaces.
 *
 * Control thread only, and never called by the engine itself. A test that sets
 * it must restore it. */
void le_platform_set_alsa_only_for_test(int state);

/* Called immediately before ma_context_init. Linux sets PIPEWIRE_QUANTUM and
 * forces the graph quantum via pw-metadata. No-op elsewhere. */
void le_platform_before_context_init(const le_config* config);

/* Called immediately after ma_device_start. Linux pins the JACK ports to the
 * selected device and clamps the published channel count. No-op elsewhere. */
void le_platform_after_device_start(le_engine* engine, const le_config* config);

/* Called after the device is opened but BEFORE it is started, while the audio
 * worker thread exists yet is still idle. Linux promotes that thread to
 * real-time here so it is already SCHED_FIFO when it enters the data loop —
 * doing it after start races the worker's first (deadline-critical) reads at
 * normal priority, overruns the capture, and the recovery leaves audible
 * artifacts. No-op elsewhere. */
void le_platform_after_device_open(le_engine* engine);

/* Called from le_engine_stop and le_engine_destroy. Linux restores PipeWire's
 * dynamic quantum (force-quantum 0). No-op elsewhere. */
void le_platform_on_engine_teardown(void);

/* Excluded-input-channel mask from per-channel labels. macOS reads CoreAudio
 * labels; Windows reads the ASIO driver's channel names (SEGNO_ENABLE_ASIO, via
 * le_win_asio_excluded_mask) — and the ASIO duplex backend computes the same mask
 * directly at open, reported in le_device_open_result.excluded_input_mask, so the
 * core uses that instead of re-probing a live driver. Linux returns 0 (no
 * channel-label source yet; PipeWire port labels are future work). All paths
 * route through the shared le_excluded_mask_from_names / le_label_is_loopback. */
uint32_t le_platform_excluded_input_mask(const char* uid, int channel_count);

/* Platform-native device enumeration, taking precedence over the portable
 * miniaudio (ALSA) path when it succeeds. Returns 1 if it enumerated the host's
 * real interfaces itself — writing up to `max` entries into `out` and the count
 * into *count — or 0 to defer to the miniaudio enumeration. `capture` selects
 * the direction. Linux enumerates via JACK so the list is one entry per real
 * PipeWire/JACK interface (not the ALSA plugin clutter) and each `id` is the
 * JACK client/node name that le_jack_pin_to_device pins by; macOS/Windows return
 * 0 (miniaudio's CoreAudio/WASAPI enumeration is already the right list). */
int le_platform_enumerate_devices(le_device_info* out, int32_t max,
                                  int32_t* count, int capture);

/* Serializes a miniaudio device id into a printable, round-trippable token used
 * to match a user-selected device back to its native id. On the string-id
 * backends (CoreAudio, ALSA, PulseAudio, …) the union's active member is a
 * NUL-terminated char string, so a plain copy is exact. On Windows the device id
 * is a wchar_t string and must be converted to UTF-8 — reading it as a narrow
 * char* stops at the first UTF-16 NUL byte and collapses every id to its first
 * character. Writes at most `cap` bytes including the NUL. */
void le_platform_device_id_to_str(const ma_device_id* id, char* out, size_t cap);

#ifdef __cplusplus
}
#endif

#endif /* SEGNO_ENGINE_PLATFORM_H */
