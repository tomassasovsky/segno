/*
 * test_engine_rt_memory.h — the audio thread never faults (#900, #906, #1367).
 *
 * Included by test_engine_core.c (it uses that file's CHECK, drain and timing
 * helpers). Three layers:
 *
 *   1. rt_alloc's contract: zeroed, sized, NULL-safe, prefault preserves
 *      content, a refused fork shield degrades instead of failing.
 *   2. Memory policy (Linux): an allocation touches nothing; a lane's
 *      cap-sized slot stays non-resident until a take is about to start on
 *      it, so growing every track to 8 lanes costs no RSS (#906); a prefault
 *      makes the slot resident; every audio buffer carries VM_DONTCOPY.
 *   3. The proof (Linux): an audio thread on its own stack runs the real
 *      engine through arm, record, overdub, punch-out, undo/redo and FX
 *      enable / disable / retype while the control thread drives it, and
 *      getrusage(RUSAGE_THREAD) counts its page faults inside
 *      le_engine_process. Expected: zero. Then the same scenario with a fork
 *      before every step, which write-protects every copied page of the
 *      process: still zero, because every page the callback writes is either
 *      MADV_DONTFORK or its stack (which this harness, unlike glibc, can
 *      shield, see rt_fork).
 *
 * The fault assertions skip under AddressSanitizer: its shadow memory is
 * written by every instrumented store and is neither prefaulted nor
 * fork-shielded, and rt_alloc uses the heap there (LE_RT_ALLOC_USES_HEAP).
 */
#ifndef SEGNO_TEST_ENGINE_RT_MEMORY_H
#define SEGNO_TEST_ENGINE_RT_MEMORY_H

#include "engine_prefault.h" /* le_prefault_tick, the head and lead */
#include "rt_alloc.h"

#if defined(__linux__) && !LE_RT_ALLOC_USES_HEAP
#define LE_RT_FAULT_TESTS 1
#include <signal.h>       /* SIGCHLD for the raw clone */
#include <sys/mman.h>     /* mincore, mmap for the shielded stack */
#include <sys/prctl.h>    /* PR_SET_THP_DISABLE */
#include <sys/resource.h> /* getrusage(RUSAGE_THREAD) */
#include <sys/syscall.h>  /* SYS_clone, SYS_exit_group */
#include <sys/wait.h>     /* waitpid */
#else
#define LE_RT_FAULT_TESTS 0
#endif

/* ---- 1. the allocator's contract (every platform) ---- */

static void test_rt_alloc_contract(void) {
  printf("test_rt_alloc_contract\n");
  CHECK(le_rt_alloc(0) == NULL);
  CHECK(le_rt_alloc((size_t)-1) == NULL); /* the header would overflow */
  CHECK(le_rt_size(NULL) == 0);
  le_rt_free(NULL); /* teardown paths call it blind */
  le_rt_prefault(NULL, 64);

  const size_t n = (size_t)1 << 20; /* 1 MB: several pages anywhere */
  unsigned char* p = (unsigned char*)le_rt_alloc(n);
  CHECK(p != NULL);
  CHECK(le_rt_size(p) == n);
  CHECK(((uintptr_t)p & 15u) == 0); /* float/SIMD-safe alignment */
  CHECK(p[0] == 0 && p[n / 2] == 0 && p[n - 1] == 0); /* zeroed */
  /* A prefault never changes content, whatever is there. */
  for (size_t i = 0; i < n; i += 997) p[i] = (unsigned char)(i * 31u + 7u);
  le_rt_prefault(p, n);
  le_rt_prefault(p + 3, n - 3); /* an unaligned interior range is fine too */
  int same = 1;
  for (size_t i = 0; i < n; i += 997) same &= p[i] == (unsigned char)(i * 31u + 7u);
  CHECK(same);
  le_rt_free(p);

  float* q = (float*)le_rt_alloc_prefaulted(4096 * sizeof(float));
  CHECK(q != NULL && q[0] == 0.0f && q[4095] == 0.0f);
  le_rt_free(q);

  /* A refused MADV_DONTFORK still hands back good memory (Linux drives the
   * refusal path; elsewhere the seam is inert and the same holds). */
  le_rt_set_fork_shield_failure_for_test(1);
  float* r = (float*)le_rt_alloc_prefaulted(1024 * sizeof(float));
  le_rt_set_fork_shield_failure_for_test(0);
  CHECK(r != NULL && r[1023] == 0.0f);
  if (r != NULL) r[1023] = 1.0f;
  le_rt_free(r);

  /* The arena: aligned, zeroed, bounded, reusable. */
  le_rt_arena arena;
  CHECK(le_rt_arena_init(&arena, 4096));
  unsigned char* a1 = (unsigned char*)le_rt_arena_alloc(&arena, 100);
  unsigned char* a2 = (unsigned char*)le_rt_arena_alloc(&arena, 100);
  CHECK(a1 != NULL && a2 != NULL && a2 >= a1 + 100);
  CHECK(((uintptr_t)a1 & 63u) == 0 && ((uintptr_t)a2 & 63u) == 0);
  CHECK(le_rt_arena_alloc(&arena, 8192) == NULL); /* does not fit */
  a1[0] = 7;
  le_rt_arena_reset(&arena);
  unsigned char* a3 = (unsigned char*)le_rt_arena_alloc(&arena, 16);
  CHECK(a3 == a1 && a3[0] == 0); /* reused, and zeroed again */
  le_rt_arena_release(&arena);
  le_rt_arena_release(&arena); /* idempotent */
  CHECK(le_rt_arena_alloc(&arena, 16) == NULL);
}

#if LE_RT_FAULT_TESTS

/* ---- 2. memory policy (Linux, mapping path) ---- */

/* Whether the smaps VmFlags of the mapping holding [addr] contain [flag]
 * (" lf", " dc"...): 1 yes, 0 no, -1 not found. */
