#include "rt_alloc.h"

#include <errno.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#if !LE_RT_ALLOC_USES_HEAP
#include <sys/mman.h>
#include <unistd.h> /* sysconf(_SC_PAGESIZE), syscall */
#endif
#if defined(__linux__) && !LE_RT_ALLOC_USES_HEAP
#include <sys/syscall.h> /* SYS_mlock2 */
/* Kernel ABI values, defined here so older libc headers still build the
 * calls; an older kernel answers EINVAL at run time. */
#ifndef MADV_POPULATE_WRITE
#define MADV_POPULATE_WRITE 23
#endif
#ifndef MLOCK_ONFAULT
#define MLOCK_ONFAULT 1
#endif
#endif

/* Every allocation records its own size in front of the payload, so le_rt_free
 * needs only the pointer: munmap needs a length, and passing one through every
 * call site, each holding the size in its own unit (frames, samples,
 * channels), is how a mismatched unmap gets written. The size is stored twice,
 * once plain and once mixed with a constant, behind a magic word: an underflow
 * that scribbles over the header is caught by le_rt_free, which then leaks the
 * mapping and says so rather than unmapping a length it cannot trust. The
 * header is the cache line right below the payload, so the payload is 64-byte
 * aligned.
 *
 * The payload does not start at the same offset in every mapping: big buffers
 * start one of LE_RT_COLOURS cache lines further in, in turn. Fresh mappings
 * of one size land on the same alignment (huge-page aligned, often), so
 * without this the 64 lane buffers a mix reads at one position would all map
 * to the same cache sets and evict each other every frame; that cost the
 * 8 x 8 mixer bench 16 us a period. Costs at most a page per buffer. */
#define LE_RT_HEADER 64u
#define LE_RT_COLOURS 64u
#define LE_RT_COLOUR_MIN_BYTES ((size_t)64 << 10) /* small buffers: no colour */
#define LE_RT_MAGIC UINT64_C(0x5345474E4F525441) /* "SEGNORTA" */
#define LE_RT_MIX UINT64_C(0x9E3779B97F4A7C15)

typedef struct le_rt_header {
  uint64_t magic;
  uint64_t bytes;
  uint64_t lead;  /* bytes from the start of the block to the payload */
  uint64_t check; /* bytes ^ lead ^ LE_RT_MIX */
} le_rt_header;

static _Atomic unsigned g_colour = 0;

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

/* Linux: fork-shield the fresh mapping, keep THP off it, and lock it on
 * fault. Each refusal degrades instead of failing the allocation (the mapping
 * is good memory either way) and is logged once per process: the condition is
 * process-wide and segno.log does not rotate. */
static void le_rt_advise(void* base, size_t total) {
#if defined(__linux__) && !LE_RT_ALLOC_USES_HEAP
  static int shield_warned = 0; /* a race prints a line twice: harmless */
  static int lock_warned = 0;
  /* No transparent huge pages, for two reasons. khugepaged collapses small
   * pages into a huge one in the background by unmapping the range under
   * mmap_lock, and an audio-thread write meanwhile faults and waits for it.
   * And with THP set to "always" the header write would fault in a whole huge
   * page (2 MB, or 32 MB on a 16 KB-page kernel), so an untouched lane slot
   * would not stay untouched. Refused only by a kernel without THP. */
  (void)madvise(base, total, MADV_NOHUGEPAGE);
  /* fork() skips the mapping and never write-protects it (rt_alloc.h, 1). A
   * forced refusal is silent, so a test never consumes the one line a genuine
   * refusal owns. */
  if (!g_shield_fail_for_test && madvise(base, total, MADV_DONTFORK) != 0 &&
      !shield_warned) {
    shield_warned = 1;
    fprintf(stderr,
            "segno/rt_alloc: MADV_DONTFORK refused (errno %d); audio buffers "
            "are copy-on-write and a fork will cost the audio thread a fault "
            "per page (#900). Reported once.\n",
            errno);
  }
  /* Lock what is faulted in, from now until the unmap: a page the audio
   * thread uses can then never be reclaimed and faulted back. Only this
   * engine's mappings are locked, never the process (the Dart VM and glibc's
   * arenas hand memory back with MADV_DONTNEED, which the kernel refuses on
   * locked memory). Needs CAP_IPC_LOCK (the appliance runs as root) or room
   * under RLIMIT_MEMLOCK; without either the buffer is merely unlocked. */
  if (syscall(SYS_mlock2, base, total, MLOCK_ONFAULT) != 0 && !lock_warned) {
    lock_warned = 1;
    fprintf(stderr,
            "segno/rt_alloc: mlock2 refused (errno %d); audio buffers are not "
            "locked and can be reclaimed under memory pressure. Reported "
            "once.\n",
            errno);
  }
#else
  (void)base; /* nothing to apply off Linux */
  (void)total;
#endif
}

