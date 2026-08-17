/*
 * perf_drain.c — see perf_drain.h.
 *
 * CONTROL-THREAD OWNERSHIP for le_perf_drain_start/stop (called only from
 * engine_commands.c's le_perf_arm/disarm and engine.c's reconfigure hook).
 * Everything between start and stop runs on the dedicated drain thread this
 * file spawns; it never touches the audio callback or pushes to the command
 * ring (that would be a second producer on control's SPSC ring).
 *
 * Sidecar writes are hand-rolled (no JSON library in this tree): the schema is
 * a flat handful of fields plus a small gap array, well within what snprintf
 * can build in one bounded pass. Every flush writes a fresh temp file and
 * atomically renames it over performance.json, so a reader never sees a
 * half-written sidecar.
 *
 * THE STEADY-STATE CYCLE ALLOCATES NOTHING (#722), and this is hygiene, not a
 * click fix — the distinction matters, because the first draft of this change
 * claimed a mechanism that measurement then disproved.
 *
 * What was here: a per-cycle malloc + free of LE_PD_JSON_BUF (512 KB) for the
 * sidecar, plus a per-cycle fopen/fclose of the temp file. The claim was
 * that 512 KB sits above glibc's 128 KB mmap threshold, so each cycle was an
 * mmap + munmap, and each munmap a TLB-shootdown IPI to every core — four
 * times a second, into a real-time audio callback. That is WRONG. glibc's
 * mmap threshold is DYNAMIC: the first free of a large mmap'd chunk raises
 * mp_.mmap_threshold to that chunk's size, so every later same-size request
 * comes out of the (now grown) arena. Measured with mallinfo2 sampled while
 * the buffer was held, gcc 13 / glibc 2.36, -O0, buffer forced to escape:
 *
 *   cycle 0: hblks=1 hblkhd=528384 arena=135168   <- one mmap, once
 *   cycle 1: hblks=0 hblkhd=0      arena=663552   <- arena, no syscall
 *   cycle 2..5: identical to cycle 1
 *
 * So the allocator churn was once per capture session, not four times a
 * second, and nothing here is established as the cause of #722's clicks.
 *
 * What IS true, and why the change still earns its place: this is a
 * background writer sharing a machine with a real-time audio callback, so its
 * cycle should be boring. Removing the per-cycle allocation drops a 512 KB
 * chunk split/merge under the malloc arena lock (a lock the audio thread must
 * never be made to wait on, and which any future allocation on this thread
 * would contend for), drops the stdio FILE object and stream buffer the
 * per-cycle fopen created, and — the permanent one — makes "this loop does not
 * call the allocator" a checkable invariant instead of a hope. Every buffer
 * the cycle needs is now owned by le_perf_drain (allocated at start, freed at
 * stop) or lives on this thread's stack, and the sidecar goes out through a
 * raw descriptor. test_engine_core.c's
 * test_perf_drain_steady_state_cycle_is_allocation_free interposes the
 * allocator around several live cycles and asserts zero calls — and separately
 * interposes fopen, because on macOS an allocation made INSIDE libc (a FILE
 * object and its stream buffer) never binds to the executable's malloc and so
 * is invisible to the first counter. Keep BOTH true when adding to this file:
 * no allocation, and no stdio stream opened per cycle.
 *
 * RETIRED LAYERS ARE THE ONE EXCEPTION, and the exception really does allocate
 * ON THIS THREAD — not just free what another thread allocated. Per retired
 * layer, le_pd_write_staged_layer does a fopen/fclose right here in the cycle:
 * the same per-call FILE object and lazily-allocated stream buffer this change
 * just took off the sidecar path, so a performer doing overdub passes makes the
 * drain thread take the arena lock once per retired layer, inside the cycle.
 * (It also frees the lane PCM the CONTROL thread malloc'd for that pass — that
 * half is a free, not an allocation.) It is left as-is because it is
 * user-paced rather than steady state: it fires on punch-outs, not four times
 * a second, and only while the performer is actually stacking layers. The
 * allocation test excludes this path by construction (no retired layer in its
 * fixture) and says so in its SCOPE note; if that path ever becomes
 * per-cycle, it needs the same treatment the sidecar just got.
 */
#include "perf_drain.h"

#include <errno.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "audio_ring.h"      /* le_audio_ring_pop */
#include "engine_private.h"  /* le_engine, le_perf_capture,
                              * LE_MAX_MONITORED_INPUTS */
#include "layer_staging_ring.h" /* le_layer_staging_ring_pop (retired-layer persistence) */
#include "perf_log_ring.h"   /* le_perf_log_ring_pop (performance event log) */

#if defined(_WIN32)
#include <direct.h> /* _mkdir */
#include <fcntl.h>  /* _O_* */
#include <io.h>     /* _open / _write / _close */
#include <sys/stat.h> /* _S_IREAD / _S_IWRITE */
#include <windows.h>
#else
#include <fcntl.h>    /* open, O_* */
#include <pthread.h>
#include <sched.h>    /* SCHED_OTHER, sched_get_priority_min */
#include <sys/stat.h> /* mkdir */
#include <time.h>     /* nanosleep */
#include <unistd.h>   /* write, close */
#if defined(__linux__)
#include <sys/resource.h> /* setpriority, PRIO_PROCESS */
#endif
#endif

/* ---- tuning ---- */
#define LE_PD_FLUSH_MS 250   /* drain + sidecar flush cadence */
#define LE_PD_POLL_MS 10     /* stop-flag poll granularity (snappy shutdown) */
#define LE_PD_MAX_GAPS 128   /* recorded gap entries; beyond this, frames are
                              * still silence-filled, just not individually
                              * logged in the sidecar */
#define LE_PD_PATH_MAX 960   /* capture_dir length; +32 headroom for filenames */
#define LE_PD_FULL_PATH_MAX (LE_PD_PATH_MAX + 32)
#define LE_PD_JSON_BUF 524288 /* generous for LE_PD_MAX_GAPS + LE_PD_MAX_LAYERS
                               * entries + fields (each layer entry runs to
                               * ~150 bytes; LE_PD_MAX_LAYERS of them is
                               * ~300KB at the current LE_MAX_TRACKS *
                               * LE_POOL_SLOTS headroom) — the loop guards in
                               * le_pd_write_sidecar bail out safely if this
                               * ever isn't enough, rather than truncating
                               * silently or overrunning the buffer */
#define LE_PD_SCRATCH_SAMPLES 2048 /* per-drain-cycle pop buffer, in samples */

/* events.log wire format (docs/design/performance-event-log-format.md): a
 * 12-byte header (4-byte magic "PLEV", uint32 version, int32 sample_rate)
 * followed by fixed-size 28-byte entries (uint64 frame, int32 code, 16 bytes
 * of raw union payload — le_command's union has no internal padding of its
 * own, every arm being plain 4-byte-aligned int32_t/float/uint32_t fields).
 * The 28 bytes ARE dumped from memory (frame via one memcpy, code + union via
 * two more) — what le_pd_write_log_entry avoids is `sizeof(le_perf_log_entry)`
 * itself, which is 32 (not 28): the struct's 8-byte alignment (from its
 * uint64_t frame) pads 4 trailing bytes onto the end that a naive
 * `fwrite(&entry, sizeof(entry), 1, f)` would write as uninitialised garbage.
 * Writing exactly 28 explicit bytes sidesteps that trailing pad; it is not a
 * claim that every byte is otherwise reinterpreted independent of this
 * process's compiler — this is a private, same-process wire format (both
 * sides compiled together), not a cross-language ABI. Part 9's .als
 * generator is meant to parse the resulting bytes without importing engine
 * code, using the per-code arm layout documented in the format doc. */
#define LE_PD_EVENTS_ENTRY_BYTES 28 /* 8 (frame) + 4 (code) + 16 (union payload) */

#define LE_PD_MAX_LAYERS \
  LE_LAYER_STAGING_RING_CAPACITY /* recorded layer-manifest entries; matches
                                  * the ring's capacity 1:1 so a full ring
                                  * never has to drop a manifest entry */