static int smaps_vmflag(const void* addr, const char* flag) {
  FILE* f = fopen("/proc/self/smaps", "r");
  if (f == NULL) return -1;
  char line[512];
  int in_range = 0;
  int found = -1;
  const unsigned long want = (unsigned long)(uintptr_t)addr;
  while (fgets(line, sizeof(line), f) != NULL) {
    unsigned long lo = 0, hi = 0;
    char perms[8];
    if (sscanf(line, "%lx-%lx %7s", &lo, &hi, perms) == 3) {
      in_range = want >= lo && want < hi;
    } else if (in_range && strncmp(line, "VmFlags:", 8) == 0) {
      found = strstr(line, flag) != NULL;
      break;
    }
  }
  fclose(f);
  return found;
}

/* Resident pages of [p, p + bytes), by mincore. */
static size_t rt_resident_pages(const void* p, size_t bytes) {
  const size_t page = (size_t)sysconf(_SC_PAGESIZE);
  const uintptr_t lo = (uintptr_t)p & ~(uintptr_t)(page - 1);
  const uintptr_t hi = ((uintptr_t)p + bytes + page - 1) & ~(uintptr_t)(page - 1);
  const size_t pages = (hi - lo) / page;
  unsigned char* vec = (unsigned char*)malloc(pages);
  if (vec == NULL) return (size_t)-1;
  size_t resident = 0;
  if (mincore((void*)lo, hi - lo, vec) == 0) {
    for (size_t i = 0; i < pages; ++i) resident += vec[i] & 1u;
  } else {
    resident = (size_t)-1;
  }
  free(vec);
  return resident;
}

static size_t rt_pages(const void* p, size_t bytes) {
  const size_t page = (size_t)sysconf(_SC_PAGESIZE);
  const uintptr_t lo = (uintptr_t)p & ~(uintptr_t)(page - 1);
  const uintptr_t hi = ((uintptr_t)p + bytes + page - 1) & ~(uintptr_t)(page - 1);
  return (hi - lo) / page;
}

/* The pages one fault can bring in beyond the faulting page: a huge page's
 * worth when transparent huge pages are "always" (the allocator leaves THP to
 * system policy, and a fault in a huge-page-aligned extent then fills all of
 * it), 0 otherwise. The bounds below are page-exact without THP and widen by
 * this per touched extent with it. */
static size_t rt_thp_pages(void) {
  FILE* f = fopen("/sys/kernel/mm/transparent_hugepage/enabled", "r");
  if (f == NULL) return 0;
  char mode[128] = {0};
  const int got = fgets(mode, sizeof(mode), f) != NULL;
  fclose(f);
  if (!got || strstr(mode, "[always]") == NULL) return 0;
  size_t huge = (size_t)2 << 20;
  f = fopen("/sys/kernel/mm/transparent_hugepage/hpage_pmd_size", "r");
  if (f != NULL) {
    unsigned long v = 0;
    if (fscanf(f, "%lu", &v) == 1 && v > 0) huge = (size_t)v;
    fclose(f);
  }
  return huge / (size_t)sysconf(_SC_PAGESIZE);
}

/* VmRSS of this process, in KB (0 when unreadable). */
static long rt_rss_kb(void) {
  FILE* f = fopen("/proc/self/status", "r");
  if (f == NULL) return 0;
  char line[256];
  long kb = 0;
  while (fgets(line, sizeof(line), f) != NULL) {
    if (sscanf(line, "VmRSS: %ld kB", &kb) == 1) break;
  }
  fclose(f);
  return kb;
}

static void test_rt_alloc_touches_nothing_until_prefaulted(void) {
  printf("test_rt_alloc_touches_nothing_until_prefaulted\n");
  const size_t n = (size_t)8 << 20; /* 8 MB */
  float* p = (float*)le_rt_alloc(n);
  CHECK(p != NULL);
  /* Only the header's page has been written. */
  CHECK(rt_resident_pages(p, n) <= 1 + rt_thp_pages());
  CHECK(smaps_mapping_is_dontcopy(p) == 1); /* fork() skips it */
  le_rt_prefault(p, n);
  CHECK(rt_resident_pages(p, n) == rt_pages(p, n));
  le_rt_free(p);

  /* The prefaulted form, used for everything written from the start. */
  float* q = (float*)le_rt_alloc_prefaulted(n);
  CHECK(q != NULL && rt_resident_pages(q, n) == rt_pages(q, n));
  CHECK(smaps_mapping_is_dontcopy(q) == 1);
  le_rt_free(q);

  /* A damaged header is refused, never unmapped at a guessed length. */
  unsigned char* r = (unsigned char*)le_rt_alloc(4096);
  CHECK(r != NULL);
  r[-64] ^= 0xffu; /* the magic word */
  CHECK(le_rt_size(r) == 0);
  le_rt_free(r); /* reports and leaks */
}

/* Every engine-owned buffer the callback writes is its own DONTFORK mapping. */
static void test_engine_audio_buffers_are_fork_shielded(void) {
  printf("test_engine_audio_buffers_are_fork_shielded\n");
  le_engine* e = le_engine_create();
  CHECK(le_engine_configure(e, 48000, 2, 2, 48000 * 4) == LE_OK);
  CHECK(smaps_mapping_is_dontcopy(e) == 1);            /* the struct + rings */
  CHECK(smaps_mapping_is_dontcopy(e->cond_buf) == 1);  /* conditioning scratch */
  CHECK(smaps_mapping_is_dontcopy(e->lat_buf) == 1);   /* latency capture */
  CHECK(smaps_mapping_is_dontcopy(e->synth) == 1);     /* instrument voices */
  CHECK(smaps_mapping_is_dontcopy(e->inst_bus) == 1);
  CHECK(smaps_mapping_is_dontcopy(e->tracks[0].lanes[0].pool[0]) == 1);
  CHECK(le_engine_set_lane_fx(e, 0, 0, 0, LE_FX_DELAY) == LE_OK);
  CHECK(le_engine_set_lane_fx(e, 0, 0, 1, LE_FX_OCTAVER) == LE_OK);
  CHECK(le_engine_set_lane_fx_count(e, 0, 0, 2, 0) == LE_OK);
  drain(e);
  const le_fx_state* fx = &e->tracks[0].lanes[0].fx;
  CHECK(fx->delay[0][0] != NULL && smaps_mapping_is_dontcopy(fx->delay[0][0]) == 1);
  CHECK(fx->delay[0][1] != NULL && smaps_mapping_is_dontcopy(fx->delay[0][1]) == 1);
  CHECK(fx->oct[1][0].out != NULL && smaps_mapping_is_dontcopy(fx->oct[1][0].out) == 1);
  CHECK(fx->oct[1][1].sum_phase != NULL &&
        smaps_mapping_is_dontcopy(fx->oct[1][1].sum_phase) == 1);
  le_engine_destroy(e);
}