void* le_rt_alloc(size_t bytes) {
  const size_t most_lead = LE_RT_HEADER * (LE_RT_COLOURS + 1u);
  if (bytes == 0 || bytes > SIZE_MAX - 2u * most_lead) return NULL;
  size_t lead = LE_RT_HEADER;
  if (bytes >= LE_RT_COLOUR_MIN_BYTES) {
    lead += LE_RT_HEADER *
            (atomic_fetch_add_explicit(&g_colour, 1u, memory_order_relaxed) %
             LE_RT_COLOURS);
  }
  const size_t total = bytes + lead;
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
  le_rt_advise(mapped, total);
  base = (unsigned char*)mapped;
#endif
  /* The header write touches the first page only; the kernel zeroes the rest
   * the first time each page is faulted in. */
  const le_rt_header h = {LE_RT_MAGIC, (uint64_t)bytes, (uint64_t)lead,
                          (uint64_t)bytes ^ (uint64_t)lead ^ LE_RT_MIX};
  memcpy(base + lead - LE_RT_HEADER, &h, sizeof(h));
  return base + lead;
}

void* le_rt_alloc_prefaulted(size_t bytes) {
  void* p = le_rt_alloc(bytes);
  le_rt_prefault(p, bytes);
  return p;
}

/* The recorded size (and the lead, when [lead] is not NULL), or 0 when the
 * header is not intact. */
static size_t le_rt_header_bytes(const void* p, size_t* lead) {
  le_rt_header h;
  memcpy(&h, (const unsigned char*)p - LE_RT_HEADER, sizeof(h));
  if (h.magic != LE_RT_MAGIC || (h.bytes ^ h.lead ^ LE_RT_MIX) != h.check ||
      h.lead < LE_RT_HEADER || h.lead > LE_RT_HEADER * (LE_RT_COLOURS + 1u)) {
    return 0;
  }
  if (lead != NULL) *lead = (size_t)h.lead;
  return (size_t)h.bytes;
}

size_t le_rt_size(const void* p) {
  return p == NULL ? 0 : le_rt_header_bytes(p, NULL);
}

int le_rt_prefault_can_run_concurrently(void) {
#if defined(__linux__) && !LE_RT_ALLOC_USES_HEAP
  /* MADV_POPULATE_WRITE is a kernel-side fault-in: on a range that has since
   * been unmapped it fails with ENOMEM, and on one that was mapped again it
   * only faults in zero or present pages. Probe it once on a scratch page. */
  static int verdict = -1;
  if (verdict < 0) {
    const size_t page = le_rt_page_size();
    void* probe = mmap(NULL, page, PROT_READ | PROT_WRITE,
                       MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    verdict = probe != MAP_FAILED &&
              madvise(probe, page, MADV_POPULATE_WRITE) == 0;
    if (probe != MAP_FAILED) munmap(probe, page);
  }
  return verdict;
#else
  return 0; /* the fallback writes from user space: never on a stale range */
#endif
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
  if (le_rt_prefault_can_run_concurrently()) {
    const uintptr_t lo = (uintptr_t)start & ~(uintptr_t)(page - 1);
    const uintptr_t hi =
        ((uintptr_t)start + bytes + page - 1) & ~(uintptr_t)(page - 1);
    /* Never fall back to user-space stores here, even on failure: the
     * background prefaulter may be handing in a range that has just been
     * unmapped (ENOMEM), and a store there would be a SIGSEGV. A range that
     * cannot be populated (out of memory) cannot be touched either. */
    (void)madvise((void*)lo, hi - lo, MADV_POPULATE_WRITE);
    return;
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
  size_t lead = 0;
  const size_t bytes = le_rt_header_bytes(p, &lead);
  if (bytes == 0) {
    fprintf(stderr, "segno/rt_alloc: buffer %p has a damaged header; leaking "
                    "it rather than unmapping an unknown length\n", p);
    return;
  }
  unsigned char* const base = (unsigned char*)p - lead;
#if LE_RT_ALLOC_USES_HEAP
  free(base);
#else
  const size_t total = bytes + lead;
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

/* ---- arena ---- */

#define LE_RT_ARENA_ALIGN 64u

int le_rt_arena_init(le_rt_arena* a, size_t bytes) {
  if (a == NULL) return 0;
  a->base = (unsigned char*)le_rt_alloc_prefaulted(bytes);
  a->cap = a->base != NULL ? bytes : 0;
  a->used = 0;
  return a->base != NULL;
}

void* le_rt_arena_alloc(le_rt_arena* a, size_t bytes) {
  if (a == NULL || a->base == NULL || bytes == 0) return NULL;
  const size_t at = (a->used + LE_RT_ARENA_ALIGN - 1) & ~(size_t)(LE_RT_ARENA_ALIGN - 1);
  if (at > a->cap || bytes > a->cap - at) return NULL;
  a->used = at + bytes;
  unsigned char* p = a->base + at;
  memset(p, 0, bytes); /* zeroed after a reset too; the pages are resident */
  return p;
}

void le_rt_arena_reset(le_rt_arena* a) {
  if (a != NULL) a->used = 0;
}

void le_rt_arena_release(le_rt_arena* a) {
  if (a == NULL) return;
  le_rt_free(a->base);
  a->base = NULL;
  a->cap = 0;
  a->used = 0;
}