#define LE_PD_LAYER_CHUNK_FRAMES 512 /* interleave-and-write in bounded chunks,
                                      * same rationale as le_pd_catch_up's
                                      * zero-fill chunking */

/* ---- portable thread + sleep shim (extends engine_plugin.c's
 * control_sleep_ms one-file-branch-by-platform style to a real joinable
 * thread; see engine_plugin.c for the sibling sleep-only version). ----
 *
 * SCHEDULING (#722). This thread must never be able to take a core away from
 * the audio callback. It is created with an EXPLICIT time-sharing policy —
 * never inheriting the creating (control) thread's — and then asks the OS for
 * a below-normal share, using whichever knob that OS actually honours per
 * thread:
 *
 *   - Linux: the policy stays SCHED_OTHER and the real lever is niceness,
 *     which on Linux is a per-thread attribute; the thread nices ITSELF to
 *     LE_PD_NICE on entry (setpriority(PRIO_PROCESS, 0, ...) addresses the
 *     calling thread there, and lowering a priority never needs privilege).
 *     Doing it from inside the thread is what keeps it per-thread — calling
 *     setpriority from the control thread would nice the whole process,
 *     audio callback included, which is the exact opposite of the intent.
 *   - Darwin: the same attribute IS the drop — SCHED_OTHER's minimum priority
 *     there is 15 against a default of 31. Deliberately NOT a QoS class: the
 *     background QoS classes bring timer coalescing with them, and this
 *     thread's 10 ms poll then stretches far enough to triple the flush
 *     interval — measured at ~750 ms in the native suite — which is not a
 *     cosmetic delay, it is more audio held in rings that are sized for a
 *     250 ms cadence, i.e. manufactured overruns.
 *   - Windows: THREAD_PRIORITY_BELOW_NORMAL on the created handle.
 *
 * THE HEADROOM THIS SPENDS, stated because rejecting QoS above on a measured
 * cadence stretch and then applying nice/priority on none would be an
 * unargued double standard.
 *
 * The budget: le_perf_arm sizes master_ring for LE_PERF_CAPTURE_SECONDS (= 2 s)
 * and the cycle runs every LE_PD_FLUSH_MS (= 250 ms), so a cycle may stretch to
 * 8x its cadence before a ring the audio thread is still filling overruns and
 * le_pd_catch_up starts writing zero-filled silence into the take (#710). That
 * 8x is the whole margin; everything below is spent out of it.
 *
 * What the QoS path spent: ~750 ms observed, 3 of the 8. It spent it on the
 * WAKEUP — timer coalescing defers when this thread runs at all, so the 10 ms
 * poll itself became ~30 ms and the cadence with it. That is the expensive
 * kind, because the deferral is a system policy with no ceiling this code can
 * reason about: the ~750 ms was measured on an IDLE machine, and coalescing
 * windows widen with load and low-power states rather than narrowing.
 *
 * What nice 10 / SCHED_OTHER-15 spends: CPU SHARE ONCE RUNNABLE, not the
 * wakeup. Nothing about them defers a timer. Under CFS, nice 10 is weight
 * 110 against nice 0's 1024 — roughly a 10% share against a saturating
 * nice-0 competitor, which is the pessimistic case a loaded Pi (UI + export +
 * plugin scan) actually presents. The cycle's own work is small and bounded:
 * pop ~250 ms of audio out of the rings (~96 KB/cycle for stereo master at
 * 48 kHz, plus each monitor stem), the fwrites for it, one ~1 KB snprintf pass
 * and one open/write/close/rename for the sidecar — single-digit milliseconds
 * of CPU on the appliance target. At a 10% share, single-digit ms of work
 * takes tens of ms of wall time: ~12% of the 250 ms cadence, ~1.5% of the 2 s
 * ring. Reaching the 8x that actually hurts would need the cycle stretched
 * past 2 s, i.e. two orders of magnitude worse than the share alone explains —
 * a machine on which the audio callback has already failed. And niceness does
 * not starve: CFS still schedules by vruntime, and a thread that sleeps 10 ms
 * out of every 10 ms comes back with a low one, so it is picked up promptly
 * rather than queued behind the hogs.
 *
 * So the margin holds where QoS's did not, for a reason and not just a smaller
 * number: this drop cannot move the wakeup, and the wakeup is what the cadence
 * is made of. What makes that claim CHECKABLE rather than asserted is the
 * monotonic deadline in le_pd_drain_thread_main — before it, the cycle counted
 * assumed sleep, so any stretch this invites would have drifted the cadence
 * with nothing measuring it.
 *
 * It is NEVER raised to a real-time policy: a late sidecar flush is invisible,
 * a late audio callback is a click. Failure to apply any of this is
 * non-fatal — the capture still has to start (a fallback pthread_create with
 * default attrs covers the EPERM-style refusals some hardened kernels give). */
#define LE_PD_NICE 10 /* below-normal share; low enough to always yield to the
                       * audio callback, not so low as to starve on a busy Pi */

#if defined(_WIN32)
typedef HANDLE le_pd_thread_t;

static void le_pd_drain_thread_main(void* arg);

static DWORD WINAPI le_pd_win_trampoline(LPVOID arg) {
  le_pd_drain_thread_main(arg);
  return 0;
}

static int le_pd_thread_start(le_pd_thread_t* out, void* arg) {
  /* CREATE_SUSPENDED so the priority really is set before the thread runs a
   * single instruction. Without it the drop would merely race the new thread,
   * and only the fact that the loop opens with a 10 ms sleep would make it
   * land in time — a coincidence, not a guarantee. */
  *out = CreateThread(NULL, 0, le_pd_win_trampoline, arg, CREATE_SUSPENDED,
                      NULL);
  if (*out == NULL) return 0;
  /* Best-effort: a refusal here costs the priority drop, not the capture. */
  (void)SetThreadPriority(*out, THREAD_PRIORITY_BELOW_NORMAL);
  if (ResumeThread(*out) == (DWORD)-1) {
    /* Should be unreachable for a handle created here and suspended exactly
     * once. If it is ever reached, closing the handle is NOT enough: a
     * suspended thread keeps running-in-name-only forever, holding its stack
     * and this call's `arg` — the le_perf_drain the caller is about to free.
     * TerminateThread is the only way to reap a thread that will never run
     * its own exit; its usual objection (arbitrary state left locked) does
     * not apply to a thread parked before its first instruction, which has
     * taken no lock and allocated nothing. Wait for the terminate to land
     * before reporting failure, so the arm's free() cannot race it. */
    (void)TerminateThread(*out, 0);
    (void)WaitForSingleObject(*out, INFINITE);
    CloseHandle(*out);
    *out = NULL;
    return 0;
  }
  return 1;
}

/* Nothing further to do on the thread itself — the handle-side call above
 * applied the drop while the thread was still suspended. */
static void le_pd_thread_lower_own_priority(void) {}

static void le_pd_thread_join(le_pd_thread_t th) {
  WaitForSingleObject(th, INFINITE);
  CloseHandle(th);
}

static void le_pd_sleep_ms(int ms) { Sleep((DWORD)ms); }

/* Milliseconds on a monotonic clock — never the wall clock, which an NTP step
 * or a manual date change could move backwards under the flush deadline.
 * GetTickCount64 is already 64-bit-since-boot, so there is no wrap to handle;
 * its ~10-16 ms resolution is irrelevant against a 250 ms cadence. */
static uint64_t le_pd_now_ms(void) { return (uint64_t)GetTickCount64(); }

static int le_pd_mkdir_one(const char* path) {
  if (path[0] == '\0') return 1;
  if (_mkdir(path) == 0) return 1;
  return errno == EEXIST;
}
#else
typedef pthread_t le_pd_thread_t;

static void le_pd_drain_thread_main(void* arg);

static void* le_pd_posix_trampoline(void* arg) {
  le_pd_drain_thread_main(arg);
  return NULL;
}

