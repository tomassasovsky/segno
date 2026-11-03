/*
 * rt_alloc.h — the allocator for every buffer the AUDIO THREAD WRITES.
 *
 * Three things can make the SCHED_FIFO callback take a page fault on memory
 * it writes, and this is where the engine keeps each of them off it (#900,
 * #906, #1367):
 *
 *   1. COPY-ON-WRITE after a fork. fork() write-protects every private page of
 *      the process, and the first write to each one afterwards faults. Under
 *      PREEMPT_RT that fault takes mmap_lock, a sleeping lock, and waits for
 *      the whole page-table copy: 6.6-9.1 ms on the console for a 512 MB
 *      process (docs/brainstorm/2026-10-19-no-fork-helpers-brainstorm-doc.md).
 *      THE PRIMARY PROTECTION IS THAT THE APP DOES NOT FORK (#1373: helpers
 *      start with posix_spawn). This is the backstop for code we do not
 *      control: every allocation here is its own anonymous mapping marked
 *      MADV_DONTFORK, so fork() skips it and never write-protects it.
 *
 *   2. FIRST TOUCH. A fresh mapping has no pages behind it, and the first
 *      write to each page faults one in. So a buffer is PREFAULTED on the
 *      control thread before the audio thread may write it (le_rt_prefault),
 *      or kept faulted in ahead of the write head by the background
 *      prefaulter (engine_prefault.h).
 *
 *   3. RECLAIM. Each mapping is locked on fault (mlock2 MLOCK_ONFAULT): a page
 *      the audio thread has touched stays in RAM until the buffer is freed.
 *      Only the engine's own memory is locked, never the process: the Dart VM
 *      and glibc's arenas hand memory back with MADV_DONTNEED, which the
 *      kernel refuses on locked memory.
 *
 * WHEN TO PREFAULT is the caller's decision, because it costs memory and
 * control-thread time for nothing until the buffer is used:
 *
 *   - Written from the start (the le_engine struct and its rings, the
 *     conditioning and latency scratch, the instrument synth, the capture
 *     rings, every FX ring and octaver buffer, the command payloads the
 *     callback writes back into): le_rt_alloc_prefaulted, when created or
 *     prepared.
 *   - Written later, maybe never (the lane loop buffers, 23 MB per slot at
 *     96 kHz / 60 s): le_rt_alloc, which touches nothing, and the control
 *     thread prefaults where engine_commands.c says ("prefaulting what the
 *     audio thread writes").
 *
 * THE RULE: NEVER FROM THE AUDIO THREAD. mmap, madvise, mlock2 and munmap all
 * take mmap_lock for write, which is the blocking this file exists to avoid.
 * Any other thread may call these; the allocator keeps no shared state.
 *
 * FOR NEW AUDIO-THREAD STATE: allocate it with le_rt_alloc_prefaulted on the
 * control thread when its owner is prepared, sized for what that owner holds
 * (an FX slot's per-kind block is one allocation per kind the slot has held,
 * #1421), and release it with le_rt_free once the audio thread can no longer
 * reach it. Never hand one of these pointers to free().
 *
 * What this cannot cover, stated so nobody assumes otherwise. These are
 * covered by the app not forking (#1373), and locked or prefaulted only where
 * noted:
 *   - the audio thread's own stack: it cannot be DONTFORK (glibc's fork child
 *     walks the thread descriptor at its top). Its top 320 KB is faulted in
 *     and locked before the device starts (engine_linux.c);
 *   - buffers that libraries the callback calls into allocate themselves
 *     (miniaudio's duplex cache, alsa-lib's plug conversion buffers): plain
 *     heap. libasound's code and data are faulted in and locked at device
 *     start;
 *   - hosted plugins (macOS only today, off on the appliance): the slot's
 *     vectors, the plugin's own heap and its binary are neither shielded nor
 *     prefaulted.
 */
#ifndef SEGNO_RT_ALLOC_H
#define SEGNO_RT_ALLOC_H

#include <stddef.h>

/* 1 where the buffers come from the heap instead of their own mappings:
 * AddressSanitizer builds, so its redzones still guard every audio buffer,
 * and Windows, which has no mmap. Such a build has no fork shield or lock;
 * the tests that check them skip there. */
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
 * its own MADV_DONTFORK, locked-on-fault mapping on Linux (a plain mapping on
 * macOS, the heap under ASan). No page is touched: the memory costs nothing
 * until it is prefaulted or written. Returns NULL on failure, including
 * bytes == 0. A refused madvise or mlock2 degrades and is logged once. */
void* le_rt_alloc(size_t bytes);

/* le_rt_alloc, then le_rt_prefault over the whole buffer. For buffers the
 * audio thread starts writing as soon as it can see them. */
void* le_rt_alloc_prefaulted(size_t bytes);

/* Faults in every page of [p, p + bytes) for writing, on the calling thread,
 * without changing the content. `p` must point into an le_rt_alloc buffer
 * and the range must lie inside it. Cheap on pages that are already present.
 *
 * Linux 5.14+ uses MADV_POPULATE_WRITE, which faults the pages in from the
 * kernel without a single user-space store. Elsewhere it adds zero to one
 * byte per page with an atomic read-modify-write, which is also
 * content-preserving if the audio thread writes the same buffer meanwhile. */
void le_rt_prefault(const void* p, size_t bytes);

/* 1 when le_rt_prefault never stores from user space (the MADV_POPULATE_WRITE
 * path), so it may run on another thread over a buffer the control thread
 * might free meanwhile: a stale range then costs nothing. The background
 * prefaulter (engine_prefault.h) runs only then. */
int le_rt_prefault_can_run_concurrently(void);

/* Releases a pointer from le_rt_alloc / le_rt_alloc_prefaulted. NULL-safe.
 * The header in front of the payload is checked first: a damaged one (an
 * underflow) is reported and the buffer leaked, never unmapped at a guessed
 * length. Never call free() on one of these, nor this on a malloc'd one. */
void le_rt_free(void* p);

/* Payload size of a live le_rt_alloc pointer, in bytes (0 for NULL or a
 * damaged header). */
size_t le_rt_size(const void* p);

/* Shrinks a live le_rt_alloc buffer to its first `bytes` in place: the same
 * pointer, the content kept, the pages past the new end unmapped (so their
 * memory and lock are released at once, with no copy). No-op unless `bytes`
 * is smaller than the current size and not zero. Nothing may be touching
 * the range given back. */
void le_rt_shrink(void* p, size_t bytes);

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
