#include "rt_alloc.h"

#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#if !defined(_WIN32)
#include <sys/mman.h>
#endif

/* Every allocation carries its own size, so le_rt_free / le_rt_shrink need only
 * the pointer — munmap needs a length, and threading one through ~30 call sites
 * (each holding the size in a different unit: frames, samples, channels) is how
 * a mismatched-length unmap gets written.
 *
 * One cache line, so on the mmap path — every POSIX host, which is every host
 * that runs the audio engine — the base is page-aligned and the payload comes
 * out 64-byte aligned. NOT a portable guarantee: the Windows branch below is
 * plain malloc, whose 16-byte alignment plus 64 is still only 16. Nothing in
 * the DSP needs more than that today (the kernels are scalar float loops), so
 * this buys cache-line behaviour where it is free rather than an invariant
 * anything depends on. A future SIMD path that DOES require 64 has to switch
 * the _WIN32 branch to _aligned_malloc/_aligned_free first. */
#define LE_RT_HEADER 64u

static int g_shield_fail_override = 0;
#if defined(__linux__)
/* see le_rt_fork_shield: at most one refusal line per process. Linux-only,
 * because only Linux has a shield that can be refused — declaring it
 * unconditionally is an unused variable everywhere else. */
static int g_shield_warned = 0;
#endif

void le_rt_set_fork_shield_failure_for_test(int state) {
  g_shield_fail_override = state;
}

/* Marks a fresh mapping VM_DONTCOPY so fork() skips the vma. See rt_alloc.h for
 * why that is a real-time property and not a micro-optimisation, and why a
 * refusal degrades instead of failing the allocation. */
static void le_rt_fork_shield(void* base, size_t total) {
#if defined(__linux__)
  if (!g_shield_fail_override && madvise(base, total, MADV_DONTFORK) == 0) {
    return;
  }
  if (g_shield_fail_override) {
    /* Forced by the test seam. Reported EVERY time and deliberately outside
     * the latch below: a test that drives the degrade path must not consume
     * the one report a genuine kernel refusal owns for the rest of the
     * process — that is what turns "no refusal line in the suite output" into
     * evidence that every other allocation really was shielded. Its own
     * wording, too, so the journal can never confuse the two. */
    fprintf(stderr,
            "segno/rt_alloc: fork shield forced to fail by the test seam for "
            "this %zu-byte buffer; the allocation still succeeds (#804)\n",
            total);
    return;
  }
  /* ONCE PER PROCESS. A kernel that refuses MADV_DONTFORK refuses it for every
   * buffer, and this seam is now on the path of every audio-thread buffer, not
   * just the capture rings — hundreds of allocations per session. The appliance
   * never rotates segno.log, so an unlatched line here would fill the partition
   * to say one thing over and over. The first one carries the diagnosis; the
   * condition is process-wide, so the repeats carry nothing.
   *
   * A plain flag, not an atomic: two threads racing here print the line twice,
   * which is harmless, and the alternative is an atomic on the allocation path
   * to make a log line exact. */
  if (g_shield_warned) return;
  g_shield_warned = 1;
  fprintf(stderr,
          "segno/rt_alloc: MADV_DONTFORK refused (errno %d); this %zu-byte "
          "buffer — and every later one — is copy-on-write, and every fork "
          "will cost the audio thread a fault per page (#804). Reported once "
          "per process.\n",
          errno, total);
#else
  /* No fork shield off Linux: MADV_DONTFORK is a Linux advice, and neither
   * macOS nor Windows runs the PREEMPT_RT kernel whose sleeping mmap_lock turns
   * a CoW fault into an audio stall. The mapping is otherwise identical, so
   * those platforms permanently — and silently — take the degrade path;
   * warning once per buffer about a hazard they do not have would be noise. */
  (void)base;
  (void)total;
#endif
}

/* The one mapping routine. `prefault` writes every page on the calling thread;
 * see the two public entry points below for when that is the point and when it
 * is pure waste. */
static void* le_rt_map(size_t bytes, int prefault) {
  if (bytes == 0 || bytes > SIZE_MAX - LE_RT_HEADER) return NULL;
  const size_t total = bytes + LE_RT_HEADER;
  unsigned char* base = NULL;
#if defined(_WIN32)
  base = (unsigned char*)malloc(total);
  if (base == NULL) return NULL;
  /* malloc has no untouched-page notion to skip, and its bytes are
   * indeterminate rather than zero, so Windows always clears. `prefault` is a
   * permission to skip work, never a promise of garbage. */
  (void)prefault;
  memset(base, 0, total);
#else
  void* mapped = mmap(NULL, total, PROT_READ | PROT_WRITE,
                      MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
  if (mapped == MAP_FAILED) return NULL;
  le_rt_fork_shield(mapped, total);
  base = (unsigned char*)mapped;
  /* Touch every page HERE, on the calling (non-audio) thread. mmap hands back
   * untouched pages, and the first pass over a fresh buffer would otherwise be
   * faulted in by the audio callback one page at a time. The kernel already
   * guarantees the CONTENT is zero; this pass buys the residency, which is why
   * a caller that is about to overwrite the whole buffer itself can skip it. */
  if (prefault) memset(base, 0, total);
#endif
  memcpy(base, &bytes, sizeof(bytes));
  return base + LE_RT_HEADER;
}

void* le_rt_alloc(size_t bytes) { return le_rt_map(bytes, 1); }

void* le_rt_alloc_for_overwrite(size_t bytes) { return le_rt_map(bytes, 0); }

size_t le_rt_size(const void* p) {
  if (p == NULL) return 0;
  size_t bytes = 0;
  memcpy(&bytes, (const unsigned char*)p - LE_RT_HEADER, sizeof(bytes));
  return bytes;
}

void le_rt_free(void* p) {
  if (p == NULL) return;
  unsigned char* base = (unsigned char*)p - LE_RT_HEADER;
  const size_t total = le_rt_size(p) + LE_RT_HEADER;
#if defined(_WIN32)
  (void)total;
  free(base);
#else
  /* A failed unmap means the caller is about to drop the only pointer that
   * could ever have freed this mapping, so it does not pass quietly. */
  if (munmap(base, total) != 0) {
    fprintf(stderr,
            "segno/rt_alloc: munmap failed (errno %d), leaking %zu bytes\n",
            errno, total);
  }
#endif
}