static void le_pd_thread_lower_own_priority(void) {
#if defined(__linux__)
  /* Per-thread on Linux (see the block comment above); ignoring the result is
   * deliberate — a kernel that refuses still leaves a working capture. */
  (void)setpriority(PRIO_PROCESS, 0, LE_PD_NICE);
#endif
}

/* Fills `attr` with the below-normal, explicitly-non-inherited policy this
 * thread wants. Returns 0 if any step failed, in which case the caller falls
 * back to default attributes rather than failing the arm. */
static int le_pd_thread_attr_init(pthread_attr_t* attr) {
  if (pthread_attr_init(attr) != 0) return 0;
  /* SCHED_OTHER at its minimum permitted priority. On Linux that minimum is 0
   * and the value carries no weight (niceness does, applied in-thread); on
   * Darwin it is a real drop (15, against a default of 31). The load-bearing
   * half everywhere is PTHREAD_EXPLICIT_SCHED, which stops the drain from
   * inheriting a caller that is — or one day becomes — real-time. */
  struct sched_param sp;
  memset(&sp, 0, sizeof(sp));
  const int min_prio = sched_get_priority_min(SCHED_OTHER);
  sp.sched_priority = min_prio < 0 ? 0 : min_prio;
  if (pthread_attr_setinheritsched(attr, PTHREAD_EXPLICIT_SCHED) != 0 ||
      pthread_attr_setschedpolicy(attr, SCHED_OTHER) != 0 ||
      pthread_attr_setschedparam(attr, &sp) != 0) {
    pthread_attr_destroy(attr);
    return 0;
  }
  return 1;
}

/* Is the thread asking for a drain thread itself real-time? The fallback path
 * below hands the new thread the CALLER's scheduling, so this decides whether
 * that fallback is harmless or exactly the outcome this code exists to
 * prevent.
 *
 * Only genuinely real-time policies count. "Not SCHED_OTHER" would be wrong:
 * SCHED_BATCH and SCHED_IDLE both rank BELOW normal, so inheriting either is
 * strictly safer than the time-sharing default — and an app launched under
 * `chrt --batch` or a systemd unit with CPUSchedulingPolicy=batch would
 * otherwise have its arm refused for scheduling that cannot outrank the audio
 * callback in the first place. Fails closed only where it must: if the policy
 * cannot be read at all, assume the dangerous case. */
static int le_pd_caller_is_realtime(void) {
  int policy = 0;
  struct sched_param sp;
  memset(&sp, 0, sizeof(sp));
  if (pthread_getschedparam(pthread_self(), &policy, &sp) != 0) return 1;
  if (policy == SCHED_FIFO || policy == SCHED_RR) return 1;
#if defined(SCHED_DEADLINE)
  if (policy == SCHED_DEADLINE) return 1; /* ranks above FIFO where visible */
#endif
  return 0;
}

static int le_pd_thread_start(le_pd_thread_t* out, void* arg) {
  pthread_attr_t attr;
  if (le_pd_thread_attr_init(&attr)) {
    const int rc = pthread_create(out, &attr, le_pd_posix_trampoline, arg);
    pthread_attr_destroy(&attr);
    if (rc == 0) return 1;
    /* fell through: some hardened kernels refuse an explicit-sched create
     * outright (EPERM) — fall back below. */
  }
  /* The fallback create INHERITS the caller's scheduling. That is fine from a
   * time-sharing caller (it is what this module did before #722) and is
   * exactly the failure this block exists to prevent from a real-time one: a
   * SCHED_FIFO drain thread outranking the audio callback. le_perf_arm is
   * control-thread-only today and the control thread is time-sharing, so the
   * fallback is available as before; should that ever change, the arm fails
   * loudly (LE_ERR_DEVICE, unwound by the caller) instead of quietly
   * shipping a priority inversion into a capture. */
  if (le_pd_caller_is_realtime()) return 0;
  return pthread_create(out, NULL, le_pd_posix_trampoline, arg) == 0;
}

static void le_pd_thread_join(le_pd_thread_t th) { pthread_join(th, NULL); }

static void le_pd_sleep_ms(int ms) {
  struct timespec ts = {ms / 1000, (long)(ms % 1000) * 1000000L};
  nanosleep(&ts, NULL);
}

/* Milliseconds on a monotonic clock — CLOCK_MONOTONIC, the same source
 * midi_backend_linux.c timestamps with, deliberately not a new abstraction and
 * deliberately not CLOCK_REALTIME (an NTP step or a manual date change must
 * never move the flush deadline). A failure leaves ts zeroed, which reads as
 * "no time passed" and simply defers this cycle by one poll; it cannot fail in
 * practice on any platform this builds for. */
static uint64_t le_pd_now_ms(void) {
  struct timespec ts;
  memset(&ts, 0, sizeof(ts));
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (uint64_t)ts.tv_sec * 1000u + (uint64_t)(ts.tv_nsec / 1000000L);
}

static int le_pd_mkdir_one(const char* path) {
  if (path[0] == '\0') return 1;
  if (mkdir(path, 0755) == 0) return 1;
  return errno == EEXIST;
}
#endif

/* ---- raw-descriptor sidecar write (#722) ----
 *
 * The sidecar is the one file in this module that is created, written and
 * closed afresh EVERY drain cycle (the PCM + events streams are opened once
 * and kept open, so their stdio buffers are a one-time cost at arm). Going
 * through stdio for it meant a per-cycle FILE object plus a lazily-allocated
 * stream buffer — a malloc/free pair, four times a second, for a document
 * that is already fully built in memory and written in a single call. These
 * shims write the exact same bytes with no allocator involvement at all,
 * which is what lets the steady-state cycle be provably allocation-free.
 * 0666 matches fopen("wb")'s creation mode exactly (umask applies to both);
 * O_CLOEXEC is a small upgrade on it — the sidecar is rewritten four times a
 * second, so any Process.start from the Dart side landing in that window used
 * to inherit a writable descriptor onto the temp inode. */
#if defined(_WIN32)
static int le_pd_open_trunc(const char* path) {
  /* _O_NOINHERIT is the O_CLOEXEC equivalent. */
  return _open(path, _O_WRONLY | _O_CREAT | _O_TRUNC | _O_BINARY | _O_NOINHERIT,
               _S_IREAD | _S_IWRITE);
}
/* void, not int: close()'s result is deliberately not a check here — see the
 * call site, and the durability note below. */
static void le_pd_fd_close(int fd) { (void)_close(fd); }
#else
static int le_pd_open_trunc(const char* path) {
  return open(path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0666);
}
static void le_pd_fd_close(int fd) { (void)close(fd); }
#endif

/* WHAT THE RENAME ACTUALLY GUARANTEES — and what it does not. It guarantees
 * ATOMICITY OF THE DIRECTORY ENTRY: performance.json always names either the
 * previous flush's complete document or this one's, never a half-written
 * file, and on POSIX it is never momentarily absent. That is a guarantee
 * about what a CONCURRENT READER sees.
 *
 * It is NOT a durability guarantee. Nothing here fsyncs, so after a power cut
 * the sidecar may be missing this cycle's content entirely. That is
 * deliberate, and it is not the weaker choice it looks like:
 *
 *   - The sidecar describes the PCM streams, which are only fflush'd (stdio
 *     buffer -> page cache) and never synced either. Syncing only the sidecar
 *     makes the pair INCONSISTENT: performance.json durably claiming
 *     capture_frames = N while master.pcm's last seconds are still page
 *     cache, so #679's salvage and daw_export lay out an arrangement past the
 *     audio. Un-synced, both sides lose the same tail and stay consistent.
 *   - On ext4 data=ordered an fsync here commits the journal transaction
 *     carrying master.pcm's block allocations too, so it would drag PCM
 *     writeback onto this cycle synchronously — and the capture rings hold
 *     only LE_PERF_CAPTURE_SECONDS. An SD garbage-collection stall past that
 *     inside one cycle overruns master_ring and writes zero-filled silence
 *     into the take: the exact #710 defect, re-manufactured.
 *
 * Real crash-durability needs the sidecar and the PCM synced together, off
 * this cycle's critical path, with that overrun risk analysed — designed in
 * #727, not smuggled in here. The comment this replaces claimed the checked
 * close made unflushed bytes un-renameable; it never did, and overclaiming
 * was the actual defect. */