/* #906: activating lanes allocates their cap-sized slots without touching
 * them, so 8 tracks x 8 lanes cost no RSS until something records; a take
 * prefaults exactly the lanes of the track it starts on. */
static void test_lane_slots_cost_nothing_until_a_take(void) {
  printf("test_lane_slots_cost_nothing_until_a_take\n");
  le_engine* e = le_engine_create();
  const int32_t rate = 96000;
  const int32_t cap = rate * 60; /* the appliance default: 60 s at 96 kHz */
  CHECK(le_engine_configure(e, rate, 8, 2, cap) == LE_OK);
  const long rss0 = rt_rss_kb();
  for (int32_t t = 0; t < e->track_count; ++t) {
    CHECK(set_lane_count_and_publish(e, t, LE_MAX_LANES) == LE_OK);
  }
  const long rss1 = rt_rss_kb();
  const size_t slot_bytes = (size_t)cap * sizeof(float);
  const size_t head_bytes =
      (size_t)rate * LE_PREFAULT_HEAD_SECONDS * sizeof(float);
  size_t worst = 0;
  for (int32_t t = 0; t < e->track_count; ++t) {
    for (int l = 0; l < LE_MAX_LANES; ++l) {
      const float* b = e->tracks[t].lanes[l].pool[0];
      CHECK(b != NULL);
      if (b == NULL) continue;
      const size_t r = rt_resident_pages(b, slot_bytes);
      if (r > worst) worst = r;
      /* the head a take writes first is in */
      CHECK(rt_resident_pages(b, head_bytes) == rt_pages(b, head_bytes));
    }
  }
  /* The head and the header page, nothing more, of each of the 64 slots. */
  const size_t thp = rt_thp_pages();
  CHECK(worst <= rt_pages(NULL, head_bytes) + 2 + 2 * thp);
  /* was 64 x 23 MB = 1.4 GB */
  CHECK(rss1 - rss0 <
        32 * 1024 + (long)(64 * 2 * thp * (size_t)sysconf(_SC_PAGESIZE) / 1024));
  printf("  %d tracks x %d lanes at 96 kHz / 60 s: RSS +%ld KB for %zu MB of "
         "slots\n", e->track_count, LE_MAX_LANES, rss1 - rss0,
         ((size_t)e->track_count * LE_MAX_LANES * slot_bytes) >> 20);

  /* A take hands its slots to the prefaulter, which stays a few seconds
   * ahead of what has been recorded, not the whole cap. */
  CHECK(le_engine_record(e, 0) == LE_OK);
  le_prefault_tick(e);
  const size_t ahead_bytes =
      (size_t)rate * (LE_PREFAULT_AHEAD_SECONDS + 1) * sizeof(float);
  for (int l = 0; l < LE_MAX_LANES; ++l) {
    const float* b = e->tracks[0].lanes[l].pool[0];
    CHECK(rt_resident_pages(b, head_bytes) == rt_pages(b, head_bytes));
    CHECK(rt_resident_pages(b, slot_bytes) <=
          rt_pages(b, ahead_bytes) + 2 + 2 * thp);
  }
  printf("  after a take starts on track 0: RSS +%ld KB\n", rt_rss_kb() - rss0);
  le_engine_destroy(e);
}

/* #900 item 7: the recording cap is bounded, and a removed lane's buffers are
 * freed (and so unlocked) once the callback has stopped reading it. */
static void test_cap_is_bounded_and_removed_lanes_are_freed(void) {
  printf("test_cap_is_bounded_and_removed_lanes_are_freed\n");
  le_engine* e = le_engine_create();
  CHECK(le_engine_configure(e, 48000, 4, 2, INT32_MAX) == LE_OK);
  CHECK(e->max_loop_frames == 48000 * LE_MAX_LOOP_SECONDS);
  CHECK(le_engine_configure(e, 48000, 4, 2, 48000 * 4) == LE_OK);
  CHECK(set_lane_count_and_publish(e, 0, 4) == LE_OK);
  CHECK(e->tracks[0].lanes[3].pool[0] != NULL);
  CHECK(set_lane_count_and_publish(e, 0, 2) == LE_OK);
  le_snapshot s;
  le_engine_get_snapshot(e, &s); /* the drain that frees them */
  CHECK(e->tracks[0].lanes[2].pool[0] == NULL);
  CHECK(e->tracks[0].lanes[3].pool[0] == NULL);
  CHECK(e->tracks[0].lanes[1].pool[0] != NULL);
  CHECK(set_lane_count_and_publish(e, 0, 4) == LE_OK); /* and they come back */
  CHECK(e->tracks[0].lanes[3].pool[0] != NULL);
  le_engine_destroy(e);
}

/* Each audio mapping is locked on fault, where the process may lock. */
static void test_audio_buffers_are_locked(void) {
  printf("test_audio_buffers_are_locked\n");
  if (geteuid() != 0) {
    printf("  (not root: mlock2 is bounded by RLIMIT_MEMLOCK; skipped)\n");
    return;
  }
  float* p = (float*)le_rt_alloc((size_t)1 << 20);
  CHECK(p != NULL);
  CHECK(smaps_vmflag(p, " lf") == 1); /* VM_LOCKONFAULT */
  le_rt_free(p);
}

/* ---- 3. the proof: page faults on the audio thread ---- */

#define RT_BLOCK 64
#define RT_STACK_BYTES ((size_t)1 << 20)

