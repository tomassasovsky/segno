/*
 * rt_alloc.h — the allocator for every buffer the AUDIO THREAD WRITES.
 *
 * WHERE THE STORAGE COMES FROM IS PART OF THE REAL-TIME CONTRACT, not an
 * implementation detail (#804). Any fork() in the host process write-protects
 * every writable anonymous page of the parent for copy-on-write, and the app
 * forks while it is playing (the Wi-Fi / Bluetooth / update helpers). A
 * SCHED_FIFO callback that then writes such a page pays a CoW fault, and under
 * PREEMPT_RT that fault takes mmap_lock as a SLEEPING lock — so the audio thread
 * blocks in state D behind whichever ordinary thread is mid-fork. Measured on
 * the Pi 5 bench as ~100 faults/s while armed, each able to stall the callback
 * for milliseconds; that is what #804's audible clicks were.
 *
 * This is where that is dealt with, once, for every such buffer: the capture
 * rings (audio_ring.c), the lane loop buffers and the overdub shadow slot
 * (engine.c), the FX delay/echo/reverb rings and the octaver's phase-vocoder
 * buffers (engine_fx.c), and the latency-capture / input-conditioning scratch
 * (engine.c). A buffer the audio thread only READS does not need this — a read
 * fault on a shared CoW page is minor and does not take mmap_lock for write —
 * but everything above is written from the callback.
 *
 * Not an arena and not a pool: one mapping per buffer. The rule is NEVER FROM
 * THE AUDIO THREAD — mmap/madvise/munmap all take mmap_lock and are exactly the
 * blocking the callback exists to avoid. Any other thread may call it, and more
 * than the control thread does: the wet-cache worker (engine_cache.c) and the
 * offline performance renderer (perf_render.c) both reach it through
 * le_fx_prepare on their own threads. Callers are responsible for the buffer's
 * own ownership; the allocator itself keeps no shared state beyond the test
 * seam below.
 */
#ifndef SEGNO_RT_ALLOC_H
#define SEGNO_RT_ALLOC_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Claims `bytes` of zeroed, page-touched storage for a buffer the audio thread
 * writes. Returns NULL on failure (including bytes == 0).
 *
 * On Linux the storage is its own anonymous mapping marked MADV_DONTFORK, so
 * fork() skips the vma outright and never write-protects the parent's pages.
 * Its own mapping rather than a malloc chunk for one reason: MADV_DONTFORK works
 * on a vma, and a malloc'd buffer lives inside [heap] alongside memory the child
 * legitimately inherits. A forked child cannot touch these mappings; nothing
 * does, because every fork in the host process execs immediately.
 *
 * If the kernel refuses the madvise the buffer is still returned: the mapping is
 * perfectly good memory and all that is lost is the fork protection, which puts
 * the build back where the unpatched one was — a performance with occasional
 * dropouts. Failing the allocation instead would fail the ARM or the RECORD, and
 * on an instrument whose whole purpose is capturing a performance, "you cannot
 * record" is a worse outcome than "the recording clicks". It says so on stderr
 * (the journal, on the appliance) so a bench session is never left wondering why
 * the clicks came back.
 *
 * macOS also gets its own mapping (there is no fork shield to apply, but the
 * lifecycle is then identical on every POSIX host, so the tests exercise the
 * code the appliance runs); Windows uses the heap.
 *
 * Either way the pages are touched HERE, on the calling thread, so the audio
 * thread never faults one in on its first lap. That makes the call
 * proportional to `bytes` — about a millisecond per 2 MB on the appliance —
 * which is why it belongs in arm / configure / lazy-prepare and nowhere hotter.
 */
void* le_rt_alloc(size_t bytes);

/* Releases a pointer from le_rt_alloc / le_rt_shrink. NULL-safe, so teardown
 * paths can call it unconditionally. Never call free() on such a pointer, and
 * never call this on a malloc'd one. */
void le_rt_free(void* p);

/* Payload size of a live le_rt_alloc pointer, in bytes (0 for NULL). Exists for
 * the tests; the engine tracks its own capacities.
 *
 * There is deliberately NO realloc here. An mmap-backed buffer cannot be resized
 * in place portably, and the map-new / copy / unmap-old that replaces it hands
 * the caller a window in which the OLD POINTER IS UNMAPPED — a stale reader
 * faults where a realloc'd one merely read stale bytes. Who may still be holding
 * that pointer is the caller's invariant, not the allocator's, so the sequence
 * lives at the one call site that owns the answer (le_lane_shrink_slot). */
size_t le_rt_size(const void* p);

/* TEST SEAM. Forces the fork shield to fail, so the degrade path above can be
 * driven without a kernel that refuses MADV_DONTFORK. Unlike le_rt_alloc this
 * IS single-threaded-only — it is a plain global, so a test that sets it must
 * clear it and must be the only thread allocating meanwhile.
 *
 * Only Linux has a shield to fail, so only there does this change which branch
 * runs; elsewhere it is inert and the test it drives asserts the invariant that
 * survives either way — a shield-less allocation is still usable, zeroed memory.
 * That is the whole contract of degrading rather than refusing. */
void le_rt_set_fork_shield_failure_for_test(int state);

#ifdef __cplusplus
}
#endif

#endif /* SEGNO_RT_ALLOC_H */