/* Writes every byte or reports failure — a short write is a real possibility
 * on a filling disk, and a partially-written temp file must never be renamed
 * over a good sidecar. EINTR is retried rather than counted as failure. */
static int le_pd_fd_write_all(int fd, const char* data, size_t len) {
  size_t off = 0;
  while (off < len) {
#if defined(_WIN32)
    const int n = _write(fd, data + off, (unsigned int)(len - off));
#else
    const ssize_t n = write(fd, data + off, len - off);
#endif
    if (n < 0) {
      if (errno == EINTR) continue;
      return 0;
    }
    if (n == 0) return 0; /* no progress: treat as a failed write, not a spin */
    off += (size_t)n;
  }
  return 1;
}

/* mkdir -p: creates every missing path segment. Splits on '/' or '\\' so a
 * caller can pass either style; each segment is created in order so a nested
 * capture dir works with no pre-existing parent. Known limitation: a bare
 * Windows drive letter ("C:") as the first segment is not special-cased —
 * not exercised by this codebase's paths (always under a resolved documents
 * dir), so left as a follow-up rather than solved speculatively here. */
static int le_pd_mkdir_recursive(const char* path) {
  char buf[LE_PD_PATH_MAX];
  snprintf(buf, sizeof(buf), "%s", path);
  size_t len = strlen(buf);
  while (len > 0 && (buf[len - 1] == '/' || buf[len - 1] == '\\')) {
    buf[--len] = '\0';
  }
  for (size_t i = 1; i < len; ++i) {
    if (buf[i] == '/' || buf[i] == '\\') {
      const char sep = buf[i];
      buf[i] = '\0';
      if (!le_pd_mkdir_one(buf)) return 0;
      buf[i] = sep;
    }
  }
  return le_pd_mkdir_one(buf);
}

/* Test-only global: forces every subsequent write attempt to fail, simulating
 * a full disk without needing a real one (engine_internal.h). Relaxed: a lone
 * on/off switch a test flips before/after driving a drain thread, not raced
 * against anything else. */
static _Atomic int g_pd_force_write_failure = 0;

void le_perf_drain_force_write_failure_for_test(int enabled) {
  atomic_store_explicit(&g_pd_force_write_failure, enabled ? 1 : 0,
                        memory_order_relaxed);
}

/* Test-only globals: see le_perf_drain_set_mid_cycle_hook_for_test
 * (engine_internal.h). Genuinely _Atomic, matching the write-failure switch
 * above, because these ARE written by the test thread while the drain thread
 * is live and reading them — plain globals there would be a data race (and
 * an invitation for the compiler to hoist the NULL check out of the cycle).
 * The ctx pointer is released and the function pointer acquired so the hook
 * never runs against a half-published context. */
static _Atomic(void (*)(void*)) g_pd_mid_cycle_hook = NULL;
static _Atomic(void*) g_pd_mid_cycle_ctx = NULL;

void le_perf_drain_set_mid_cycle_hook_for_test(void (*fn)(void*), void* ctx) {
  atomic_store_explicit(&g_pd_mid_cycle_ctx, ctx, memory_order_relaxed);
  atomic_store_explicit(&g_pd_mid_cycle_hook, fn, memory_order_release);
}

typedef struct le_pd_gap {
  uint64_t frame;
  uint64_t duration_frames;
} le_pd_gap;

/* One retired-layer manifest entry (part 5, D-LAYER) — recorded once its
 * file is durably written (fclose'd), so it never appears in the sidecar
 * before the bytes it describes are actually on disk. `channel`/`slot`/
 * `generation` are the same key events.log's LE_PLOG_LAYER_RETIRED entry
 * carries, for a renderer to cross-reference the sample-accurate frame (see
 * layer_staging_ring.h and docs/design/performance-event-log-format.md). */
typedef struct le_pd_layer_manifest_entry {
  int32_t channel;
  int32_t slot;
  uint32_t generation;
  uint64_t frame;
  int32_t frame_count;
  int32_t lane_count;
  char filename[64];
} le_pd_layer_manifest_entry;

typedef struct le_pd_file {
  FILE* f;
  uint64_t written; /* frames written so far, in THIS file's own channel width */
} le_pd_file;

struct le_perf_drain {
  le_engine* engine;
  le_pd_thread_t thread;

  _Atomic int running;       /* cleared by le_perf_drain_stop to end the loop */
  _Atomic int disk_full;     /* 1 once a write failure self-stopped the thread */
  _Atomic int device_changed; /* 1 once le_perf_drain_stop(..., DEVICE_CHANGED) */

  char capture_dir[LE_PD_PATH_MAX];

  le_pd_file master_file;
  /* valid iff the matching input_mask bit is set */
  le_pd_file monitor_file[LE_MAX_MONITORED_INPUTS];

  /* Performance event log (part 3): append-only, header written once at
   * start; every subsequent drain cycle appends whatever both perf-log rings
   * have accumulated since the last cycle. Never reopened/truncated mid-
   * session, unlike the sidecar. */
  FILE* events_file;

  le_pd_gap gaps[LE_PD_MAX_GAPS];
  int gap_count;

  le_pd_layer_manifest_entry layers[LE_PD_MAX_LAYERS];
  int layer_count;

  /* The sidecar's build buffer, owned by the session and reused by every
   * cycle (#722). It was a per-cycle malloc(512 KB) + free; measurement (see
   * the file header) showed glibc served that from the arena after the first
   * cycle rather than mmapping each time, so this is not the syscall storm
   * the first draft of this change claimed. What it removes is real but
   * smaller: a large chunk split/merge under the malloc arena lock, four
   * times a second, on a thread that shares a machine with a real-time audio
   * callback. It is still not a stack array (see the note in
   * le_pd_write_sidecar) and still not sized down — owning it here just moves
   * the one allocation to arm. */
  char json_buf[LE_PD_JSON_BUF];
};

int le_perf_drain_self_stopped(struct le_perf_drain* drain) {
  if (drain == NULL) return 0;
  return atomic_load_explicit(&drain->disk_full, memory_order_acquire);
}

/* Low-level bounded write; checks the force-failure test hook so every PCM/
 * silence-fill write path fails uniformly. This is the ONLY function that
 * consults it — le_pd_flush and le_pd_write_sidecar deliberately do NOT check
 * it; see their own definitions for why (the sidecar's exemption is what makes
 * the `stopped_early` marker testable after a forced PCM failure). */
static int le_pd_write(FILE* f, const void* data, size_t bytes) {
  if (atomic_load_explicit(&g_pd_force_write_failure, memory_order_relaxed)) {
    return 0;
  }
  if (bytes == 0) return 1;
  return fwrite(data, 1, bytes, f) == bytes;
}

/* Flushes a long-lived PCM file handle so its writes actually reach the OS
 * (and become visible to any other reader) rather than sitting in this
 * stream's userspace buffer until an eventual fclose — the file is kept open
 * for the whole capture session, unlike the sidecar's per-cycle
 * open/write/close (#722 moved that off stdio; it was fopen/fclose before).
 * This is a flush to the OS, NOT to the device — no fsync is involved
 * anywhere in this module, on either side (see the durability note above the
 * sidecar's descriptor shims, and #727).
 * This IS the ~250 ms flush cadence perf_drain.h documents. Not itself
 * subject to the force-write-failure test hook (le_pd_write already covers
 * the PCM data path; by the time flush would run, either the write already
 * failed and this is unreached, or there is genuinely nothing forced to
 * fail). */
static int le_pd_flush(FILE* f) { return fflush(f) == 0; }

/* Writes events.log's 12-byte header once, right after the file is created:
 * magic "PLEV", a uint32 version (bump if the entry layout ever changes), and
 * the session's sample rate (so a reader can convert frame -> seconds without
 * cross-referencing the sidecar). */
