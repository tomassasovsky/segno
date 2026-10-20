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

#include "rt_alloc.h"

#if defined(__linux__) && !LE_RT_ALLOC_USES_HEAP
#define LE_RT_FAULT_TESTS 1
#include <signal.h>       /* SIGCHLD for the raw clone */
#include <sys/mman.h>     /* mincore, mmap for the shielded stack */
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
}

#if LE_RT_FAULT_TESTS

/* ---- 2. memory policy (Linux, mapping path) ---- */

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
  CHECK(rt_resident_pages(p, n) <= 1);
  CHECK(smaps_mapping_is_dontcopy(p) == 1); /* fork() skips it */
  le_rt_prefault(p, n);
  CHECK(rt_resident_pages(p, n) == rt_pages(p, n));
  le_rt_free(p);

  /* The prefaulted form, used for everything written from the start. */
  float* q = (float*)le_rt_alloc_prefaulted(n);
  CHECK(q != NULL && rt_resident_pages(q, n) == rt_pages(q, n));
  CHECK(smaps_mapping_is_dontcopy(q) == 1);
  le_rt_free(q);
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
  const int32_t cap = 96000 * 60; /* the appliance default: 60 s at 96 kHz */
  CHECK(le_engine_configure(e, 96000, 8, 2, cap) == LE_OK);
  const long rss0 = rt_rss_kb();
  for (int32_t t = 0; t < e->track_count; ++t) {
    CHECK(set_lane_count_and_publish(e, t, LE_MAX_LANES) == LE_OK);
  }
  const long rss1 = rt_rss_kb();
  const size_t slot_bytes = (size_t)cap * sizeof(float);
  size_t touched = 0;
  for (int32_t t = 0; t < e->track_count; ++t) {
    for (int l = 0; l < LE_MAX_LANES; ++l) {
      const float* b = e->tracks[t].lanes[l].pool[0];
      CHECK(b != NULL);
      if (b != NULL) touched += rt_resident_pages(b, slot_bytes);
    }
  }
  /* At most the header page of each of the 64 slots. */
  CHECK(touched <= (size_t)e->track_count * LE_MAX_LANES);
  CHECK(rss1 - rss0 < 16 * 1024); /* was 64 x 23 MB = 1.4 GB */
  printf("  %d tracks x %d lanes at 96 kHz / 60 s: RSS +%ld KB for %zu MB of "
         "slots\n", e->track_count, LE_MAX_LANES, rss1 - rss0,
         ((size_t)e->track_count * LE_MAX_LANES * slot_bytes) >> 20);

  /* A take on track 0 prefaults all 8 of its live slots, and only those. */
  CHECK(le_engine_record(e, 0) == LE_OK);
  for (int l = 0; l < LE_MAX_LANES; ++l) {
    const float* b = e->tracks[0].lanes[l].pool[0];
    CHECK(rt_resident_pages(b, slot_bytes) == rt_pages(b, slot_bytes));
  }
  CHECK(rt_resident_pages(e->tracks[1].lanes[0].pool[0], slot_bytes) <= 1);
  printf("  after a take on track 0: RSS +%ld KB\n", rt_rss_kb() - rss0);
  le_engine_destroy(e);
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
  printf("  %ld blocks, a fork before each of 25 steps: %ld faults on the "
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
  test_audio_thread_takes_no_page_faults();
  test_audio_thread_takes_no_page_faults_across_forks();
  test_engine_counts_forks();
#endif
}

#endif /* SEGNO_TEST_ENGINE_RT_MEMORY_H */
