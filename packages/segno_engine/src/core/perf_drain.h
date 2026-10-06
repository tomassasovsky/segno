/*
 * perf_drain.h — the performance-recording capture-to-disk subsystem (part 2
 * of the DAW-export stack).
 *
 * A dedicated background thread — spawned by le_perf_arm, joined by
 * le_perf_disarm — that drains part 1's capture rings (audio_ring.h) into
 * ordered 32-bit float WAV parts per stream plus a `performance.json`
 * sidecar, flushing every ~250 ms (#1198; the format is described above
 * le_perf_target in segno_engine_api.h). A part's header carries zero sizes
 * until the part is sealed, so a crash mid-capture leaves whole-frame float
 * payloads after a fixed 84-byte header plus a parseable sidecar.
 *
 * It runs at a below-normal, explicitly non-inherited scheduling priority and
 * its steady-state cycle performs NO heap allocation — not because either was
 * shown to cause an audible artifact (#722 investigated exactly that and the
 * allocator mechanism did not survive measurement), but because a background
 * writer sharing a machine with a real-time audio callback should hold no
 * allocator lock and outrank nothing. See perf_drain.c's header for what was
 * measured and the invariant to preserve when changing that loop.
 *
 * Lifecycle sibling of the plugin scan thread (host/plugin_scan.cpp), but
 * this one is plain C (no SDK dependency) so it lives in core/ alongside the
 * rest of the engine. Thread ownership: engine_commands.c's le_perf_arm/
 * disarm are the only callers; this module never touches the audio thread or
 * the command ring (a background thread pushing commands would be a second
 * producer on the control thread's SPSC ring — never done here).
 */
#ifndef SEGNO_PERF_DRAIN_H
#define SEGNO_PERF_DRAIN_H

#include <stdint.h>

#include "segno_engine_api.h" /* le_perf_target */

#ifdef __cplusplus
extern "C" {
#endif

typedef struct le_engine le_engine; /* opaque; full definition in engine_private.h */

/* Opaque drain-thread handle, one per armed capture session. */
typedef struct le_perf_drain le_perf_drain;

/* Why a capture session ended, recorded in the sidecar's `stopped_early`
 * field (absent on a normal disarm — only le_perf_arm/disarm's own bookkeeping
 * needs `finalized`, still false in this slice either way). */
typedef enum le_perf_stop_reason {
  LE_PERF_STOP_DISARM = 0,         /* a normal, caller-requested disarm */
  LE_PERF_STOP_DEVICE_CHANGED = 1, /* engine reconfigure while armed */
} le_perf_stop_reason;

/* Starts the drain thread for `engine`'s just-armed perf capture: creates
 * the target's capture (and live-sidecar) directory if missing, opens the
 * first part of the master and of every captured input, and begins the
 * drain-flush-sleep loop. `target` is copied (its strings need not outlive the
 * call); `ring_seconds` is what the arm granted, reported in the sidecar. Returns the handle, or
 * NULL on failure (directory could not be created, or the thread could not be
 * spawned) — the caller must not proceed to arm without a working drain
 * thread. Call once per capture session, after the ring set is published
 * (i.e. after LE_CMD_PERF_ARM is pushed) so the rings the drain thread reads
 * are already valid. */
le_perf_drain* le_perf_drain_start(le_engine* engine,
                                   const le_perf_target* target,
                                   int32_t ring_seconds);

/* Signals the drain thread to run one final drain-and-flush pass — which
 * also seals every open part — and stop, then joins it and frees `drain`. `reason` is recorded in the final sidecar
 * flush's `stopped_early` field UNLESS the thread already self-stopped for
 * its own reason (a disk-full write failure) — that reason always wins, since
 * the thread reached it first. Safe to call on a thread that already
 * self-stopped early — the join simply reaps it. `drain` must not be used
 * again afterward. No-op on NULL. */
void le_perf_drain_stop(le_perf_drain* drain, le_perf_stop_reason reason);

#ifdef __cplusplus
}
#endif

#endif /* SEGNO_PERF_DRAIN_H */