typedef struct rt_audio_thread {
  le_engine* e;
  pthread_t thread;
  pthread_mutex_t mu;
  pthread_cond_t cv;
  int blocks_wanted; /* > 0: run that many blocks; -1: exit */
  float level;
  float* in;  /* both le_rt_alloc_prefaulted, so they are shielded too */
  float* out;
  void* stack; /* this thread's stack: its own DONTFORK mapping */
  long faults; /* minor + major, inside le_engine_process only */
  long worst_block;
  long blocks_run;
  unsigned char* painted_top; /* the stack was painted below this address */
  size_t deepest;             /* bytes of stack the callback used, at most */
} rt_audio_thread;

#define RT_PAINT 0xA5u

static long rt_thread_faults(void) {
  struct rusage ru;
  getrusage(RUSAGE_THREAD, &ru);
  return ru.ru_minflt + ru.ru_majflt;
}

static void* rt_audio_main(void* arg) {
  rt_audio_thread* a = (rt_audio_thread*)arg;
  le_rt_prefault_stack(256u * 1024u); /* what data_callback does first */
  /* Paint the stack below this frame (a page of margin), so the deepest byte
   * any callback wrote can be found afterwards. */
  volatile unsigned char here = 0;
  a->painted_top = (unsigned char*)&here - 4096;
  memset(a->stack, RT_PAINT, (size_t)(a->painted_top - (unsigned char*)a->stack));
  pthread_mutex_lock(&a->mu);
  for (;;) {
    while (a->blocks_wanted == 0) pthread_cond_wait(&a->cv, &a->mu);
    if (a->blocks_wanted < 0) break;
    const int n = a->blocks_wanted;
    const float level = a->level;
    pthread_mutex_unlock(&a->mu);
    for (int b = 0; b < n; ++b) {
      for (int i = 0; i < RT_BLOCK * 2; ++i) a->in[i] = level;
      const long before = rt_thread_faults();
      le_engine_process(a->e, a->out, a->in, RT_BLOCK);
      const long got = rt_thread_faults() - before;
      a->faults += got;
      if (got > a->worst_block) a->worst_block = got;
      a->blocks_run++;
    }
    pthread_mutex_lock(&a->mu);
    a->blocks_wanted = 0;
    pthread_cond_broadcast(&a->cv);
  }
  pthread_mutex_unlock(&a->mu);
  return NULL;
}

