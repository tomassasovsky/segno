/*
 * engine_prefault.h — the background prefaulter: keeps a capture's buffers
 * faulted in ahead of the audio thread's write head (#900, #906).
 *
 * A take may write a lane's whole recording cap (60 s at 96 kHz is 23 MB, up
 * to 10 min), so faulting all of it in on the control thread before RECORD
 * would delay the take's start by milliseconds per lane, and touching it when
 * the lane is created would cost the RSS #906 removed. So:
 *
 *   - the first LE_PREFAULT_HEAD_SECONDS of every live slot are faulted in
 *     when the slot is created (configure, lane growth), so a take can start
 *     writing at once;
 *   - when a take starts, le_prefault_follow hands the slot to one background
 *     thread, which keeps it faulted in LE_PREFAULT_AHEAD_SECONDS beyond the
 *     write head (the lane's a_len, which is the take's record_pos while it
 *     records) or the existing loop's length, whichever is further, until the
 *     take ends or reaches the cap. Faulting in runs at gigabytes a second
 *     and the write head at one second a second, so the margin only shrinks
 *     if the thread is starved for seconds;
 *   - le_prefault_buffer faults a buffer in whole, in the background, for a
 *     spare that is not needed for a while (a standby shadow, a spare
 *     overdub shadow). Its optional `ready` flag is set when it is done;
 *   - le_prefault_range faults one range in, in the order a write head
 *     entering it at one end reaches it (the rest of a buffer whose first
 *     second around the playhead was faulted in on the press).
 *
 * A new job wakes the thread at once.
 *
 * Only where le_rt_prefault_can_run_concurrently() holds (Linux 5.14+, the
 * mapping path): the thread then never writes from user space, so a buffer
 * freed under it costs nothing. Elsewhere both calls prefault synchronously.
 *
 * Control thread only, except the thread itself. le_prefault_shutdown joins
 * it; le_prefault_clear drops every job (configure, before buffers are freed).
 */
#ifndef SEGNO_ENGINE_PREFAULT_H
#define SEGNO_ENGINE_PREFAULT_H

#include <stdatomic.h>
#include <stdint.h>

#include "segno_engine_api.h"

#ifdef __cplusplus
extern "C" {
#endif

#define LE_PREFAULT_HEAD_SECONDS 1
#define LE_PREFAULT_AHEAD_SECONDS 4

/* Keeps [done_frames, cap_frames) of `buf` faulted in ahead of track
 * `channel`'s recorded length while the track captures or waits to. */
void le_prefault_follow(le_engine* e, int32_t channel, float* buf,
                        int32_t cap_frames, int32_t done_frames);

/* Faults in all of [buf, buf + frames) in the background; stores 1 to
 * `ready` (release) when done, if `ready` is not NULL. */
void le_prefault_buffer(le_engine* e, float* buf, int32_t frames,
                        _Atomic int32_t* ready);

/* Faults in frames [from, to) of `buf` in the background, from `from` up, or
 * with `descending` from `to` down: the order a write head that enters the
 * range at that end reaches it. */
void le_prefault_range(le_engine* e, float* buf, int32_t from, int32_t to,
                       int descending);

/* Starts the thread ahead of the first job, so no take start pays for its
 * creation. le_engine_configure calls it. No-op where it would not run. */
void le_prefault_start(le_engine* e);

/* One pass over the jobs, on the calling thread (the thread's body; tests
 * call it to stay ahead deterministically). */
void le_prefault_tick(le_engine* e);

/* Exactly one pass (one chunk per job), for tests that check the order in
 * which a buffer is faulted in. */
void le_prefault_pass_for_test(le_engine* e);

/* Drops every job whose buffer is `buf` and waits out a chunk of it being
 * faulted: after it returns, nothing faults any part of `buf` again, so the
 * caller may unmap it (le_free_audio_buffer). At most one chunk's wait. */
void le_prefault_forget(le_engine* e, const float* buf);

void le_prefault_clear(le_engine* e);
void le_prefault_shutdown(le_engine* e);

#ifdef __cplusplus
}
#endif

#endif /* SEGNO_ENGINE_PREFAULT_H */
