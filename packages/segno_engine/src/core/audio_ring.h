/*
 * audio_ring.h — single-producer/single-consumer lock-free ring for float audio
 * samples.
 *
 * lockfree_ring.h's le_ring stores fixed-size POD commands — the wrong shape for
 * raw audio. le_audio_ring is the audio counterpart: a flat float buffer with the
 * same wait-free push/pop discipline, but with the producer/consumer roles
 * reversed from le_ring — here the AUDIO thread is the producer (the
 * performance-capture taps in engine_process.c push into it) and the control
 * thread is the consumer (perf_drain.c's background drain thread). push_frame
 * writes `n` contiguous floats as one
 * all-or-nothing unit so a stereo/mono capture frame is never torn across a
 * fill/drop boundary: on a full ring it drops the whole frame and returns 0
 * rather than partially writing it.
 *
 * WHERE THE STORAGE COMES FROM IS PART OF THE CONTRACT, not an implementation
 * detail (#804). A capture ring is written by the audio callback, one frame at
 * a time, for the whole length of a take — so on Linux it must not be ordinary
 * malloc memory. Any fork() in the host process write-protects every writable
 * anonymous page of the parent for copy-on-write, and the app forks (`df`,
 * the Wi-Fi/Bluetooth/update helpers) while a capture is armed; the SCHED_FIFO
 * callback then pays a CoW page fault per page as it sweeps the ring, and under
 * PREEMPT_RT that fault takes mmap_lock as a SLEEPING lock, so the audio thread
 * blocks in state D behind whichever ordinary thread is mid-fork.
 * le_audio_ring_alloc is where that is dealt with, once, for every ring.
 */
#ifndef SEGNO_AUDIO_RING_H
#define SEGNO_AUDIO_RING_H

#include <stdatomic.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Fixed-capacity SPSC float ring. `capacity` is a power of two, in SAMPLES (not
 * frames — a stereo capture stores 2 samples per frame); one slot is kept empty
 * to distinguish full from empty, so usable slots == capacity - 1. */
typedef struct le_audio_ring {
  float* buffer;
  size_t capacity; /* power of two */
  size_t mask;     /* capacity - 1 */
  _Atomic size_t head; /* consumer index */
  _Atomic size_t tail; /* producer index (audio thread writes) */
} le_audio_ring;

/* Claims `capacity` samples of storage the ring owns, and initialises `ring`
 * over it. `capacity` must be a power of two and >= 2. Returns 1 on success, 0
 * on invalid arguments or if the storage could not be claimed.
 *
 * On Linux the storage is its own anonymous mapping marked MADV_DONTFORK, so
 * fork() skips the vma outright and never write-protects the parent's pages —
 * see the header note above for why that matters. Everywhere else it is plain
 * malloc, which is what those platforms already had. Either way the pages are
 * touched here, on the CONTROL thread, so the audio thread does not fault them
 * in on its first lap either.
 *
 * Pair with le_audio_ring_release. Rings initialised with le_audio_ring_init
 * over caller-owned memory must NOT be released. */
int le_audio_ring_alloc(le_audio_ring* ring, size_t capacity);

/* Releases storage claimed by le_audio_ring_alloc and zeroes `ring`. A no-op on
 * a zeroed ring, so teardown paths can call it unconditionally. */
void le_audio_ring_release(le_audio_ring* ring);

/* Initialises `ring` to use `buffer` of `capacity` samples. `capacity` must be a
 * power of two and >= 2. Does not allocate; the caller owns `buffer`'s lifetime.
 * Returns 1 on success, 0 on invalid arguments. */
int le_audio_ring_init(le_audio_ring* ring, float* buffer, size_t capacity);

/* Producer side: writes `n` contiguous samples as one all-or-nothing unit, so a
 * stereo/mono capture frame is never split across a fill/drop boundary. Returns
 * 1 if the frame was enqueued, 0 if fewer than `n` slots were free (nothing
 * written — the caller counts this as one dropped frame). Wait-free; never
 * allocates or blocks, so it is safe to call from the audio callback. */
int le_audio_ring_push_frame(le_audio_ring* ring, const float* samples,
                            size_t n);

/* Consumer side: pops up to `max` samples into `out`, returning the count
 * actually popped (0 if the ring is empty). Wait-free. Called from
 * perf_drain.c's background drain thread, never from the audio thread. */
size_t le_audio_ring_pop(le_audio_ring* ring, float* out, size_t max);

#ifdef __cplusplus
}
#endif

#endif /* SEGNO_AUDIO_RING_H */