static int rt_audio_start(rt_audio_thread* a, le_engine* e) {
  memset(a, 0, sizeof(*a));
  a->e = e;
  pthread_mutex_init(&a->mu, NULL);
  pthread_cond_init(&a->cv, NULL);
  a->in = (float*)le_rt_alloc_prefaulted(RT_BLOCK * 2 * sizeof(float));
  a->out = (float*)le_rt_alloc_prefaulted(RT_BLOCK * 2 * sizeof(float));
  /* The real audio thread's stack cannot be DONTFORK: glibc's fork() walks
   * the descriptor at the top of every user-supplied stack in the child, and
   * would crash there. This harness forks with a raw clone that skips glibc,
   * so it can shield its stack and leave only the engine's own memory
   * exposed — which is the thing under test. */
  a->stack = mmap(NULL, RT_STACK_BYTES, PROT_READ | PROT_WRITE,
                  MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
  if (a->stack == MAP_FAILED || a->in == NULL || a->out == NULL) return 0;
  madvise(a->stack, RT_STACK_BYTES, MADV_DONTFORK);
  /* What le_miniaudio_start does before the device thread's first block. */
  le_platform_prefault_audio_code();
  pthread_attr_t attr;
  pthread_attr_init(&attr);
  pthread_attr_setstack(&attr, a->stack, RT_STACK_BYTES);
  const int ok = pthread_create(&a->thread, &attr, rt_audio_main, a) == 0;
  pthread_attr_destroy(&attr);
  return ok;
}

/* Runs [blocks] callbacks of [level] input on the audio thread and waits. */
static void rt_run(rt_audio_thread* a, int blocks, float level) {
  pthread_mutex_lock(&a->mu);
  a->level = level;
  a->blocks_wanted = blocks;
  pthread_cond_broadcast(&a->cv);
  while (a->blocks_wanted != 0) pthread_cond_wait(&a->cv, &a->mu);
  pthread_mutex_unlock(&a->mu);
}

static void rt_audio_stop(rt_audio_thread* a) {
  pthread_mutex_lock(&a->mu);
  a->blocks_wanted = -1;
  pthread_cond_broadcast(&a->cv);
  pthread_mutex_unlock(&a->mu);
  pthread_join(a->thread, NULL);
  const unsigned char* low = (const unsigned char*)a->stack;
  while (low < a->painted_top && *low == RT_PAINT) ++low;
  a->deepest = (size_t)(a->painted_top - low) + 4096;
  munmap(a->stack, RT_STACK_BYTES);
  le_rt_free(a->in);
  le_rt_free(a->out);
  pthread_mutex_destroy(&a->mu);
  pthread_cond_destroy(&a->cv);
}

/* fork() as the kernel sees it — page tables copied, every copied private
 * page write-protected in the parent — without glibc's child-side work, which
 * would trip over the harness thread's shielded stack. The child exits at
 * once; the parent's pages stay write-protected until written, so the next
 * write to any unshielded page faults exactly as it would after Dart's fork
 * (docs/brainstorm/2026-10-19-no-fork-helpers-brainstorm-doc.md). */
static void rt_fork(void) {
  const long pid = syscall(SYS_clone, (unsigned long)SIGCHLD, 0L, 0L, 0L, 0L);
  if (pid == 0) syscall(SYS_exit_group, 0L);
  if (pid > 0) waitpid((pid_t)pid, NULL, 0);
}

/* One scenario step: optionally fork, then run [blocks] callbacks. */
static void rt_step(rt_audio_thread* a, int fork_first, int blocks, float level) {
  if (fork_first) rt_fork();
  rt_run(a, blocks, level);
}

/* The whole performance: grid-defining take, overdub passes with per-pass
 * undo layers, punch-out drain, undo/redo, FX enable/disable/retype on lanes
 * and a monitor, a quantized arm that fires on a second track, a second
 * overdub. The control thread does what the app does between callbacks. */
static size_t g_rt_deepest_stack = 0;

static long rt_run_performance(int fork_first, int shielded, long* worst,
                               long* blocks) {
  /* Unshielded: every allocation of the run skips MADV_DONTFORK, which is
   * what the engine's memory was before #900. The control case. */
  if (!shielded) le_rt_set_fork_shield_failure_for_test(1);
  le_engine* e = le_engine_create();
  const int loop_blocks = 48000 / 2 / RT_BLOCK; /* a 0.5 s loop */
  CHECK(le_engine_configure(e, 48000, 2, 2, 48000 * 10) == LE_OK);
  CHECK(set_lane_count_and_publish(e, 0, 2) == LE_OK); /* a stereo track */
  CHECK(le_engine_set_lane_fx(e, 0, 0, 0, LE_FX_DELAY) == LE_OK);
  CHECK(le_engine_set_lane_fx(e, 0, 1, 0, LE_FX_REVERB) == LE_OK);
  CHECK(le_engine_set_lane_fx_count(e, 0, 0, 1, 0) == LE_OK);
  CHECK(le_engine_set_lane_fx_count(e, 0, 1, 1, 0) == LE_OK);
  CHECK(le_engine_set_monitor_input(e, 0, 1) == LE_OK);
  CHECK(le_engine_set_monitor_input_fx(e, 0, 0, LE_FX_ECHO) == LE_OK);
  CHECK(le_engine_set_monitor_input_fx_count(e, 0, 1) == LE_OK);

  rt_audio_thread a;
  CHECK(rt_audio_start(&a, e));
  le_snapshot s;

  rt_step(&a, fork_first, 8, 0.0f); /* idle, monitoring through the echo */

  /* The defining take on track 0, then its finalize. */
  CHECK(le_engine_record(e, 0) == LE_OK);
  rt_step(&a, fork_first, loop_blocks, 0.5f);
  CHECK(le_engine_record(e, 0) == LE_OK);
  rt_step(&a, fork_first, loop_blocks, 0.0f);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_PLAYING);

  /* Overdub three passes; the poll between passes files each layer and posts
   * the next shadow, as the app's snapshot poll does. */
  CHECK(le_engine_record(e, 0) == LE_OK);
  for (int pass = 0; pass < 3; ++pass) {
    rt_step(&a, fork_first, loop_blocks, 0.25f);
    le_engine_get_snapshot(e, &s);
  }
  /* Punch out mid-pass: the remainder drains live -> shadow on the callback. */
  rt_step(&a, fork_first, loop_blocks / 3, 0.25f);
  CHECK(le_engine_record(e, 0) == LE_OK);
  for (int k = 0; k < 8; ++k) {
    rt_step(&a, fork_first, loop_blocks / 4, 0.0f);
    le_engine_get_snapshot(e, &s);
  }
  CHECK(s.tracks[0].undo_depth >= 3);

  /* FX: disable, re-enable (the callback clears the rings on re-enable),
   * retype a slot to the octaver, grow the chain. */
  CHECK(le_engine_set_lane_fx_enabled(e, 0, 0, 0, 0) == LE_OK);
  rt_step(&a, fork_first, loop_blocks / 2, 0.0f);
  CHECK(le_engine_set_lane_fx_enabled(e, 0, 0, 0, 1) == LE_OK);
  rt_step(&a, fork_first, loop_blocks / 2, 0.0f);
  CHECK(le_engine_set_lane_fx(e, 0, 1, 1, LE_FX_OCTAVER) == LE_OK);
  CHECK(le_engine_set_lane_fx_count(e, 0, 1, 2, 0) == LE_OK);
  rt_step(&a, fork_first, loop_blocks, 0.0f);
  CHECK(le_engine_set_monitor_input_fx(e, 0, 0, LE_FX_REVERB) == LE_OK);
  rt_step(&a, fork_first, loop_blocks / 2, 0.3f);

  /* Undo and redo the newest layer. */
  CHECK(le_engine_undo(e, 0) == LE_OK);
  rt_step(&a, fork_first, loop_blocks / 2, 0.0f);
  CHECK(le_engine_redo(e, 0) == LE_OK);
  rt_step(&a, fork_first, loop_blocks / 2, 0.0f);

  /* A quantized take on track 1: armed now, fired by the callback at the
   * next loop top, recorded for a loop, finished by the next press. */
  CHECK(timing_gate(e, 1) == LE_OK);
  CHECK(le_engine_record(e, 1) == LE_OK);
  rt_step(&a, fork_first, 2 * loop_blocks, 0.4f);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[1].state == LE_TRACK_RECORDING);
  CHECK(le_engine_record(e, 1) == LE_OK);
  rt_step(&a, fork_first, 2 * loop_blocks, 0.0f);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[1].state == LE_TRACK_PLAYING);

  /* A lane added to a playing track: the callback reads its live slot from
   * the next block, over the whole loop. */
  CHECK(le_engine_set_lane_count(e, 1, 2) == LE_OK);
  rt_step(&a, fork_first, 2 * loop_blocks, 0.0f);

  /* And one more overdub on track 0 over the quantized grid. */
  CHECK(le_engine_record(e, 0) == LE_OK);
  rt_step(&a, fork_first, 2 * loop_blocks, 0.2f);
  le_engine_get_snapshot(e, &s);
  CHECK(le_engine_record(e, 0) == LE_OK);
  rt_step(&a, fork_first, 2 * loop_blocks, 0.0f);

  rt_audio_stop(&a);
  *worst = a.worst_block;
  *blocks = a.blocks_run;
  if (a.deepest > g_rt_deepest_stack) g_rt_deepest_stack = a.deepest;
  le_engine_destroy(e);
  le_rt_set_fork_shield_failure_for_test(0);
  return a.faults;
}

static void test_audio_thread_takes_no_page_faults(void) {
  printf("test_audio_thread_takes_no_page_faults\n");
  long worst = 0;
  long blocks = 0;
  const long faults = rt_run_performance(0, 1, &worst, &blocks);
  printf("  %ld blocks: %ld faults on the audio thread (worst block %ld); "
         "deepest stack %zu KB\n", blocks, faults, worst,
         g_rt_deepest_stack >> 10);
  CHECK(blocks > 0);
  CHECK(faults == 0);
  /* data_callback prefaults 256 KB (engine_miniaudio.c); the callback must
   * stay well inside it. */
  CHECK(g_rt_deepest_stack < 128u * 1024u);
}

