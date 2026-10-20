#include "rt_alloc.h"

#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#if !LE_RT_ALLOC_USES_HEAP
#include <sys/mman.h>
#include <unistd.h> /* sysconf(_SC_PAGESIZE) */
#endif

#if defined(__linux__) && !LE_RT_ALLOC_USES_HEAP
/* The values are kernel ABI; defined here so older libc headers still build
 * the call, and an older kernel answers EINVAL at run time. */
#ifndef MADV_POPULATE_WRITE
#define MADV_POPULATE_WRITE 23
#endif
#endif

/* Every allocation records its own size in front of the payload, so le_rt_free
 * needs only the pointer: munmap needs a length, and passing one through every
 * call site, each holding the size in its own unit (frames, samples,
 * channels), is how a mismatched unmap gets written. One cache line, so the
 * payload of a page-aligned mapping is 64-byte aligned. */
#define LE_RT_HEADER 64u

static int g_shield_fail_for_test = 0;

void le_rt_set_fork_shield_failure_for_test(int state) {
  g_shield_fail_for_test = state;
}

#if !LE_RT_ALLOC_USES_HEAP
static size_t le_rt_page_size(void) {
  static size_t page = 0; /* racing initialisers store the same value */
  if (page == 0) {
    const long v = sysconf(_SC_PAGESIZE);
    page = v > 0 ? (size_t)v : 4096u;
  }
  return page;
}
#endif

/* Marks a fresh mapping VM_DONTCOPY so fork() skips it (rt_alloc.h, item 1).
 * A refusal degrades rather than failing the allocation: the mapping is good
 * memory and only the fork protection is lost, and "the take clicks if
 * something forks" beats "you cannot record". Logged once per process; the
 * condition is process-wide and segno.log does not rotate. */
static void le_rt_fork_shield(void* base, size_t total) {
#if defined(__linux__) && !LE_RT_ALLOC_USES_HEAP
  static int warned = 0; /* a race prints the line twice, which is harmless */
  /* A forced refusal is silent, so it never consumes the one line a genuine
   * refusal owns. */
  if (g_shield_fail_for_test) return;
  if (madvise(base, total, MADV_DONTFORK) == 0) return;
  if (warned) return;
  warned = 1;
  fprintf(stderr,
          "segno/rt_alloc: MADV_DONTFORK refused (errno %d); audio buffers "
          "are copy-on-write and a fork will cost the audio thread a fault per "
          "page (#900). Reported once.\n",
          errno);
#else
  (void)base; /* no fork shield to apply off Linux */
  (void)total;
#endif
}

void* le_rt_alloc(size_t bytes) {
  if (bytes == 0 || bytes > SIZE_MAX - 2u * LE_RT_HEADER) return NULL;
  const size_t total = bytes + LE_RT_HEADER;
  unsigned char* base;
#if LE_RT_ALLOC_USES_HEAP
  /* A sanitized build keeps the heap so AddressSanitizer still puts redzones
   * around every audio buffer; the mapping path is what the plain test run
   * and every shipped build exercise. */
  base = (unsigned char*)calloc(1, total);
  if (base == NULL) return NULL;
#else
  void* mapped = mmap(NULL, total, PROT_READ | PROT_WRITE,
                      MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
  if (mapped == MAP_FAILED) return NULL;
#if defined(__linux__)
  /* No transparent huge pages, for two reasons. khugepaged collapses small
   * pages into a huge one in the background by unmapping the range under
   * mmap_lock, and an audio-thread write meanwhile faults and waits for it.
   * And with THP set to "always" the header write below would fault in a
   * whole huge page (2 MB, or 32 MB on a 16 KB-page kernel), so an untouched
   * lane slot would not stay untouched. Refused only by a kernel without THP,
   * where there is nothing to turn off. */
  (void)madvise(mapped, total, MADV_NOHUGEPAGE);
#endif
  le_rt_fork_shield(mapped, total);
  base = (unsigned char*)mapped;
#endif
  /* The size write touches the first page only; the kernel zeroes the rest
   * the first time each page is faulted in. */
  memcpy(base, &bytes, sizeof(bytes));
  return base + LE_RT_HEADER;
}

void* le_rt_alloc_prefaulted(size_t bytes) {
  void* p = le_rt_alloc(bytes);
  le_rt_prefault(p, bytes);
  return p;
}

size_t le_rt_size(const void* p) {
  if (p == NULL) return 0;
  size_t bytes = 0;
  memcpy(&bytes, (const unsigned char*)p - LE_RT_HEADER, sizeof(bytes));
  return bytes;
}

void le_rt_prefault(const void* p, size_t bytes) {
  if (p == NULL || bytes == 0) return;
  unsigned char* const start = (unsigned char*)p;
#if LE_RT_ALLOC_USES_HEAP
  /* calloc's pages are touched by the zeroing or are the shared zero page;
   * write one byte per 4 KB so either way they end up private and present. */
  const size_t page = 4096u;
#else
  const size_t page = le_rt_page_size();
#if defined(__linux__)
  /* Linux 5.14+: the kernel faults the range in writable without a single
   * user-space store, so it cannot disturb a concurrent writer. The range is
   * rounded out to pages; both ends stay inside this allocation's mapping,
   * whose base is page-aligned and holds the header. */
  static int populate_unsupported = 0;
  if (!populate_unsupported) {
    const uintptr_t lo = (uintptr_t)start & ~(uintptr_t)(page - 1);
    const uintptr_t hi =
        ((uintptr_t)start + bytes + page - 1) & ~(uintptr_t)(page - 1);
    if (madvise((void*)lo, hi - lo, MADV_POPULATE_WRITE) == 0) return;
    if (errno == EINVAL) populate_unsupported = 1; /* kernel older than 5.14 */
  }
#endif
#endif
  /* One atomic add of zero per page: a write access, so the page is faulted in
   * writable, and a read-modify-write, so a concurrent store by the audio
   * thread to the same byte is never lost. The first byte of the range, then
   * every page boundary inside it. */
  unsigned char* const end = start + bytes;
  unsigned char* a = start;
  while (a < end) {
    __atomic_fetch_add(a, (unsigned char)0, __ATOMIC_RELAXED);
    const uintptr_t next =
        ((uintptr_t)a + page) & ~(uintptr_t)(page - 1);
    a = (unsigned char*)next;
  }
}

void le_rt_free(void* p) {
  if (p == NULL) return;
  unsigned char* const base = (unsigned char*)p - LE_RT_HEADER;
#if LE_RT_ALLOC_USES_HEAP
  free(base);
#else
  const size_t total = le_rt_size(p) + LE_RT_HEADER;
  /* A failed unmap leaks the only pointer that could free this mapping, so it
   * does not pass quietly. */
  if (munmap(base, total) != 0) {
    fprintf(stderr, "segno/rt_alloc: munmap failed (errno %d), leaking %zu "
                    "bytes\n", errno, total);
  }
#endif
}

void le_rt_prefault_stack(size_t bytes) {
  /* A variable-length array is the stack frame itself; writing one byte per
   * 4 KB faults every page of it in. `volatile` keeps the stores. */
  if (bytes == 0 || bytes > (1u << 20)) return;
  volatile unsigned char frame[bytes];
  for (size_t i = 0; i < bytes; i += 4096u) frame[i] = 0;
  frame[bytes - 1] = 0;
}