static int le_pd_write_events_header(FILE* f, int32_t sample_rate) {
  static const char magic[4] = {'P', 'L', 'E', 'V'};
  const uint32_t version = 1;
  if (!le_pd_write(f, magic, sizeof(magic))) return 0;
  if (!le_pd_write(f, &version, sizeof(version))) return 0;
  if (!le_pd_write(f, &sample_rate, sizeof(sample_rate))) return 0;
  return 1;
}

/* Serializes one log entry into the fixed 28-byte on-disk record: frame,
 * code, then the union's raw 16 bytes taken directly from memory (every
 * le_command union arm is laid out as plain int32_t/float/uint32_t fields
 * with no arm exceeding 16 bytes, so this is a faithful, code-agnostic copy —
 * the reader interprets those 16 bytes per the audited table's per-code arm
 * documentation, the same way apply_command does in-process). */
static int le_pd_write_log_entry(FILE* f, const le_perf_log_entry* entry) {
  unsigned char buf[LE_PD_EVENTS_ENTRY_BYTES];
  memcpy(buf, &entry->frame, sizeof(entry->frame));
  memcpy(buf + sizeof(entry->frame), &entry->cmd.code,
        sizeof(entry->cmd.code));
  memcpy(buf + sizeof(entry->frame) + sizeof(entry->cmd.code),
        ((const char*)&entry->cmd) + sizeof(entry->cmd.code),
        LE_PD_EVENTS_ENTRY_BYTES - sizeof(entry->frame) -
            sizeof(entry->cmd.code));
  return le_pd_write(f, buf, sizeof(buf));
}

/* Drains everything currently available from a perf-log ring (either
 * log_ring or log_ctrl_ring) into events.log, one entry at a time — these
 * rings carry one event per pop, unlike the bulk-sample le_audio_ring above. */
static int le_pd_drain_log_ring(FILE* f, le_perf_log_ring* ring) {
  le_perf_log_entry entry;
  while (le_perf_log_ring_pop(ring, &entry)) {
    if (!le_pd_write_log_entry(f, &entry)) return 0;
  }
  return 1;
}

/* Writes one retired layer's PCM to its own file, interleaving lanes the same
 * way multi-channel PCM is interleaved everywhere else in this format
 * (lane0[0], lane1[0], ..., lane0[1], lane1[1], ...). ALWAYS frees every
 * `entry->lane_pcm[l]` before returning, success or failure — this function
 * takes ownership of the staged copy unconditionally, matching
 * layer_staging_ring.h's documented handoff contract. Only records a
 * manifest entry on success, and only once the file is fclose'd (durably on
 * disk) — see le_pd_layer_manifest_entry's doc comment for why. */
static int le_pd_write_staged_layer(le_perf_drain* d,
                                    const le_staged_layer* entry) {
  char filename[64];
  snprintf(filename, sizeof(filename), "layer-%d-%llu-%d.pcm", entry->channel,
          (unsigned long long)entry->frame, entry->slot);
  char path[LE_PD_FULL_PATH_MAX];
  snprintf(path, sizeof(path), "%s/%s", d->capture_dir, filename);

  int ok = 1;
  FILE* f = fopen(path, "wb");
  if (f == NULL) {
    ok = 0;
  } else {
    float chunk[LE_PD_LAYER_CHUNK_FRAMES * LE_MAX_LANES];
    int32_t fr = 0;
    while (ok && fr < entry->frame_count) {
      const int32_t remaining = entry->frame_count - fr;
      const int32_t n =
          remaining < LE_PD_LAYER_CHUNK_FRAMES ? remaining : LE_PD_LAYER_CHUNK_FRAMES;
      for (int32_t i = 0; i < n; ++i) {
        for (int32_t l = 0; l < entry->lane_count; ++l) {
          chunk[i * entry->lane_count + l] = entry->lane_pcm[l][fr + i];
        }
      }
      if (!le_pd_write(f, chunk,
                       (size_t)n * (size_t)entry->lane_count * sizeof(float))) {
        ok = 0;
      }
      fr += n;
    }
    if (fclose(f) != 0) ok = 0;
  }

  for (int32_t l = 0; l < entry->lane_count; ++l) free(entry->lane_pcm[l]);

  if (ok && d->layer_count < LE_PD_MAX_LAYERS) {
    le_pd_layer_manifest_entry* m = &d->layers[d->layer_count];
    m->channel = entry->channel;
    m->slot = entry->slot;
    m->generation = entry->generation;
    m->frame = entry->frame;
    m->frame_count = entry->frame_count;
    m->lane_count = entry->lane_count;
    snprintf(m->filename, sizeof(m->filename), "%s", filename);
    d->layer_count++;
  }
  return ok;
}

/* Drains everything currently available from the retired-layer staging ring
 * into individual layer files. Continues past a single layer's write
 * failure (each layer is an independent file — one bad layer shouldn't stop
 * later ones from persisting) but reports overall failure so the caller's
 * disk-full bookkeeping still fires. */
static int le_pd_drain_layer_staging(le_perf_drain* d) {
  le_staged_layer entry;
  int ok = 1;
  while (le_layer_staging_ring_pop(&d->engine->perf.layer_staging_ring,
                                   &entry)) {
    if (!le_pd_write_staged_layer(d, &entry)) ok = 0;
  }
  return ok;
}

/* Drains everything currently available from `ring` (a le_audio_ring of
 * `channels`-wide frames) into `pf`'s file, looping until the ring reports
 * less than a full scratch buffer (i.e. it is now empty). */
static int le_pd_drain_ring(le_pd_file* pf, le_audio_ring* ring, int channels,
                           float* scratch, size_t scratch_samples) {
  if (channels <= 0) return 1;
  const size_t max_frames = scratch_samples / (size_t)channels;
  for (;;) {
    const size_t popped =
        le_audio_ring_pop(ring, scratch, max_frames * (size_t)channels);
    if (popped == 0) return 1;
    if (!le_pd_write(pf->f, scratch, popped * sizeof(float))) return 0;
    const size_t popped_frames = popped / (size_t)channels;
    pf->written += popped_frames;
    if (popped_frames < max_frames) return 1;
  }
}

/* THE ZERO-FILL (#710). Tops `pf` up to `elapsed` frames with digital silence
 * when the audio that should have filled them never reached the drain — a ring
 * overrun being the designed cause — so the file stays sample-consistent with
 * the engine's frame clock rather than time-compressing around the hole.
 *
 * This is the ONLY place the capture path substitutes silence, so it is also
 * the only honest place to count it: whatever the cause, every frame padded
 * here is a frame of the take the performer did not play, and #710's bench
 * captures found period-exact runs of it in takes whose `overrun_count` read a
 * clean zero (a_perf_overruns only sees frames the AUDIO thread failed to
 * enqueue). a_perf_zero_filled_frames therefore counts the silence itself, is
 * published on le_snapshot, and is what the app latches into the capture's
 * glitch flag. Also records a gap entry {frame, duration_frames} — where the
 * file started falling behind, and how many frames were INTENDED to be padded
 * — capped at LE_PD_MAX_GAPS, which is why the total lives in the atomic and
 * not in `gap_count`.
 *
 * The counter is bumped AFTER the padding writes, by the number of frames that
 * actually reached the file. Bumping it up front double-counts on the one path
 * where the two differ: a failed write leaves `pf->written` where it was, so
 * the next cycle (and the unconditional final one) re-pads the same gap and
 * would charge for it again — a disk-full stop reporting roughly twice the
 * silence it wrote. The gap LIST can still name a span the disk refused; the
 * total stays a count of silence genuinely on disk, which is what the manifest
 * documents it as. */