static void test_audio_thread_takes_no_page_faults_across_forks(void) {
  printf("test_audio_thread_takes_no_page_faults_across_forks\n");
  long worst = 0;
  long blocks = 0;
  const long faults = rt_run_performance(1, 1, &worst, &blocks);
  printf("  %ld blocks, a fork before each of 26 steps: %ld faults on the "
         "audio thread (worst block %ld)\n", blocks, faults, worst);
  CHECK(blocks > 0);
  CHECK(faults == 0);

  /* The control: the same run with the fork shield off must fault, or the
   * two zeros above prove nothing about this kernel and this counter. */
  long cworst = 0;
  long cblocks = 0;
  const long cfaults = rt_run_performance(1, 0, &cworst, &cblocks);
  printf("  control, shield off: %ld faults on the audio thread (worst block "
         "%ld)\n", cfaults, cworst);
  CHECK(cfaults > 0);
}

/* A defining take much longer than the head its slot starts with, at the
 * appliance rate and cap: the background prefaulter follows the write head,
 * and the punch-in after it takes its armed shadow from the lane's standby.
 * The harness runs faster than real time, so it lets the prefaulter catch up
 * once per second of audio, as wall-clock time does on a device. */
static void test_long_take_is_followed_by_the_prefaulter(void) {
  printf("test_long_take_is_followed_by_the_prefaulter\n");
  const int32_t rate = 96000;
  const int sec_blocks = rate / RT_BLOCK;
  le_engine* e = le_engine_create();
  CHECK(le_engine_configure(e, rate, 2, 2, rate * 60) == LE_OK);
  CHECK(set_lane_count_and_publish(e, 0, 2) == LE_OK);
  rt_audio_thread a;
  CHECK(rt_audio_start(&a, e));
  CHECK(le_engine_record(e, 0) == LE_OK);
  for (int sec = 0; sec < 8; ++sec) {
    le_prefault_tick(e);
    rt_run(&a, sec_blocks, 0.3f);
  }
  CHECK(le_engine_record(e, 0) == LE_OK); /* an 8 s loop */
  le_snapshot s;
  for (int k = 0; k < 4; ++k) { /* polls: the standby is made and filled */
    le_engine_get_snapshot(e, &s);
    le_prefault_tick(e);
    rt_run(&a, sec_blocks / 4, 0.0f);
  }
  CHECK(e->spares[0][0].standby != NULL);
  CHECK(atomic_load(&e->spares[0][0].a_standby_ready) == 1);
  CHECK(le_engine_record(e, 0) == LE_OK); /* punch in */
  CHECK(e->spares[0][0].standby == NULL); /* it became the shadow */
  for (int sec = 0; sec < 9; ++sec) {
    le_engine_get_snapshot(e, &s);
    le_prefault_tick(e);
    rt_run(&a, sec_blocks, 0.2f);
  }
  CHECK(le_engine_record(e, 0) == LE_OK);
  rt_run(&a, sec_blocks + sec_blocks / 3, 0.0f); /* the playhead mid-loop */
  /* An immediate take over the loop on track 1: it starts writing at the
   * playhead, not at frame 0, into a slot just replaced by a fresh mapping. */
  CHECK(le_engine_record(e, 1) == LE_OK);
  for (int sec = 0; sec < 10; ++sec) {
    le_prefault_tick(e);
    rt_run(&a, sec_blocks, 0.25f);
  }
  CHECK(le_engine_record(e, 1) == LE_OK);
  rt_run(&a, sec_blocks, 0.0f);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[1].state == LE_TRACK_PLAYING);
  rt_audio_stop(&a);
  printf("  %ld blocks: %ld faults on the audio thread (worst block %ld)\n",
         a.blocks_run, a.faults, a.worst_block);
  CHECK(a.faults == 0);
  le_engine_destroy(e);
}

/* Runs [blocks] callbacks on the audio thread at the device's own pace, so
 * the background prefaulter races a real-time write head, not a test that
 * waits for it. */
static void rt_run_paced(rt_audio_thread* a, int blocks, float level,
                         int32_t rate) {
  const int chunk = rate / 10 / RT_BLOCK; /* 100 ms of audio */
  for (int done = 0; done < blocks; done += chunk) {
    struct timespec t0, t1;
    clock_gettime(CLOCK_MONOTONIC, &t0);
    rt_run(a, chunk, level);
    clock_gettime(CLOCK_MONOTONIC, &t1);
    const long spent =
        (t1.tv_sec - t0.tv_sec) * 1000000000L + (t1.tv_nsec - t0.tv_nsec);
    const long due = 100000000L;
    if (spent < due) {
      struct timespec rest = {0, due - spent};
      nanosleep(&rest, NULL);
    }
  }
}

/* A take over a long loop started late in it: the second at the playhead is
 * faulted in on the press, the background walk starts right after it (not at
 * frame 0, from where the write head would be long gone), and the frames
 * before the playhead are a separate fill. Then the take runs at real-time
 * pace against the real prefaulter thread, with no help from the test. */
