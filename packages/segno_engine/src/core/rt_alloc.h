/*
 * rt_alloc.h — the allocator for every buffer the AUDIO THREAD WRITES.
 *
 * Two page faults can stall the SCHED_FIFO callback, and this is where the
 * engine keeps both off it (#900, #906, #1367):
 *
 *   1. COPY-ON-WRITE after a fork. fork() write-protects every private page of
 *      the process, and the first write to each one afterwards faults. Under
 *      PREEMPT_RT that fault takes mmap_lock, a sleeping lock, and waits for
 *      the whole page-table copy: 6.6-9.1 ms on the console for a 512 MB
 *      process (docs/brainstorm/2026-10-19-no-fork-helpers-brainstorm-doc.md).
 *      The app no longer forks (#1373), but code we do not control still can.
 *      So every allocation here is its own anonymous mapping marked
 *      MADV_DONTFORK: fork() skips it and never write-protects it.
 *
 *   2. FIRST TOUCH. A fresh mapping has no pages behind it. The first write to
 *      each page faults one in, which is microseconds when the machine is
 *      quiet and an mmap_lock wait when another thread is mapping memory. So a
 *      buffer is PREFAULTED on the control thread before the audio thread may
 *      write it (le_rt_prefault), and mlockall (engine_platform.h) keeps every
 *      faulted page resident from then on.
 *
 * WHEN TO PREFAULT is the caller's decision, because it trades memory for
 * nothing until the buffer is used. Two patterns, and the engine uses both:
 *
 *   - Written from the start: the le_engine struct (its command, event and
 *     perf-log rings are written every block), the conditioning and latency
 *     scratch, the instrument synth, the capture rings, every FX delay /
 *     echo / reverb ring and octaver buffer, the command payloads the
 *     callback writes back into (prepared FX recipes, bounce bundles). These
 *     use le_rt_alloc_prefaulted at the moment they are created or prepared.
 *
 *   - Written later, maybe never: the lane loop buffers. A lane's slot is
 *     sized to the recording cap (60 s at 96 kHz is 23 MB) when the lane
 *     becomes active, and touching it then cost 623 MB of RSS for 8 tracks x
 *     8 lanes with nothing recorded (#906). These use le_rt_alloc, which
 *     touches nothing, and the control thread calls le_rt_prefault when it
 *     hands a slot to the audio thread for writing: a take or overdub about to
 *     start on the lane, or an overdub shadow being posted
 *     (engine_commands.c, le_track_prefault_capture and le_post_dub_shadows).
 *
 * THE RULE: NEVER FROM THE AUDIO THREAD. mmap, madvise and munmap all take
 * mmap_lock for write, which is the blocking this file exists to avoid. Any
 * other thread may call these: the control thread, and the wet-cache and
 * performance-render workers through le_fx_prepare. The allocator keeps no
 * shared state, so concurrent calls from different threads are safe.
 *
 * FOR NEW AUDIO-THREAD STATE (the FX engine room, #1372 Part 4, and anything
 * after it): allocate per-kind state with le_rt_alloc_prefaulted when the slot
 * is prepared, release it with le_rt_free when it is retired, and never hand
 * one of these pointers to free(). A refused madvise degrades, it does not
 * fail: the buffer is still returned and the refusal is logged once.
 *
 * What this cannot cover, stated so nobody assumes otherwise: the audio
 * thread's own stack (it is written every block and cannot be DONTFORK; glibc's
 * fork child walks the thread descriptor at its top), and buffers allocated by
 * libraries the callback calls into (miniaudio's duplex cache, alsa-lib's plug
 * conversion buffers). A fork still costs those pages one fault each. That
 * residue is why the app must not fork at all (#1373); this file is the
 * backstop that makes a stray fork cost a handful of faults instead of
 * thousands.
 */
#ifndef SEGNO_RT_ALLOC_H
#define SEGNO_RT_ALLOC_H

#include <stddef.h>

/* 1 where the buffers come from the heap instead of their own mappings:
 * AddressSanitizer builds, so its redzones still guard every audio buffer,
 * and Windows, which has no mmap. Such a build has no fork shield; the tests
 * that check the shield skip there. */
#if defined(__SANITIZE_ADDRESS__) || defined(_WIN32)
#define LE_RT_ALLOC_USES_HEAP 1
#elif defined(__has_feature)
#if __has_feature(address_sanitizer)
#define LE_RT_ALLOC_USES_HEAP 1
#endif
#endif
#ifndef LE_RT_ALLOC_USES_HEAP
#define LE_RT_ALLOC_USES_HEAP 0
#endif

#ifdef __cplusplus
extern "C" {
#endif

/* Claims `bytes` of zeroed storage for a buffer the audio thread writes, as
 * its own MADV_DONTFORK mapping on Linux (a plain mapping on macOS, the heap
 * on Windows). No page is touched: the memory costs nothing until it is
 * prefaulted or written. Returns NULL on failure, including bytes == 0. */
void* le_rt_alloc(size_t bytes);

/* le_rt_alloc, then le_rt_prefault over the whole buffer. For buffers the
 * audio thread starts writing as soon as it can see them. */
void* le_rt_alloc_prefaulted(size_t bytes);

/* Faults in every page of [p, p + bytes) for writing, on the calling thread,
 * without changing the content. `p` must point into an le_rt_alloc buffer
 * and the range must lie inside it. Cheap on pages that are already present,
 * so calling it again on a buffer already prefaulted is fine.
 *
 * Linux uses MADV_POPULATE_WRITE (5.14+), which faults the pages in from the
 * kernel without a single user-space store. Elsewhere, or on an older kernel,
 * it adds zero to one byte per page with an atomic read-modify-write, which
 * is also content-preserving if the audio thread is writing the same buffer
 * at the time. */
void le_rt_prefault(const void* p, size_t bytes);

/* Releases a pointer from le_rt_alloc / le_rt_alloc_prefaulted. NULL-safe.
 * Never call free() on one of these, and never call this on a malloc'd one. */
void le_rt_free(void* p);

/* Payload size of a live le_rt_alloc pointer, in bytes (0 for NULL). Each
 * allocation records its own size, so le_rt_free needs only the pointer. */
size_t le_rt_size(const void* p);

/* Touches `bytes` of the CALLING thread's stack below the current frame, so
 * the deepest call the audio callback makes never faults in a stack page.
 * The audio thread calls this itself, once, on its first callback. */
void le_rt_prefault_stack(size_t bytes);

/* TEST SEAM: makes the next allocations behave as if the kernel refused
 * MADV_DONTFORK (the allocation must still succeed). Single-threaded use only;
 * a test that sets it clears it. Inert off Linux. */
void le_rt_set_fork_shield_failure_for_test(int state);

#ifdef __cplusplus
}
#endif

#endif /* SEGNO_RT_ALLOC_H */
