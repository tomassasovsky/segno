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
 * a mismatched-length unmap gets written. One cache line, so the payload stays
 * 64-byte aligned for the DSP that reads it. */
#define LE_RT_HEADER 64u

static int g_shield_fail_override = 0;

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
  fprintf(stderr,
          "segno/rt_alloc: MADV_DONTFORK refused (errno %d); this %zu-byte "
          "buffer is copy-on-write and every fork will cost the audio thread a "
          "fault per page (#804)\n",
          g_shield_fail_override ? 0 : errno, total);
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

void* le_rt_alloc(size_t bytes) {
  if (bytes == 0 || bytes > SIZE_MAX - LE_RT_HEADER) return NULL;
  const size_t total = bytes + LE_RT_HEADER;
  unsigned char* base = NULL;
#if defined(_WIN32)
  base = (unsigned char*)malloc(total);
  if (base == NULL) return NULL;
#else
  void* mapped = mmap(NULL, total, PROT_READ | PROT_WRITE,
                      MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
  if (mapped == MAP_FAILED) return NULL;
  le_rt_fork_shield(mapped, total);
  base = (unsigned char*)mapped;
#endif
  /* Touch every page HERE, on the control thread. mmap and malloc both hand
   * back untouched pages, and the first pass over a fresh buffer would
   * otherwise be faulted in by the audio callback one page at a time. This also
   * gives the caller the zeroed memory calloc used to. */
  memset(base, 0, total);
  memcpy(base, &bytes, sizeof(bytes));
  return base + LE_RT_HEADER;
}

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