static void test_late_take_is_walked_from_the_playhead(void) {
  printf("test_late_take_is_walked_from_the_playhead\n");
  const int32_t rate = 96000;
  const int sec_blocks = rate / RT_BLOCK;
  le_engine* e = le_engine_create();
  CHECK(le_engine_configure(e, rate, 2, 2, rate * 60) == LE_OK);
  rt_audio_thread a;
  CHECK(rt_audio_start(&a, e));
  CHECK(le_engine_record(e, 0) == LE_OK); /* a 40 s loop, fast */
  for (int sec = 0; sec < 40; ++sec) {
    le_prefault_tick(e);
    rt_run(&a, sec_blocks, 0.3f);
  }
  CHECK(le_engine_record(e, 0) == LE_OK);
  rt_run(&a, 35 * sec_blocks, 0.0f); /* the playhead at about 35 s */
  le_snapshot s;
  le_engine_get_snapshot(e, &s); /* a poll: the zero spares are made */
  le_prefault_tick(e);
  const int32_t p = load_i32(&e->a_master_pos);
  CHECK(p > 30 * rate);
  CHECK(le_engine_record(e, 1) == LE_OK); /* immediate, at the playhead */
  le_prefault_pass_for_test(e); /* one chunk per job */
  const float* b = e->tracks[1].lanes[0].pool[0];
  const size_t head = (size_t)rate * LE_PREFAULT_HEAD_SECONDS;
  const size_t chunk = (size_t)64 << 10; /* LE_PREFAULT_CHUNK_BYTES */
  CHECK(rt_resident_pages(b + p, head * sizeof(float)) >=
        rt_pages(b + p, head * sizeof(float)) - 2); /* on the press */
  /* the walk's first chunk, which starts a second past the playhead (less
   * the block of margin the press takes), wherever the playhead is */
  CHECK(rt_resident_pages(b + p + head, chunk / 2) ==
        rt_pages(b + p + head, chunk / 2));
  /* The old live slot is retired, not unmapped, until a block publishes. */
  CHECK(e->retired_count > 0);
  rt_run_paced(&a, 3 * sec_blocks, 0.25f, rate); /* the real thread only */
  le_engine_get_snapshot(e, &s);
  CHECK(e->retired_count == 0);
  CHECK(le_engine_record(e, 1) == LE_OK);
  rt_run(&a, sec_blocks, 0.0f);
  rt_audio_stop(&a);
  printf("  %ld blocks: %ld faults on the audio thread (worst block %ld)\n",
         a.blocks_run, a.faults, a.worst_block);
  CHECK(a.faults == 0);
  le_engine_destroy(e);
}

/* Standbys stay inside LE_STANDBY_BUDGET_BYTES: a track whose standbys would
 * exceed it gets none (its punch-in takes the fresh path, and still does not
 * fault), and an imported session, with no captures, keeps none. */
static void test_standbys_stay_in_budget(void) {
  printf("test_standbys_stay_in_budget\n");
  const int32_t rate = 96000;
  const int sec_blocks = rate / RT_BLOCK;
  le_engine* e = le_engine_create();
  CHECK(le_engine_configure(e, rate, 8, 2, rate * 60) == LE_OK);
  CHECK(set_lane_count_and_publish(e, 0, 8) == LE_OK);
  rt_audio_thread a;
  CHECK(rt_audio_start(&a, e));
  CHECK(le_engine_record(e, 0) == LE_OK); /* 8 lanes x 30 s = 92 MB > 64 MB */
  for (int sec = 0; sec < 30; ++sec) {
    le_prefault_tick(e);
    rt_run(&a, sec_blocks, 0.3f);
  }
  CHECK(le_engine_record(e, 0) == LE_OK);
  le_snapshot s;
  for (int k = 0; k < 3; ++k) {
    rt_run(&a, sec_blocks / 4, 0.0f);
    le_engine_get_snapshot(e, &s);
    le_prefault_tick(e);
  }
  size_t held = 0;
  for (int t = 0; t < LE_MAX_TRACKS; ++t)
    for (int l = 0; l < LE_MAX_LANES; ++l)
      held += (size_t)e->spares[t][l].standby_cap * sizeof(float);
  CHECK(held <= LE_STANDBY_BUDGET_BYTES);
  CHECK(e->spares[0][0].standby == NULL); /* over budget: none */
  rt_run(&a, 15 * sec_blocks, 0.0f); /* the playhead mid-loop */
  le_engine_get_snapshot(e, &s);
  /* Punch in on the fresh path: the second of its shadow at the playhead is
   * faulted in on the press, the rest by the real thread, in real time. */
  CHECK(le_engine_record(e, 0) == LE_OK);
  rt_run_paced(&a, 4 * sec_blocks, 0.2f, rate);
  CHECK(le_engine_record(e, 0) == LE_OK);
  rt_run(&a, sec_blocks, 0.0f);
  rt_audio_stop(&a);
  printf("  standbys held: %zu KB; %ld blocks, %ld faults on the audio thread\n",
         held >> 10, a.blocks_run, a.faults);
  CHECK(a.faults == 0);
  le_engine_destroy(e);
}

/* A take over a loop pressed in its last 20 ms with a fixed multiple of 1:
 * its write head wraps to frame 0 within the second, into a zeroed slot no
 * page of which was touched. The wrapped part is faulted in on the press,
 * not left to the background, and the take then runs in real time against
 * the real prefaulter thread. THP is off for the run: a huge page around
 * the slot's header page would make frame 0 resident by itself. */
static void test_take_pressed_at_the_loop_end_wraps_faulted_in(void) {
  printf("test_take_pressed_at_the_loop_end_wraps_faulted_in\n");
  CHECK(prctl(PR_SET_THP_DISABLE, 1, 0, 0, 0) == 0);
  const int32_t rate = 96000;
  const int sec_blocks = rate / RT_BLOCK;
  const int32_t loop = 10 * rate;
  le_engine* e = le_engine_create();
  CHECK(le_engine_configure(e, rate, 2, 2, rate * 60) == LE_OK);
  CHECK(set_lane_count_and_publish(e, 1, 2) == LE_OK);
  CHECK(le_engine_set_track_multiple(e, 1, 1) == LE_OK);
  rt_audio_thread a;
  CHECK(rt_audio_start(&a, e));
  CHECK(le_engine_record(e, 0) == LE_OK);
  for (int sec = 0; sec < 10; ++sec) {
    le_prefault_tick(e);
    rt_run(&a, sec_blocks, 0.3f);
  }
  CHECK(le_engine_record(e, 0) == LE_OK); /* a 10 s loop */
  rt_run(&a, sec_blocks, 0.0f);
  le_snapshot s;
  le_engine_get_snapshot(e, &s); /* a poll: the zero spares are made */
  CHECK(load_i32(&e->a_master_len) == loop);
  const int32_t late = loop - rate / 50; /* 20 ms before the loop end */
  int32_t p = load_i32(&e->a_master_pos);
  if (p > late) {
    rt_run(&a, (loop - p) / RT_BLOCK + 1, 0.0f);
    p = load_i32(&e->a_master_pos);
  }
  rt_run(&a, (late - p) / RT_BLOCK, 0.0f);
  p = load_i32(&e->a_master_pos);
  CHECK(p >= late - RT_BLOCK && p < loop);
  CHECK(le_engine_record(e, 1) == LE_OK); /* immediate, at the playhead */
  const size_t head = (size_t)rate * LE_PREFAULT_HEAD_SECONDS;
  const size_t past = (size_t)p + head - (size_t)loop; /* past the wrap */
  for (int l = 0; l < 2; ++l) {
    const float* b = e->tracks[1].lanes[l].pool[0];
    CHECK(rt_resident_pages(b, past * sizeof(float)) ==
          rt_pages(b, past * sizeof(float)));
  }
  rt_run_paced(&a, 3 * sec_blocks, 0.25f, rate); /* the real thread only */
  CHECK(le_engine_record(e, 1) == LE_OK);
  rt_run(&a, sec_blocks, 0.0f);
  rt_audio_stop(&a);
  printf("  pressed %d ms before the loop end: %ld blocks, %ld faults on the "
         "audio thread (worst block %ld)\n", (int)((loop - p) * 1000 / rate),
         a.blocks_run, a.faults, a.worst_block);
  CHECK(a.faults == 0);
  le_engine_destroy(e);
  CHECK(prctl(PR_SET_THP_DISABLE, 0, 0, 0, 0) == 0);
}