static int le_pd_catch_up(le_perf_drain* d, le_pd_file* pf, int channels,
                          uint64_t elapsed) {
  if (pf->written >= elapsed || channels <= 0) return 1;
  const uint64_t gap = elapsed - pf->written;

  if (d->gap_count < LE_PD_MAX_GAPS) {
    d->gaps[d->gap_count].frame = pf->written;
    d->gaps[d->gap_count].duration_frames = gap;
    d->gap_count++;
  }

  static const float kZeros[1024] = {0};
  uint64_t remaining = gap * (uint64_t)channels;
  uint64_t padded_samples = 0;
  int ok = 1;
  while (remaining > 0) {
    const size_t chunk = remaining < 1024 ? (size_t)remaining : 1024;
    if (!le_pd_write(pf->f, kZeros, chunk * sizeof(float))) {
      ok = 0;
      break;
    }
    remaining -= chunk;
    padded_samples += chunk;
  }

  const uint64_t padded_frames = padded_samples / (uint64_t)channels;
  if (padded_frames > 0) {
    atomic_fetch_add_explicit(&d->engine->a_perf_zero_filled_frames,
                              padded_frames, memory_order_relaxed);
  }
  if (!ok) return 0;

  pf->written = elapsed;
  return 1;
}

static int le_pd_atomic_rename(const char* tmp, const char* final_path) {
#if defined(_WIN32)
  /* Windows' rename() refuses to replace an existing destination (unlike
   * POSIX) — a best-effort pre-remove closes that gap at the cost of a
   * brief window with neither file present there (acceptable: a reader
   * mid-window just sees the previous flush's absence, not corruption, and
   * the next cycle's temp file already has fresh content queued). */
  remove(final_path);
#endif
  /* POSIX rename() already atomically replaces an existing destination, so
   * skipping the remove() there means the final path is NEVER momentarily
   * absent — a reader can fopen() it at any instant and always see either
   * the previous flush or this one, never neither. */
  return rename(tmp, final_path) == 0;
}

static const char* le_pd_basename(const char* path) {
  const char* slash = strrchr(path, '/');
  const char* backslash = strrchr(path, '\\');
  if (backslash != NULL && (slash == NULL || backslash > slash)) slash = backslash;
  return slash != NULL ? slash + 1 : path;
}

/* Minimal JSON string escaping (quote + backslash only) — the sidecar's only
 * string field is the capture-dir basename, a machine-generated timestamp
 * slug with no expected special characters; this is defensive, not a general
 * JSON encoder. */
static void le_pd_json_escape(const char* in, char* out, size_t out_cap) {
  size_t o = 0;
  for (size_t i = 0; in[i] != '\0' && o + 2 < out_cap; ++i) {
    if (in[i] == '"' || in[i] == '\\') out[o++] = '\\';
    out[o++] = in[i];
  }
  out[o] = '\0';
}

/* Builds performance.json and atomically replaces it. Always
 * `"finalized": false` in this slice — flipping it to true happens at
 * finalize, a later part. `stopped_early` is omitted entirely on a normal,
 * still-running (or normally disarmed) capture; present only for the two
 * abnormal-stop reasons this part defines.
 *
 * NOT subject to the force-write-failure test hook (unlike le_pd_write/
 * le_pd_flush): a disk-full failure realistically hits the large,
 * continuously-growing PCM files long before it hits this tiny, occasional
 * JSON write, and — more importantly — is the ONLY place `stopped_early`
 * ever reaches disk, so it must still be able to succeed after a PCM write
 * has already failed this same cycle.
 *
 * `report_disk_full` is an explicit parameter, not a read of d->disk_full:
 * the caller (le_pd_drain_cycle) only sets that externally-observable atomic
 * AFTER this call returns, so a test polling it can never see "disk_full"
 * before the marker it implies has actually finished its remove()+rename()
 * on disk.
 *
 * `elapsed` is the caller's own cycle-start sample, NOT a fresh load (#710):
 * catch-up padded the PCM files up to that value, so re-reading a_perf_frames
 * here would publish a `capture_frames` that runs up to a cycle ahead of the
 * bytes actually on disk. A crash-recovered bundle is finalized straight from
 * this sidecar, and daw_export lays out the session from `capture_frames` — an
 * inflated one stretches the arrangement past the audio. Same number, same
 * cycle, one truth. */
static int le_pd_write_sidecar(le_perf_drain* d, int report_disk_full,
                               uint64_t elapsed) {
  char slug_esc[128];
  le_pd_json_escape(le_pd_basename(d->capture_dir), slug_esc, sizeof(slug_esc));

  const uint32_t overruns = atomic_load_explicit(&d->engine->a_perf_overruns,
                                                 memory_order_relaxed);
  /* #710: `overrun_count` alone let a take look clean while carrying audible
   * silence — it counts frames the audio thread could not enqueue, not the
   * silence this thread actually wrote. Report both, so a reader never has to
   * infer the second from the (capped) `overrun_gaps` list. */
  const uint64_t zero_filled = atomic_load_explicit(
      &d->engine->a_perf_zero_filled_frames, memory_order_relaxed);

  /* Not a local array: LE_PD_JSON_BUF scales with LE_PD_MAX_LAYERS (in turn
   * LE_MAX_TRACKS * LE_POOL_SLOTS), and this function runs on the drain
   * thread, whose stack is sized for the small, fixed-size buffers every
   * other function here uses — a stack array this large blew that stack
   * (SIGBUS) the first time LE_PD_JSON_BUF grew past a few hundred KB. It is
   * no longer a per-call malloc either (#722): the session owns it, so this
   * cycle costs nothing but the snprintf passes below and the write. */
  char* const buf = d->json_buf;
  int result = 0;
  int off = snprintf(buf, LE_PD_JSON_BUF,
                     "{\n"
                     "  \"slug\": \"%s\",\n"
                     "  \"sample_rate\": %d,\n"
                     "  \"channel_layout\": {\"master_channels\": %d, "
                     "\"captured_inputs\": [",
                     slug_esc, d->engine->sample_rate,
                     d->engine->perf.master_channels);
  if (off < 0) goto done;

  int first = 1;
  for (int32_t c = 0; c < LE_MAX_MONITORED_INPUTS; ++c) {
    if (!(d->engine->perf.input_mask & (1u << c))) continue;
    off += snprintf(buf + off, (size_t)LE_PD_JSON_BUF - (size_t)off, "%s%d",
                    first ? "" : ", ", c);
    first = 0;
  }

  off += snprintf(buf + off, (size_t)LE_PD_JSON_BUF - (size_t)off,
                 "]},\n"
                 "  \"capture_frames\": %llu,\n"
                 "  \"overrun_count\": %u,\n"
                 "  \"zero_filled_frames\": %llu,\n"
                 "  \"overrun_gaps\": [",
                 (unsigned long long)elapsed, overruns,
                 (unsigned long long)zero_filled);

  /* Loop guard re-checks `off` before every snprintf: once `off` reaches
   * LE_PD_JSON_BUF, `LE_PD_JSON_BUF - off` would otherwise underflow
   * (size_t is unsigned) and hand snprintf a huge bogus size on the very
   * next iteration — an out-of-bounds write, not just truncation. */
  for (int i = 0; i < d->gap_count && off >= 0 && off < LE_PD_JSON_BUF; ++i) {
    off += snprintf(buf + off, (size_t)LE_PD_JSON_BUF - (size_t)off,
                   "%s{\"frame\": %llu, \"duration_frames\": %llu}",
                   i == 0 ? "" : ", ", (unsigned long long)d->gaps[i].frame,
                   (unsigned long long)d->gaps[i].duration_frames);
  }
  if (off < 0 || off >= LE_PD_JSON_BUF) goto done; /* truncated */
  off += snprintf(buf + off, (size_t)LE_PD_JSON_BUF - (size_t)off, "],\n");

  /* Retired-layer manifest (part 5, D-LAYER): every layer persisted so far
   * this session, so part 7's offline renderer can stitch overdub passes
   * without re-deriving anything from the pool (which may have long since
   * reclaimed/reused these slots). `frame` here is the best-effort staging-
   * time snapshot (see layer_staging_ring.h); cross-reference `channel`/
   * `slot`/`generation` against events.log's LE_PLOG_LAYER_RETIRED entries
   * for the sample-accurate retire frame. */
  if (off < 0 || off >= LE_PD_JSON_BUF) goto done; /* truncated */
  off += snprintf(buf + off, (size_t)LE_PD_JSON_BUF - (size_t)off,
                 "  \"layers\": [");
  for (int i = 0; i < d->layer_count && off >= 0 && off < LE_PD_JSON_BUF;
       ++i) {
    const le_pd_layer_manifest_entry* m = &d->layers[i];
    off += snprintf(buf + off, (size_t)LE_PD_JSON_BUF - (size_t)off,
                   "%s{\"channel\": %d, \"slot\": %d, \"generation\": %u, "
                   "\"frame\": %llu, \"frame_count\": %d, \"lane_count\": %d, "
                   "\"filename\": \"%s\"}",
                   i == 0 ? "" : ", ", m->channel, m->slot, m->generation,
                   (unsigned long long)m->frame, m->frame_count,
                   m->lane_count, m->filename);
  }
  if (off < 0 || off >= LE_PD_JSON_BUF) goto done; /* truncated */
  off += snprintf(buf + off, (size_t)LE_PD_JSON_BUF - (size_t)off, "],\n");

  if (report_disk_full) {
    off += snprintf(buf + off, (size_t)LE_PD_JSON_BUF - (size_t)off,
                   "  \"stopped_early\": \"disk_full\",\n");
  } else if (atomic_load_explicit(&d->device_changed, memory_order_acquire)) {
    off += snprintf(buf + off, (size_t)LE_PD_JSON_BUF - (size_t)off,
                   "  \"stopped_early\": \"device_changed\",\n");
  }

  off += snprintf(buf + off, (size_t)LE_PD_JSON_BUF - (size_t)off,
                 "  \"finalized\": false\n}\n");
  if (off < 0 || off >= LE_PD_JSON_BUF) goto done; /* truncated */

  {
    char tmp_path[LE_PD_FULL_PATH_MAX];
    char final_path[LE_PD_FULL_PATH_MAX];
    snprintf(tmp_path, sizeof(tmp_path), "%s/performance.json.tmp",
            d->capture_dir);
    snprintf(final_path, sizeof(final_path), "%s/performance.json",
            d->capture_dir);

    const int fd = le_pd_open_trunc(tmp_path);
    if (fd < 0) goto done;
    const int ok = le_pd_fd_write_all(fd, buf, (size_t)off);
    /* close() is release-the-descriptor, nothing more: it neither flushes the
     * page cache nor reports writeback errors, so its result says nothing
     * about the bytes and is not worth failing a whole capture over (see the
     * durability note above the shims). The write itself is the check. */
    le_pd_fd_close(fd);
    if (!ok) goto done;

    result = le_pd_atomic_rename(tmp_path, final_path);
  }

done:
  return result;
}