/* A freed lane buffer is never faulted again: a slot with a background job
 * on it is regrown (le_lane_ensure_slot frees the old buffer) while the
 * thread works on it, and a new mapping placed where the old one was is
 * still untouched a while later. Before every free went through
 * le_free_audio_buffer the job outlived the buffer, and the thread faulted,
 * and locked, whatever was mapped there next. THP is off for the run, so a
 * fault touches one page, not a huge one. */
static void test_freed_buffer_is_never_faulted_again(void) {
  printf("test_freed_buffer_is_never_faulted_again\n");
  CHECK(prctl(PR_SET_THP_DISABLE, 1, 0, 0, 0) == 0);
  le_engine* e = le_engine_create();
  CHECK(le_engine_configure(e, 48000, 2, 2, 48000 * 10) == LE_OK);
  le_lane* ln = &e->tracks[0].lanes[0];
  const int slot = LE_POOL_SLOTS - 1; /* not live, not posted */
  const int32_t frames = 64 << 18;   /* 64 MB */
  int reused = 0;
  for (int round = 0; round < 4; ++round) {
    CHECK(le_lane_ensure_slot(e, ln, slot, frames + round * 2) == LE_SLOT_FRESH);
    float* b = ln->pool[slot];
    le_prefault_buffer(e, b, frames, NULL);
    struct timespec ms = {0, 1000000L}; /* the thread is into it by now */
    nanosleep(&ms, NULL);
    CHECK(le_lane_ensure_slot(e, ln, slot, frames + round * 2 + 1) ==
          LE_SLOT_FRESH); /* maps the new one, then frees b */
    const size_t total = (size_t)frames * sizeof(float) + ((size_t)1 << 20);
    unsigned char* m = (unsigned char*)mmap(NULL, total, PROT_READ | PROT_WRITE,
                                            MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    CHECK(m != MAP_FAILED);
    if (m == MAP_FAILED) break;
    const unsigned char* bb = (const unsigned char*)b;
    reused += bb >= m && bb < m + total;
    struct timespec wait = {0, 50000000L};
    nanosleep(&wait, NULL);
    CHECK(rt_resident_pages(m, total) == 0);
    munmap(m, total);
  }
  printf("  4 rounds, the freed address mapped again in %d\n", reused);
  le_engine_destroy(e);
  CHECK(prctl(PR_SET_THP_DISABLE, 0, 0, 0, 0) == 0);
}

/* A backend miniaudio does not drive from a worker thread of its own (JACK)
 * leaves device.thread zero; the stack preparation at device open must skip
 * it, where pthread_getattr_np(0) would crash. */
static void test_device_open_skips_a_backend_without_a_thread(void) {
  printf("test_device_open_skips_a_backend_without_a_thread\n");
  le_engine* e = le_engine_create();
  CHECK(le_engine_configure(e, 48000, 2, 2, 48000 * 10) == LE_OK);
  CHECK(e->device.thread == (ma_thread)0);
  e->device_initialised = 1; /* as after an asynchronous backend's init */
  le_platform_after_device_open(e);
  e->device_initialised = 0;
  le_engine_destroy(e);
}

/* The engine counts every glibc fork() of the process (#1367). Run with no
 * harness thread alive: a glibc fork child would trip over its stack. */
static void test_engine_counts_forks(void) {
  printf("test_engine_counts_forks\n");
  le_engine* e = le_engine_create(); /* registers the handler, once */
  const unsigned before = le_platform_fork_count();
  const pid_t pid = fork();
  if (pid == 0) _exit(0);
  CHECK(pid > 0);
  if (pid > 0) waitpid(pid, NULL, 0);
  CHECK(le_platform_fork_count() == before + 1u);
  le_engine_destroy(e);
}

#endif /* LE_RT_FAULT_TESTS */

static void run_rt_memory_tests(void) {
  test_rt_alloc_contract();
#if LE_RT_FAULT_TESTS
  test_rt_alloc_touches_nothing_until_prefaulted();
  test_engine_audio_buffers_are_fork_shielded();
  test_lane_slots_cost_nothing_until_a_take();
  test_cap_is_bounded_and_removed_lanes_are_freed();
  test_audio_buffers_are_locked();
  test_audio_thread_takes_no_page_faults();
  test_audio_thread_takes_no_page_faults_across_forks();
  test_long_take_is_followed_by_the_prefaulter();
  test_late_take_is_walked_from_the_playhead();
  test_standbys_stay_in_budget();
  test_take_pressed_at_the_loop_end_wraps_faulted_in();
  test_freed_buffer_is_never_faulted_again();
  test_device_open_skips_a_backend_without_a_thread();
  test_engine_counts_forks();
#endif
}

#endif /* SEGNO_TEST_ENGINE_RT_MEMORY_H */