/* One drain-and-flush pass: pop everything available from every captured
 * ring, silence-fill any file that has fallen behind wall-clock elapsed
 * frames, flush the PCM files, then rewrite the sidecar. The sidecar write is
 * ALWAYS attempted, even after a PCM failure earlier in the same pass — it is
 * the only place `stopped_early` ever reaches disk, so it must still run
 * while there is something to report. Returns 0 if the PCM path failed (the
 * caller stops the thread — a partial pass is not retried mid-cycle) or the
 * sidecar write itself failed. */
static int le_pd_drain_cycle(le_perf_drain* d) {
  le_engine* e = d->engine;
  float scratch[LE_PD_SCRATCH_SAMPLES];
  int ok = 1;

  /* ORDER IS LOAD-BEARING (#710), and it takes BOTH halves to hold: sample
   * the elapsed frame count before touching a single ring, and sample it with
   * ACQUIRE.
   *
   * Program order first. The audio thread publishes as push-then-count — every
   * frame of the block into the rings, THEN the block added to a_perf_frames
   * (engine_process.c's tail) — so the rings hold at least `a_perf_frames`
   * worth of audio. Reading elapsed first therefore makes the catch-up test
   * `written < elapsed` mean exactly what it claims: audio the taps could not
   * enqueue. Anything produced WHILE this cycle drains lands past the snapshot
   * and is written next cycle.
   *
   * Reading it afterwards — as this did until #710 — makes the same test fire
   * for audio that is merely still in flight: the drain empties the master
   * ring, spends milliseconds writing the monitor stems to disk, then asks the
   * audio thread how far it has got and pads the difference with silence even
   * though those frames are sitting in the ring, unread. The padding displaces
   * the real audio, which arrives next cycle and is written after the hole.
   * That is the deterministic zero-fill every bench take showed ~0.25 s in
   * (LE_PD_FLUSH_MS — the FIRST cycle, whose writes are the slowest of the
   * session: freshly created files, cold stdio buffers, unallocated extents),
   * and the same mechanism at a lower rate through the rest of the take, worse
   * on slow storage because the window IS the cycle's write time. No overrun
   * is involved, which is why a_perf_overruns stayed at zero through all of it.
   *
   * Program order alone is not enough, though, and this is why the load is
   * ACQUIRE and the producer's add is RELEASE. Statement order binds the
   * compiler's emission, not what another core observes: with both sides
   * relaxed, the producer's count could become visible before the ring tail
   * stores it vouches for (release on tail is one-way), and this load could
   * sink below the acquire loads inside le_audio_ring_pop. Either reordering
   * reconstructs the exact artifact through the memory model on a weakly-
   * ordered machine. The release/acquire pair gives the drain a
   * synchronizes-with edge: observing a count here guarantees every tail store
   * sequenced before it is visible to the pops below. (The bench that found
   * this ran on a Pi 4, where the window was statement-order-only.)
   *
   * A genuine ring overrun still zero-fills: the frames it dropped were
   * counted into a_perf_frames before this load and never enqueued at all. */
  const uint64_t elapsed =
      atomic_load_explicit(&e->a_perf_frames, memory_order_acquire);

  if (!le_pd_drain_ring(&d->master_file, &e->perf.master_ring,
                       e->perf.master_channels, scratch,
                       LE_PD_SCRATCH_SAMPLES)) {
    ok = 0;
  }
  for (int32_t c = 0; ok && c < LE_MAX_MONITORED_INPUTS; ++c) {
    if (!(e->perf.input_mask & (1u << c))) continue;
    if (!le_pd_drain_ring(&d->monitor_file[c], &e->perf.monitor_ring[c], 2,
                         scratch, LE_PD_SCRATCH_SAMPLES)) {
      ok = 0;
    }
  }

  /* Test seam (engine_internal.h): stands in for the audio thread producing
   * while this cycle was busy writing. Compiled in unconditionally — one NULL
   * check per 250 ms cycle on a background thread — because the ordering it
   * pins is the whole #710 fix. */
  {
    void (*const hook)(void*) =
        atomic_load_explicit(&g_pd_mid_cycle_hook, memory_order_acquire);
    if (hook != NULL) {
      hook(atomic_load_explicit(&g_pd_mid_cycle_ctx, memory_order_relaxed));
    }
  }

  if (ok) {
    if (!le_pd_catch_up(d, &d->master_file, e->perf.master_channels, elapsed)) {
      ok = 0;
    }
    for (int32_t c = 0; ok && c < LE_MAX_MONITORED_INPUTS; ++c) {
      if (!(e->perf.input_mask & (1u << c))) continue;
      if (!le_pd_catch_up(d, &d->monitor_file[c], 2, elapsed)) ok = 0;
    }
  }

  /* Performance event log (part 3): drain both perf-log rings — the audio-
   * thread-producer log_ring first, then the control-thread-producer
   * log_ctrl_ring — and append every entry to events.log. Order between the
   * two streams is a file-write-order interleaving, not a global frame sort
   * (see docs/design/performance-event-log-format.md): each stream is
   * monotonic in frame on its own, but a control-side param change and an
   * audio-thread command from the same drain interval can land in either
   * order in the file. */
  if (ok && !le_pd_drain_log_ring(d->events_file, &e->perf.log_ring)) ok = 0;
  if (ok && !le_pd_drain_log_ring(d->events_file, &e->perf.log_ctrl_ring)) {
    ok = 0;
  }

  /* Retired-layer persistence (part 5, D-LAYER): each staged layer is its
   * own self-contained file (open, write, fclose — not a long-lived stream
   * like master.pcm), so there is nothing to flush separately below; the
   * fclose inside le_pd_write_staged_layer already makes it durable before
   * its manifest entry is recorded. */
  if (ok && !le_pd_drain_layer_staging(d)) ok = 0;

  /* The PCM files stay open for the whole capture session (never closed
   * until disarm), so without an explicit flush here their buffered writes
   * would sit invisible to any other reader (a crash-consistency check, or
   * this very drain cycle's sidecar reporting a capture_frames count nothing
   * has actually reached disk for yet) until fclose. This is THE flush the
   * ~250 ms cadence documented in perf_drain.h refers to. */
  if (ok && !le_pd_flush(d->master_file.f)) ok = 0;
  for (int32_t c = 0; ok && c < LE_MAX_MONITORED_INPUTS; ++c) {
    if (!(e->perf.input_mask & (1u << c))) continue;
    if (!le_pd_flush(d->monitor_file[c].f)) ok = 0;
  }
  if (ok && !le_pd_flush(d->events_file)) ok = 0;

  /* Write the sidecar (with the disk_full marker, if this cycle just failed)
   * BEFORE publishing d->disk_full — le_perf_drain_self_stopped
   * lets a caller observe that flag while the thread is still alive (unlike
   * device_changed, only ever checked after a full join), so the store must
   * happen strictly after the marker it implies is already durably on disk,
   * never before. */
  const int sidecar_ok = le_pd_write_sidecar(d, !ok, elapsed);
  if (!ok) atomic_store_explicit(&d->disk_full, 1, memory_order_release);
  return ok && sidecar_ok;
}

static void le_pd_drain_thread_main(void* arg) {
  le_perf_drain* d = (le_perf_drain*)arg;

  /* Before the first cycle: drop this thread's own scheduling share (#722).
   * See the shim block's SCHEDULING note for why this half has to happen from
   * inside the thread rather than in the attributes. */
  le_pd_thread_lower_own_priority();

  /* A MONOTONIC DEADLINE, not a tick accumulator. This loop used to add
   * LE_PD_POLL_MS per iteration and fire at 25 of them — counting ASSUMED
   * sleep, with nothing measuring the elapsed kind. le_pd_sleep_ms(10) is a
   * floor, never a ceiling, and this thread is now deliberately deprioritized
   * (see the SCHEDULING note), so a poll landing at 15 ms or worse under load
   * is an expected outcome rather than an anomaly. Under the accumulator that
   * silently stretched the cadence: 25 polls of 30 ms is a 750 ms cycle that
   * still believes it ran at 250. The failure at the far end is #710's — more
   * than LE_PERF_CAPTURE_SECONDS of audio piling into master_ring inside one
   * cycle, an overrun, and le_pd_catch_up padding the take with zero-filled
   * silence.
   *
   * The deadline is re-based off ITSELF, not off `now`, so a cycle that ran
   * long does not push the next one out by its own duration — the cadence is
   * of cycle STARTS. If a whole interval has already been missed, it resyncs
   * to now instead of trying to make it up with back-to-back cycles (catching
   * up by running the writer harder is the opposite of what a background
   * writer should do when the machine is busy).
   *
   * This can only ever make cycles MORE frequent, never less: a real sleep is
   * always at least as long as its request, so the accumulator's 25th tick
   * always landed at or after 250 ms of true elapsed time, and this fires at
   * the first poll wake at or after exactly that. The one case where the
   * accumulator fired sooner is a nanosleep cut short by a signal — it would
   * credit a full 10 ms for a partial sleep — and firing at the true 250 ms
   * instead is the documented contract, comfortably inside the 2 s ring. */
  uint64_t next_flush_ms = le_pd_now_ms() + LE_PD_FLUSH_MS;

  while (atomic_load_explicit(&d->running, memory_order_acquire)) {
    le_pd_sleep_ms(LE_PD_POLL_MS);
    const uint64_t now_ms = le_pd_now_ms();
    if (now_ms < next_flush_ms) continue;
    next_flush_ms += LE_PD_FLUSH_MS;
    if (next_flush_ms <= now_ms) next_flush_ms = now_ms + LE_PD_FLUSH_MS;
    if (!le_pd_drain_cycle(d)) {
      atomic_store_explicit(&d->disk_full, 1, memory_order_release);
      break;
    }
  }

  /* Final pass regardless of how we got here (a graceful stop request, or a
   * disk-full self-stop above): best-effort drain + one last sidecar flush,
   * so the on-disk state reflects everything captured up to this moment.
   * Its own failure is not actionable — the thread is exiting either way. */
  le_pd_drain_cycle(d);
}

le_perf_drain* le_perf_drain_start(le_engine* engine, const char* capture_dir) {
  if (engine == NULL || capture_dir == NULL || capture_dir[0] == '\0') {
    return NULL;
  }
  if (strlen(capture_dir) >= sizeof(((le_perf_drain*)0)->capture_dir)) {
    return NULL; /* reject rather than silently truncate into a wrong path */
  }
  if (!le_pd_mkdir_recursive(capture_dir)) return NULL;

  le_perf_drain* d = (le_perf_drain*)calloc(1, sizeof(le_perf_drain));
  if (d == NULL) return NULL;
  d->engine = engine;
  snprintf(d->capture_dir, sizeof(d->capture_dir), "%s", capture_dir);

  char path[LE_PD_FULL_PATH_MAX];
  snprintf(path, sizeof(path), "%s/master.pcm", d->capture_dir);
  d->master_file.f = fopen(path, "wb");
  if (d->master_file.f == NULL) {
    free(d);
    return NULL;
  }

  for (int32_t c = 0; c < LE_MAX_MONITORED_INPUTS; ++c) {
    if (!(engine->perf.input_mask & (1u << c))) continue;
    snprintf(path, sizeof(path), "%s/input-%d.pcm", d->capture_dir, c);
    d->monitor_file[c].f = fopen(path, "wb");
    if (d->monitor_file[c].f == NULL) {
      fclose(d->master_file.f);
      for (int32_t k = 0; k < c; ++k) {
        if (d->monitor_file[k].f != NULL) fclose(d->monitor_file[k].f);
      }
      free(d);
      return NULL;
    }
  }

  snprintf(path, sizeof(path), "%s/events.log", d->capture_dir);
  d->events_file = fopen(path, "wb");
  if (d->events_file == NULL ||
      !le_pd_write_events_header(d->events_file, engine->sample_rate)) {
    if (d->events_file != NULL) fclose(d->events_file);
    fclose(d->master_file.f);
    for (int32_t c = 0; c < LE_MAX_MONITORED_INPUTS; ++c) {
      if (d->monitor_file[c].f != NULL) fclose(d->monitor_file[c].f);
    }
    free(d);
    return NULL;
  }

  atomic_store_explicit(&d->running, 1, memory_order_release);
  if (!le_pd_thread_start(&d->thread, d)) {
    fclose(d->events_file);
    fclose(d->master_file.f);
    for (int32_t c = 0; c < LE_MAX_MONITORED_INPUTS; ++c) {
      if (d->monitor_file[c].f != NULL) fclose(d->monitor_file[c].f);
    }
    free(d);
    return NULL;
  }
  return d;
}

void le_perf_drain_stop(le_perf_drain* drain, le_perf_stop_reason reason) {
  if (drain == NULL) return;
  if (!atomic_load_explicit(&drain->disk_full, memory_order_acquire) &&
      reason == LE_PERF_STOP_DEVICE_CHANGED) {
    atomic_store_explicit(&drain->device_changed, 1, memory_order_release);
  }
  atomic_store_explicit(&drain->running, 0, memory_order_release);
  le_pd_thread_join(drain->thread);

  if (drain->master_file.f != NULL) fclose(drain->master_file.f);
  for (int32_t c = 0; c < LE_MAX_MONITORED_INPUTS; ++c) {
    if (drain->monitor_file[c].f != NULL) fclose(drain->monitor_file[c].f);
  }
  if (drain->events_file != NULL) fclose(drain->events_file);
  free(drain);
}
