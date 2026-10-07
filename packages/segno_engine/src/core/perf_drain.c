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
#include "engine_digest.h"   /* le_sha256_ctx (each part's payload digest) */
#include "engine_wav.h"      /* le_wav_writer (the one float WAV writer) */
#include "engine_private.h"  /* le_engine, le_perf_capture,
                              * LE_MAX_MONITORED_INPUTS */
#include "layer_staging_ring.h" /* le_layer_staging_ring_pop (retired-layer persistence) */
#include "perf_log_ring.h"   /* le_perf_log_ring_pop (performance event log) */
#include "perf_checkpoint.h" /* durable two-slot checkpoints (#1198 D4) */

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
#include <sys/statvfs.h> /* statvfs (le_volume_space) */
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
#define LE_PD_JSON_BUF 655360 /* generous for LE_PD_MAX_GAPS + LE_PD_MAX_LAYERS
                               * entries + fields (each layer entry runs to
                               * ~150 bytes; LE_PD_MAX_LAYERS of them is
                               * ~300KB at the current LE_MAX_TRACKS *
                               * LE_POOL_SLOTS headroom) — the loop guards in
                               * le_pd_write_sidecar bail out safely if this
                               * ever isn't enough, rather than truncating
                               * silently or overrunning the buffer */
#define LE_PD_SCRATCH_SAMPLES 2048 /* per-drain-cycle pop buffer, in samples */
#define LE_PD_MAX_PARTS 512 /* sealed parts listed per take (all streams); at
                             * the default part size that is a terabyte. A
                             * take that would seal one more stops as a write
                             * failure rather than leave a part unlisted. */
#define LE_PD_HEADER_BYTES LE_PERF_PART_HEADER_BYTES
#define LE_PD_FREE_SAMPLE_CYCLES 20 /* free-space re-read: every ~5 s */
#define LE_PD_NO_LIMIT UINT64_MAX

/* Total and available bytes of the volume holding `path` — segno_engine_api.h
 * has the why, including why no caller shells out to `df` for it.
 *
 * f_bavail, not f_bfree: the reserved blocks a filesystem keeps for root are
 * not room a capture may use, and reporting them would let a take arm onto a
 * volume it cannot actually fill. f_blocks is the whole volume, which is what
 * the Storage page draws as "of N GB" next to the free figure. */
int32_t le_volume_space(const char* path, uint64_t* out_total_bytes,
                        uint64_t* out_free_bytes) {
  if (path == NULL || path[0] == '\0' || out_total_bytes == NULL ||
      out_free_bytes == NULL) {
    return LE_ERR_INVALID;
  }
  *out_total_bytes = 0;
  *out_free_bytes = 0;
#if defined(_WIN32)
  /* The W entry point, not the A one: `path` is UTF-8 (it comes from Dart), and
   * GetDiskFreeSpaceExA would read it in the active ANSI code page — every
   * accented or CJK directory name would silently miss and report "cannot
   * answer", turning the low-disk gate off for exactly the users whose paths
   * are unusual. */
  WCHAR wide[LE_PD_FULL_PATH_MAX];
  const int wide_len = MultiByteToWideChar(CP_UTF8, 0, path, -1, wide,
                                           (int)(sizeof(wide) / sizeof(wide[0])));
  if (wide_len <= 0) return LE_ERR_INVALID;
  ULARGE_INTEGER avail;
  ULARGE_INTEGER total;
  avail.QuadPart = 0;
  total.QuadPart = 0;
  if (!GetDiskFreeSpaceExW(wide, &avail, &total, NULL)) return LE_ERR_DEVICE;
  *out_total_bytes = (uint64_t)total.QuadPart;
  *out_free_bytes = (uint64_t)avail.QuadPart;
  return LE_OK;
#else
  struct statvfs st;
  if (statvfs(path, &st) != 0) return LE_ERR_DEVICE;
  *out_total_bytes = (uint64_t)st.f_blocks * (uint64_t)st.f_frsize;
  *out_free_bytes = (uint64_t)st.f_bavail * (uint64_t)st.f_frsize;
  return LE_OK;
#endif
}

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
 * The budget: le_perf_arm sizes master_ring for LE_PERF_RING_SECONDS_DEFAULT (= 2 s on Internal)
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
static void le_pd_checkpoint_thread_main(void* arg);

static DWORD WINAPI le_pd_win_trampoline(LPVOID arg) {
  le_pd_drain_thread_main(arg);
  return 0;
}

static DWORD WINAPI le_pd_win_checkpoint_trampoline(LPVOID arg) {
  le_pd_checkpoint_thread_main(arg);
  return 0;
}

typedef LPTHREAD_START_ROUTINE le_pd_entry_t;
#define LE_PD_DRAIN_ENTRY le_pd_win_trampoline
#define LE_PD_CHECKPOINT_ENTRY le_pd_win_checkpoint_trampoline

/* A lock held only to copy a few integers (the published progress) or to
 * serialize checkpoint writes. */
typedef SRWLOCK le_pd_mutex_t;
static void le_pd_mutex_init(le_pd_mutex_t* m) { InitializeSRWLock(m); }
static void le_pd_mutex_destroy(le_pd_mutex_t* m) { (void)m; }
static void le_pd_mutex_lock(le_pd_mutex_t* m) { AcquireSRWLockExclusive(m); }
static void le_pd_mutex_unlock(le_pd_mutex_t* m) {
  ReleaseSRWLockExclusive(m);
}

static int le_pd_thread_start(le_pd_thread_t* out, le_pd_entry_t entry,
                              void* arg) {
  /* CREATE_SUSPENDED so the priority really is set before the thread runs a
   * single instruction. Without it the drop would merely race the new thread,
   * and only the fact that the loop opens with a 10 ms sleep would make it
   * land in time — a coincidence, not a guarantee. */
  *out = CreateThread(NULL, 0, entry, arg, CREATE_SUSPENDED, NULL);
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
 * its ~10-16 ms resolution is irrelevant against a 250 ms cadence.
 * GetTickCount64 has no failure mode, so this always reports success; the
 * success/failure return exists for the POSIX twin, whose caller must fail
 * closed on an unreadable clock. */
static int le_pd_now_ms(uint64_t* out_ms) {
  *out_ms = (uint64_t)GetTickCount64();
  return 1;
}

static int le_pd_mkdir_one(const char* path) {
  if (path[0] == '\0') return 1;
  if (_mkdir(path) == 0) return 1;
  return errno == EEXIST;
}
#else
typedef pthread_t le_pd_thread_t;

static void le_pd_drain_thread_main(void* arg);
static void le_pd_checkpoint_thread_main(void* arg);

static void* le_pd_posix_trampoline(void* arg) {
  le_pd_drain_thread_main(arg);
  return NULL;
}

static void* le_pd_posix_checkpoint_trampoline(void* arg) {
  le_pd_checkpoint_thread_main(arg);
  return NULL;
}

typedef void* (*le_pd_entry_t)(void*);
#define LE_PD_DRAIN_ENTRY le_pd_posix_trampoline
#define LE_PD_CHECKPOINT_ENTRY le_pd_posix_checkpoint_trampoline

/* A lock held only to copy a few integers (the published progress) or to
 * serialize checkpoint writes. */
typedef pthread_mutex_t le_pd_mutex_t;
static void le_pd_mutex_init(le_pd_mutex_t* m) { pthread_mutex_init(m, NULL); }
static void le_pd_mutex_destroy(le_pd_mutex_t* m) { pthread_mutex_destroy(m); }
static void le_pd_mutex_lock(le_pd_mutex_t* m) { pthread_mutex_lock(m); }
static void le_pd_mutex_unlock(le_pd_mutex_t* m) { pthread_mutex_unlock(m); }

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

static int le_pd_thread_start(le_pd_thread_t* out, le_pd_entry_t entry,
                              void* arg) {
  pthread_attr_t attr;
  if (le_pd_thread_attr_init(&attr)) {
    const int rc = pthread_create(out, &attr, entry, arg);
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
  return pthread_create(out, NULL, entry, arg) == 0;
}

static void le_pd_thread_join(le_pd_thread_t th) { pthread_join(th, NULL); }

static void le_pd_sleep_ms(int ms) {
  struct timespec ts = {ms / 1000, (long)(ms % 1000) * 1000000L};
  nanosleep(&ts, NULL);
}

/* Milliseconds on a monotonic clock — CLOCK_MONOTONIC, the same source
 * midi_backend_linux.c timestamps with, deliberately not a new abstraction and
 * deliberately not CLOCK_REALTIME (an NTP step or a manual date change must
 * never move the flush deadline).
 *
 * A failure is REPORTED, not swallowed, and *out_ms is left untouched. An
 * earlier revision returned 0 on failure and let the caller compare it against
 * the deadline; that reads as "no time has passed", so a PERSISTENT failure
 * would have deferred the cycle at every poll forever — rings filling,
 * master_ring overrunning, le_pd_catch_up zero-filling the take: #710's
 * outcome, silently, with no self-stop and no disk-full marker. The safe
 * direction on an unreadable clock is to FIRE the cycle, not to skip it, so
 * the caller checks this return. CLOCK_MONOTONIC cannot actually fail on any
 * platform this builds for; the point is that the unreachable case fails
 * cheaply (an early write) rather than catastrophically (a lost take). */
static int le_pd_now_ms(uint64_t* out_ms) {
  struct timespec ts;
  memset(&ts, 0, sizeof(ts));
  if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0) return 0;
  *out_ms = (uint64_t)ts.tv_sec * 1000u + (uint64_t)(ts.tv_nsec / 1000000L);
  return 1;
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
 * to inherit a writable descriptor onto the temp inode. It closes ONLY that
 * window, and it is the narrow one: the open parts, events.log and every staged
 * layer are still plain fopen(..., "wb") with no "e", so a child spawned any
 * time during a capture inherits those writable descriptors for as long as it
 * lives. Widening the close-on-exec discipline to the stdio streams is a
 * separate change, deliberately not smuggled in with a perf fix. */
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
 *     capture_frames = N while the open part's last seconds are still page
 *     cache, so #679's salvage and daw_export lay out an arrangement past the
 *     audio. Un-synced, both sides lose the same tail and stay consistent.
 *   - On ext4 data=ordered an fsync here commits the journal transaction
 *     carrying the open part's block allocations too, so it would drag PCM
 *     writeback onto this cycle synchronously — and the capture rings hold
 *     only LE_PERF_RING_SECONDS_DEFAULT. An SD garbage-collection stall past that
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

/* Test-only global: a BYTE BUDGET for the PCM/silence-fill write path
 * (engine_internal.h). Negative is the production value and means unlimited;
 * 0 fails every write outright — the full-disk simulation
 * le_perf_drain_force_write_failure_for_test has always given — and a positive
 * N lets exactly N more bytes through and then starts failing.
 *
 * That positive case is why this is a budget and not the boolean it replaces:
 * a chunk larger than the remaining budget lands PARTIALLY, which is the one
 * disk-full shape the boolean could not produce and the one #718's desync
 * needs (a pad whose bytes reach the file while the call reports failure).
 * A real filling disk short-writes; a switch that fails at zero bytes does
 * not, so the accounting that has to survive it was untested.
 *
 * Relaxed, and still a single load per write — the same cost as the flag it
 * replaces. A test flips it before/after driving a drain thread (or from the
 * mid-cycle hook, on the drain thread itself); it is not raced against
 * anything else. */
#define LE_PD_WRITE_BUDGET_UNLIMITED (-1)
static _Atomic int64_t g_pd_write_budget = LE_PD_WRITE_BUDGET_UNLIMITED;

void le_perf_drain_force_write_failure_for_test(int enabled) {
  atomic_store_explicit(&g_pd_write_budget,
                        enabled ? 0 : (int64_t)LE_PD_WRITE_BUDGET_UNLIMITED,
                        memory_order_relaxed);
}

void le_perf_drain_set_write_budget_for_test(int64_t bytes) {
  atomic_store_explicit(&g_pd_write_budget,
                        bytes < 0 ? (int64_t)LE_PD_WRITE_BUDGET_UNLIMITED
                                  : bytes,
                        memory_order_relaxed);
}

/* Test-only globals: see le_perf_drain_set_mid_cycle_hook_for_test
 * (engine_internal.h). Genuinely _Atomic, matching the write-failure switch
 * above, because these ARE written by the test thread while the drain thread
 * is live and reading them — plain globals there would be a data race (and
 * an invitation for the compiler to hoist the NULL check out of the cycle).
 *
 * WHAT THE RELEASE/ACQUIRE PAIRING ACTUALLY BUYS (#718) — stated per
 * direction, because it is an invariant in one of them and only a narrowed
 * window in the other, and the comment this replaces claimed both.
 *
 * PUBLISH is the invariant: ctx is stored first and relaxed, fn second and
 * RELEASE, so a drain thread that acquire-loads a non-NULL fn is guaranteed to
 * see the ctx published with it. The hook never runs against a half-published
 * context.
 *
 * TEARDOWN has no equivalent to be had from store order. The reader is two
 * separate loads — `fn = load(acquire); if (fn) fn(load(ctx))` — so a drain
 * thread that loaded a non-NULL fn BEFORE either clear became visible still
 * loads ctx afterwards and calls fn(NULL), whichever order the two stores go
 * in. Store order cannot retract a pointer a reader already holds; closing
 * that would take a single atomic carrying both halves, which is more
 * machinery than a test seam earns.
 *
 * What the clear order below DOES buy is the one interleaving it can reach:
 * retiring fn FIRST means a reader whose fn load lands BETWEEN the two stores
 * sees NULL and skips the call, where the publish order would have handed it a
 * live fn with an already-cleared ctx. That is free, so it is taken — but the
 * safety of teardown is caller-side, and both call sites honour it: they clear
 * only after le_perf_disarm has joined the drain thread, so at that point
 * there is no reader at all. */
static _Atomic(void (*)(void*)) g_pd_mid_cycle_hook = NULL;
static _Atomic(void*) g_pd_mid_cycle_ctx = NULL;

void le_perf_drain_set_mid_cycle_hook_for_test(void (*fn)(void*), void* ctx) {
  if (fn == NULL) {
    /* Teardown: retire the callable first, then the context (see above). */
    atomic_store_explicit(&g_pd_mid_cycle_hook, NULL, memory_order_release);
    atomic_store_explicit(&g_pd_mid_cycle_ctx, ctx, memory_order_relaxed);
    return;
  }
  atomic_store_explicit(&g_pd_mid_cycle_ctx, ctx, memory_order_relaxed);
  atomic_store_explicit(&g_pd_mid_cycle_hook, fn, memory_order_release);
}

/* Test-only: see le_perf_drain_set_volume_free_for_test (engine_internal.h).
 * -1 reads the real volume. Read on the drain thread, written by the test
 * thread before arming. */
static _Atomic int64_t g_pd_volume_free = -1;

/* Test-only: see le_perf_drain_set_free_sample_cycles_for_test. 0 is the
 * production LE_PD_FREE_SAMPLE_CYCLES. */
static _Atomic int g_pd_free_sample_cycles = 0;

void le_perf_drain_set_free_sample_cycles_for_test(int cycles) {
  atomic_store_explicit(&g_pd_free_sample_cycles, cycles < 0 ? 0 : cycles,
                        memory_order_relaxed);
}

void le_perf_drain_set_volume_free_for_test(int64_t bytes) {
  atomic_store_explicit(&g_pd_volume_free, bytes, memory_order_relaxed);
}

typedef struct le_pd_gap {
  uint64_t frame;
  uint64_t duration_frames;
} le_pd_gap;

/* One retired-layer manifest entry (part 5, D-LAYER) — recorded only after
 * its file has been fclose'd, so a reader never sees an entry naming a file
 * whose last bytes are still sitting in a stdio buffer. That is a VISIBILITY
 * ordering, not a durability one: fclose flushes to the page cache and makes
 * the file complete to other processes, it does not put it on the platter.
 * Nothing in this module fsyncs, on either side (see the durability note above
 * the sidecar's descriptor shims, and #727), so a power cut can still lose a
 * staged layer whose manifest entry survived. `channel`/`slot`/
 * `generation` are the same key events.log's LE_PLOG_LAYER_RETIRED entry
 * carries, for a renderer to cross-reference the sample-accurate frame (see
 * layer_staging_ring.h and docs/design/performance-event-log-format.md). */
typedef struct le_pd_layer_manifest_entry {
  int32_t channel;
  int32_t kind;
  uint32_t restore_id;
  int32_t slot;
  uint32_t generation;
  uint64_t frame;
  int32_t frame_count;
  int32_t lane_count;
  char filename[64];
} le_pd_layer_manifest_entry;

/* One captured stream (the master, or one input), written as ordered parts.
 * `f` is the open part; `written` counts every whole frame the stream holds
 * across all its parts (the frame clock the zero-fill compares with elapsed);
 * the part_* fields describe the open part only. */
typedef struct le_pd_file {
  /* The open part, through the engine's one float WAV writer (engine_wav.h).
   * w.file is NULL when no part is open. The drain writes samples through
   * its own budget seam and short-write accounting (le_pd_append) and credits
   * the landed frames to the writer, which owns the header and the seal. */
  le_wav_writer w;
  uint64_t written;      /* frames in the whole stream, all parts */
  int32_t stream;        /* 0 master, 1 + n input n */
  int32_t channels;      /* the frame width */
  int32_t part_index;    /* the open part's index, from 1 */
  uint64_t part_frames;  /* whole frames in the open part */
  uint64_t part_overs;   /* samples above full scale in the open part */
  le_sha256_ctx sha;     /* the open part's payload so far */
} le_pd_file;

/* A sealed part, for the sidecar's `parts` list and the checkpoints. */
typedef le_perf_sealed_part le_pd_sealed_part;

struct le_perf_drain {
  le_engine* engine;
  le_pd_thread_t thread;

  _Atomic int running;       /* cleared by le_perf_drain_stop to end the loop */
  /* 1 once the thread stopped the take itself; `stop_reason` says why. */
  _Atomic int self_stopped;
  _Atomic int device_changed; /* 1 once le_perf_drain_stop(..., DEVICE_CHANGED) */
  /* The thread's own stop (an le_perf_stop_reason, NONE until it stops),
   * and the frame every stream ends at for a reserve or slow-storage stop
   * (LE_PD_NO_LIMIT otherwise). Drain-thread only. */
  int32_t stop_reason;
  uint64_t stop_frame;

  /* The reserve budget (#1198). `free_at_sample` is the volume's free bytes
   * when last read and `bytes_at_sample` what the take had written by then;
   * every byte written since comes off the budget until the next reading.
   * `has_budget` is 0 for a take with no reserve, and while the volume cannot
   * be read. Drain-thread only, except bytes_written's published copy. */
  uint64_t reserve_bytes;
  int has_budget;
  uint64_t free_at_sample;
  uint64_t bytes_at_sample;
  uint64_t bytes_written;
  int cycles_since_sample;
  int layer_over_budget; /* a staged layer did not fit: stop at the reserve */

  char capture_dir[LE_PD_PATH_MAX];
  char sidecar_dir[LE_PD_PATH_MAX]; /* where performance.json lives */
  uint8_t take_id[16];
  int64_t volume_generation;
  uint64_t part_bytes;   /* the most one part file holds, header included */
  int32_t ring_seconds;  /* what the arm granted, reported in the sidecar */
  uint64_t overs;        /* samples above full scale, every stream, sealed parts */

  le_pd_sealed_part sealed[LE_PD_MAX_PARTS];

  /* Checkpoints (#1198 D4). The drain copies its flushed progress into
   * `published` under `progress_lock` after every cycle; the checkpoint
   * thread copies it out under the same lock, so neither waits on the other
   * for more than a few integers. `write_lock` serializes whole checkpoints
   * (the thread's and le_perf_checkpoint_now_for_test's). */
  le_pd_mutex_t progress_lock;
  le_pcp_progress published;
  le_pd_mutex_t write_lock;
  le_pcp_writer cp_writer;
  le_pcp_take cp_take;
  char mirror_dir[LE_PD_PATH_MAX];
  char boot_id[64];
  int32_t checkpoint_ms;
  le_pd_thread_t cp_thread;
  _Atomic int cp_stop; /* write a last checkpoint and exit */
  _Atomic int cp_now;  /* write one as soon as possible */
  uint64_t events_bytes; /* events.log bytes written */
  int sealed_count;

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
  /* Retired images that arrived after the manifest filled. They are dropped,
   * not written: master/monitor capture continues, and the renderer fails
   * any stem whose logged retire/restore has no manifest entry. */
  uint32_t layers_dropped;

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
  return atomic_load_explicit(&drain->self_stopped, memory_order_acquire);
}

/* Counts `bytes` the take has put on its volume, and publishes the total. */
static void le_pd_count_bytes(le_perf_drain* d, uint64_t bytes) {
  d->bytes_written += bytes;
  atomic_store_explicit(&d->engine->a_perf_bytes_written, d->bytes_written,
                        memory_order_relaxed);
}

/* Re-reads the volume's free bytes and restarts the budget's count from
 * here. A take without a reserve has no budget; so has one whose volume
 * cannot be read, until a later reading succeeds. */
static void le_pd_sample_free(le_perf_drain* d) {
  d->cycles_since_sample = 0;
  if (d->reserve_bytes == UINT64_MAX) {
    d->has_budget = 0;
    return;
  }
  const int64_t forced =
      atomic_load_explicit(&g_pd_volume_free, memory_order_relaxed);
  uint64_t total = 0;
  uint64_t free_bytes = 0;
  if (forced >= 0) {
    free_bytes = (uint64_t)forced;
  } else if (forced < -1 ||
             le_volume_space(d->capture_dir, &total, &free_bytes) != LE_OK) {
    d->has_budget = 0;
    return;
  }
  d->has_budget = 1;
  d->free_at_sample = free_bytes;
  d->bytes_at_sample = d->bytes_written;
}

/* Bytes the take may still write before its reserve: the last reading less
 * the reserve, the allowance and everything written since. */
static uint64_t le_pd_budget(const le_perf_drain* d) {
  const uint64_t spent = d->bytes_written - d->bytes_at_sample;
  const uint64_t keep = d->reserve_bytes > UINT64_MAX - LE_PERF_ALLOWANCE_BYTES
                            ? UINT64_MAX
                            : d->reserve_bytes + LE_PERF_ALLOWANCE_BYTES;
  if (keep > d->free_at_sample || spent > d->free_at_sample - keep) return 0;
  return d->free_at_sample - keep - spent;
}

/* Low-level bounded write, reporting how many bytes ACTUALLY landed. Two
 * callers want different things from that number and both are honest answers:
 * le_pd_write below wants all-or-nothing (a short write is a failed write),
 * while le_pd_catch_up wants the count itself, because zero bytes and some
 * bytes leave the capture file in genuinely different states (#718).
 *
 * This is also the ONLY function that consults the write-budget test seam, so
 * every PCM/silence-fill path fails uniformly — le_pd_flush and
 * le_pd_write_sidecar deliberately do NOT check it; see their own definitions
 * for why (the sidecar's exemption is what makes the `stopped_early` marker
 * testable after a forced PCM failure).
 *
 * A short return is NOT retried, which is the same all-or-nothing verdict this
 * path has always given — a short fwrite failed the cycle before #718 too, and
 * all that changes here is that the bytes it DID take are now accounted for
 * rather than dropped on the floor. Retrying is the wrong direction: the
 * realistic causes of a short write to a regular-file stream are terminal
 * (ENOSPC, EDQUOT, EFBIG), so a retry loop turns a full disk into a spin on
 * the one thread that must stay off the audio callback's back. A
 * signal-interrupted write is the single case a retry could rescue, and stdio
 * does not hand this layer the information to tell it apart from the terminal
 * ones; the raw-descriptor sidecar path, which does, retries EINTR explicitly
 * (le_pd_fd_write_all). */
static size_t le_pd_write_some(FILE* f, const void* data, size_t bytes) {
  if (bytes == 0) return 0;
  const int64_t budget =
      atomic_load_explicit(&g_pd_write_budget, memory_order_relaxed);
  if (budget != LE_PD_WRITE_BUDGET_UNLIMITED) {
    if (budget <= 0) return 0;
    if ((uint64_t)budget < (uint64_t)bytes) bytes = (size_t)budget;
  }
  const size_t n = fwrite(data, 1, bytes, f);
  if (budget != LE_PD_WRITE_BUDGET_UNLIMITED && n > 0) {
    /* Stored, not fetch_sub'd, and clamped at 0: `bytes` was already clipped
     * to the budget so this cannot go negative from one writer — but -1 is the
     * UNLIMITED sentinel, and a seam that silently re-enables itself on
     * underflow is the kind of test infrastructure that hides a real bug. */
    int64_t left = budget - (int64_t)n;
    if (left < 0) left = 0;
    atomic_store_explicit(&g_pd_write_budget, left, memory_order_relaxed);
  }
  return n;
}

static int le_pd_write(FILE* f, const void* data, size_t bytes) {
  if (bytes == 0) return 1;
  return le_pd_write_some(f, data, bytes) == bytes;
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
 * magic "PLEV", a uint32 version, and the session's sample rate (so a reader
 * can convert frame -> seconds without cross-referencing the sidecar).
 *
 * The version describes the CODE VOCABULARY as well as the entry layout, so
 * bump it whenever a reader's interpretation of an existing code changes, not
 * only when the 28-byte record does:
 *   1 — the original vocabulary. An aborted take (armed, stopped with nothing
 *       captured) was logged as LE_PLOG_RECORD_END, so a version-1 capture is
 *       subject to #264: the renderer can anchor the disarm image at the abort
 *       frame instead of at the real finalize.
 *   2 — an aborted take logs LE_PLOG_RECORD_ABORT (314). A RECORD_END in a
 *       version-2 file always means content was captured.
 *   3 — a RECORD_ABORT may appear UNPAIRED: a count-in cancelled by the
 *       immediate-finalize primitive (#405, handle_finalize_take) logs 314
 *       for the counting channel even though no RECORD_START ever preceded
 *       it (the count-in's commit is what logs the start). In a version-2
 *       file every 314 closes an open START; from 3 on, a reader must treat
 *       an ABORT with no open START as a no-op, not a malformed file.
 *   4 — two new facts, and RECORD_END carries a take id (#262 / #819):
 *       LE_PLOG_PERF_ARMED (315) records the master loop phase at arm and
 *       LE_PLOG_TRANSPORT_HELD (316) marks a mid-capture transport hold, and
 *       LE_PLOG_RECORD_END's payload is now the `take` arm {channel, take_id}
 *       rather than a bare channel. The renderer REQUIRES these facts — its
 *       old inferences (the race-stale armSnapshot.clockFrame anchor and the
 *       "first RECORD_END while content-free" disarm proxy) were deleted with
 *       no fallback (AGENTS.md), so a pre-4 capture no longer has a supported
 *       phase anchor and renders correctly only if re-captured.
 *   5 — applied Clear restoration and its state/phase/source-end facts
 *       (322/323) reference capture-local immutable restored images.
 *   6 — every callback-applied history image (Clear Undo, layer Undo/Redo,
 *       Redo-from-empty) logs 322 at its exact application frame, so a
 *       channel may carry several 322 facts and a reader switches images on
 *       each; LE_CMD_UNDO_TO_EMPTY (39) is logged raw at its apply frame
 *       (#1143).
 *   7 — the direction fact LE_PLOG_REVERSE (324, #1162) and the Peel
 *       admission record LE_PLOG_PEEL (325, #1164).
 *   8 — assigned to pitch/time Speed (#1179 P2a, numbering ledger).
 *   9 — LE_PLOG_LENGTH (326, #1168): a length edit or its Undo/Redo applied,
 *       with the staged image the callback's 322 names at the same frame.
 *       Version numbers are assigned in landing order: renumber if another
 *       bump lands first.
 * Without the bump, "no 314 in this file" is indistinguishable from "the
 * writer did not know about 314". No reader in this repo gates on the field —
 * le_pr_load_log and daw_export's EventLogReader both check the magic and skip
 * these four bytes — deliberately: refusing to render a capture already on
 * disk helps nobody, and the version-4 facts are simply absent (not
 * misread) in an older file. The field is there so a reader CAN tell, not so
 * this codebase can reject. */
static int le_pd_write_events_header(FILE* f, int32_t sample_rate) {
  static const char magic[4] = {'P', 'L', 'E', 'V'};
  const uint32_t version = 12; /* 8: LE_PLOG_SPEED; 9: LE_PLOG_TRANSPOSE (#1179);
                                 * 10: LE_PLOG_LENGTH (#1168);
                                 * 11: LE_PLOG_HEAD_SPAN, LE_PLOG_RETIME;
                                 * 12: LE_PLOG_SOURCE_LEN (#1179) */
  if (!le_pd_write(f, magic, sizeof(magic))) return 0;
  if (!le_pd_write(f, &version, sizeof(version))) return 0;
  if (!le_pd_write(f, &sample_rate, sizeof(sample_rate))) return 0;
  return 1;
}

/* Serializes one log entry into the fixed 28-byte on-disk record: frame,
 * code, then the compact primitive payload's 16 bytes. Admission explicitly
 * extracts primitive fields from le_command; transaction batches never enter
 * this ring. The compact payload has no padding after its code, so
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
static int le_pd_drain_log_ring(le_perf_drain* d, le_perf_log_ring* ring) {
  le_perf_log_entry entry;
  while (le_perf_log_ring_pop(ring, &entry)) {
    if (!le_pd_write_log_entry(d->events_file, &entry)) return 0;
    le_pd_count_bytes(d, LE_PD_EVENTS_ENTRY_BYTES);
    d->events_bytes += LE_PD_EVENTS_ENTRY_BYTES;
  }
  return 1;
}

/* Writes one retired layer's PCM to its own file, interleaving lanes the same
 * way multi-channel PCM is interleaved everywhere else in this format
 * (lane0[0], lane1[0], ..., lane0[1], lane1[1], ...). ALWAYS frees every
 * `entry->lane_pcm[l]` before returning, success or failure — this function
 * takes ownership of the staged copy unconditionally, matching
 * layer_staging_ring.h's documented handoff contract. Only records a
 * manifest entry on success, and only once the file is fclose'd — i.e. once
 * every byte has reached the OS and the file is complete to any other reader,
 * which is not the same as being on the device (no fsync here or anywhere else
 * in this module) — see le_pd_layer_manifest_entry's doc comment for why. */
static int le_pd_write_staged_layer(le_perf_drain* d,
                                    const le_staged_layer* entry) {
  char filename[64];
  if (entry->kind == 1)
    snprintf(filename, sizeof(filename), "restore-%d-%u.pcm", entry->channel, entry->restore_id);
  else
    snprintf(filename, sizeof(filename), "layer-%d-%llu-%d.pcm", entry->channel,
             (unsigned long long)entry->frame, entry->slot);
  char path[LE_PD_FULL_PATH_MAX];
  snprintf(path, sizeof(path), "%s/%s", d->capture_dir, filename);

  if (d->layer_count >= LE_PD_MAX_LAYERS) {
    for (int32_t l = 0; l < entry->lane_count; ++l) free(entry->lane_pcm[l]);
    d->layers_dropped++;
    return 1;
  }
  /* A layer the reserve budget cannot pay for is not written: the take stops
   * at the reserve now (le_pd_drain_cycle) rather than run the volume out
   * and end as a failed write (#1198). Counted like any unpersisted layer. */
  if (d->has_budget &&
      (uint64_t)entry->frame_count * (uint64_t)entry->lane_count *
              sizeof(float) >
          le_pd_budget(d)) {
    for (int32_t l = 0; l < entry->lane_count; ++l) free(entry->lane_pcm[l]);
    d->layers_dropped++;
    d->layer_over_budget = 1;
    return 1;
  }

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

  if (ok) {
    le_pd_count_bytes(d, (uint64_t)entry->frame_count *
                             (uint64_t)entry->lane_count * sizeof(float));
    le_pd_layer_manifest_entry* m = &d->layers[d->layer_count];
    m->channel = entry->channel;
    m->kind = entry->kind;
    m->restore_id = entry->restore_id;
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

/* THE SHORT-WRITE CREDIT, in one place because it is one rule (#718, #790).
 * Turns the bytes a write actually LANDED into the frames the file now holds:
 * advances `pf->written`, rewinds over the torn remainder, and returns the
 * count, so a caller that also reports on it (le_pd_catch_up's silence counter)
 * reports the same number the file got. `channels` must be > 0 — both callers
 * reject that before they write anything.
 *
 * FLOORS to whole frames. fwrite is byte-granular, so a disk that gives out
 * mid-write stops wherever it stops: mid-frame, and even mid-float. Only a
 * frame that is entirely on disk is a frame of the take, and inventing a count
 * for one that is half there would be the dishonest direction.
 *
 * REWINDS what it floored off, rather than leaving it at EOF. A torn partial
 * frame at the end of the file is harmless only while nothing appends after
 * it, and something does: the disk can free up between the cycle that failed
 * and the final one — which is exactly what the fixtures simulate — and the
 * catch-up then starts its padding part-way into a frame. From there every
 * sample is read against the wrong channel and the file length is no longer a
 * whole number of frames, which is a permanent misalignment of the rest of the
 * take, not a lost tail. The capture files are opened "wb", not append, so
 * seeking back over the residue costs nothing and the next write overwrites
 * it.
 *
 * The file is NOT truncated, only the position moved, so the residue does
 * survive in one case: the final pass pads from `pf->written` and always has
 * at least one frame to pad after a short write, so the only way nothing
 * overwrites the residue is a disk still full then — the case where nothing
 * could be written anyway. Same if the seek itself fails, which a genuinely
 * full disk can do (fseek flushes the stream). Neither is papered over:
 * `pf->written` is floored either way, so this module never claims a frame the
 * file does not hold, and a reader floors the length on the frame size exactly
 * as this does. */
static uint64_t le_pd_whole_frames_landed(le_pd_file* pf, uint64_t landed,
                                          int channels) {
  const uint64_t frame_bytes = (uint64_t)channels * sizeof(float);
  const uint64_t frames = landed / frame_bytes;
  const uint64_t torn = landed - frames * frame_bytes;
  if (torn > 0) fseek(pf->w.file, -(long)torn, SEEK_CUR);
  pf->written += frames;
  return frames;
}

/* Drains everything currently available from `ring` (a le_audio_ring of
 * `channels`-wide frames) into `pf`'s file, looping until the ring reports
 * less than a full scratch buffer (i.e. it is now empty).
 *
 * ADVANCES `pf->written` ON THE FAILURE PATH TOO, by whatever the short write
 * landed (#790) — which is why this cannot use the all-or-nothing le_pd_write
 * any more. The popped frames are gone from the ring either way, so no audio
 * is re-written; what IS retried is this function itself, on the drain
 * thread's unconditional final pass, and the catch-up that follows it pads
 * from `pf->written`. Leaving it behind the bytes already on disk is what made
 * the master stream come out LONGER than `elapsed` by the residue — the same shape as
 * the pad's own gap (#718), milder only because there is no whole gap to
 * duplicate here.
 *
 * Returns 0 on any write failure, short or refused, which self-stops the
 * capture — see le_pd_write_some for why a short write is not retried. */
/* ---- ordered float parts (#1198) ----
 *
 * Each stream is a sequence of parts `<stream>-NNN.wav`, each at most
 * `part_bytes` long including its LE_PD_HEADER_BYTES header (the layout is
 * documented above le_perf_target in segno_engine_api.h). A part is opened
 * with zero sizes in its header, appended to in whole frames, and SEALED —
 * sizes patched, payload digest and overs recorded — when the next frame
 * needs a new part or the take ends. Sealing is lazy on purpose: a part that
 * filled exactly as the take stopped is not followed by an empty one.
 *
 * Header writes and patches go straight to fwrite rather than through
 * le_pd_write_some: the write-budget test seam models the PAYLOAD filling a
 * disk, and every existing budget in the suite is a count of sample bytes. A
 * header write that fails still fails the cycle like any other write. */

static void le_pd_part_filename(int32_t stream, int32_t index, char* out,
                                size_t cap) {
  le_perf_part_filename(stream, index, out, cap);
}

/* The 32-byte `sgno` chunk: take id, stream, part index, 12 reserved zero
 * bytes, little-endian (engine_wav.h writes it between `fmt ` and `data`,
 * which puts the payload at LE_PD_HEADER_BYTES). */
static void le_pd_sgno_chunk(const le_perf_drain* d, const le_pd_file* pf,
                             uint8_t out[32]) {
  memset(out, 0, 32);
  memcpy(out, d->take_id, 16);
  out[16] = (uint8_t)(pf->stream & 0xFF);
  out[17] = (uint8_t)((pf->stream >> 8) & 0xFF);
  out[18] = (uint8_t)(pf->part_index & 0xFF);
  out[19] = (uint8_t)((pf->part_index >> 8) & 0xFF);
}

/* Frames one part of `pf` holds. */
static uint64_t le_pd_part_capacity(const le_perf_drain* d,
                                    const le_pd_file* pf) {
  return (d->part_bytes - LE_PD_HEADER_BYTES) /
         ((uint64_t)pf->channels * sizeof(float));
}

/* Opens `pf`'s next part and writes its header with zero sizes. */
static int le_pd_open_part(le_perf_drain* d, le_pd_file* pf) {
  pf->part_index++;
  pf->part_frames = 0;
  pf->part_overs = 0;
  le_sha256_init(&pf->sha);
  char name[64];
  char path[LE_PD_FULL_PATH_MAX];
  le_pd_part_filename(pf->stream, pf->part_index, name, sizeof(name));
  snprintf(path, sizeof(path), "%s/%s", d->capture_dir, name);
  uint8_t sgno[32];
  le_pd_sgno_chunk(d, pf, sgno);
  if (!le_wav_open(&pf->w, path, d->engine->sample_rate, pf->channels, "sgno",
                   sgno, sizeof(sgno))) {
    le_wav_abandon(&pf->w);
    return 0;
  }
  le_pd_count_bytes(d, (uint64_t)pf->w.header_bytes);
  return pf->w.header_bytes == LE_PD_HEADER_BYTES;
}

/* Seals `pf`'s open part through the writer (sizes patched, flushed,
 * closed) and lists it with its digest and overs. le_pd_append keeps room
 * in the list for every open part; should it ever be full, the part is
 * left open (recovery measures it) rather than sealed and unlisted. Not synced here: durability is the checkpoint's job
 * (plan D4, Part 4). */
static int le_pd_seal_part(le_perf_drain* d, le_pd_file* pf) {
  if (pf->w.file == NULL) return 0;
  if (d->sealed_count >= LE_PD_MAX_PARTS) return 0; /* before sealing */
  const int ok = le_wav_seal(&pf->w, 0);
  le_pd_sealed_part* sp = &d->sealed[d->sealed_count];
  sp->stream = pf->stream;
  sp->index = pf->part_index;
  sp->frames = pf->part_frames;
  sp->overs = pf->part_overs;
  le_sha256_final(&pf->sha, sp->sha256);
  d->sealed_count++;
  d->overs += pf->part_overs;
  return ok;
}

/* The streams the take writes: the master and each captured input. */
static int32_t le_pd_stream_count(const le_perf_drain* d) {
  int32_t n = 1;
  for (int32_t c = 0; c < LE_MAX_MONITORED_INPUTS; ++c) {
    if (d->engine->perf.input_mask & (1u << c)) n++;
  }
  return n;
}

/* Samples whose magnitude exceeds 1.0 — the master is tapped before the
 * master gain and limiter, so a sum above full scale is real and is kept;
 * this only counts it. NaN is not an over. */
static uint64_t le_pd_count_overs(const float* samples, size_t n) {
  uint64_t overs = 0;
  for (size_t i = 0; i < n; ++i) {
    if (samples[i] > 1.0f || samples[i] < -1.0f) overs++;
  }
  return overs;
}

/* Appends `frames` whole frames to `pf` — from `src`, or digital silence when
 * `src` is NULL — rolling to a new part whenever the open one is full. Every
 * frame that lands is digested and counted (le_pd_whole_frames_landed credits
 * `pf->written` and rewinds a torn tail). Returns 0 on any failed write, open
 * or seal; whatever landed before it stays credited. */
static int le_pd_append(le_perf_drain* d, le_pd_file* pf, const float* src,
                        uint64_t frames) {
  static const float kZeros[1024] = {0};
  const int channels = pf->channels;
  const uint64_t capacity = le_pd_part_capacity(d, pf);
  while (frames > 0) {
    if (pf->w.file == NULL) return 0;
    if (pf->part_frames >= capacity) {
      /* Room must stay in the parts list for every stream's open part, which
       * the final pass seals: a take that would outgrow it stops here, as a
       * write failure, with every part on disk listed. */
      if (d->sealed_count + le_pd_stream_count(d) >= LE_PD_MAX_PARTS) return 0;
      if (!le_pd_seal_part(d, pf) || !le_pd_open_part(d, pf)) return 0;
    }
    uint64_t n = capacity - pf->part_frames;
    if (n > frames) n = frames;
    if (src == NULL) {
      const uint64_t zero_frames = 1024 / (uint64_t)channels;
      if (n > zero_frames) n = zero_frames;
    }
    const float* data = src != NULL ? src : kZeros;
    const size_t want = (size_t)(n * (uint64_t)channels * sizeof(float));
    const size_t got = le_pd_write_some(pf->w.file, data, want);
    const uint64_t landed = le_pd_whole_frames_landed(pf, (uint64_t)got,
                                                      channels);
    const size_t landed_samples = (size_t)(landed * (uint64_t)channels);
    if (landed > 0) {
      le_sha256_update(&pf->sha, data, landed_samples * sizeof(float));
      if (src != NULL) pf->part_overs += le_pd_count_overs(src, landed_samples);
      pf->part_frames += landed;
      le_wav_note_frames(&pf->w, landed);
      le_pd_count_bytes(d, landed_samples * sizeof(float));
    }
    if (got != want) return 0;
    if (src != NULL) src += landed_samples;
    frames -= n;
  }
  return 1;
}

/* Drains everything currently available from `ring` into `pf`'s parts,
 * looping until the ring reports less than a full scratch buffer.
 *
 * ADVANCES `pf->written` ON THE FAILURE PATH TOO, by whatever the short write
 * landed (#790), through le_pd_append. The popped frames are gone from the
 * ring either way, so no audio is re-written; what IS retried is this
 * function itself, on the drain thread's unconditional final pass, and the
 * catch-up that follows it pads from `pf->written`.
 *
 * Returns 0 on any write failure, short or refused, which self-stops the
 * capture — see le_pd_write_some for why a short write is not retried. */
static int le_pd_drain_ring(le_perf_drain* d, le_pd_file* pf,
                            le_audio_ring* ring, float* scratch,
                            size_t scratch_samples, uint64_t cap) {
  const int channels = pf->channels;
  if (channels <= 0) return 1;
  const size_t max_frames = scratch_samples / (size_t)channels;
  /* Never past `cap` (#1198): what lies beyond it stays in the ring, for the
   * next cycle or, once the take has stopped, for nobody. */
  while (pf->written < cap) {
    size_t want = max_frames;
    if (cap - pf->written < (uint64_t)want) want = (size_t)(cap - pf->written);
    const size_t popped =
        le_audio_ring_pop(ring, scratch, want * (size_t)channels);
    if (popped == 0) return 1;
    const size_t frames = popped / (size_t)channels;
    if (!le_pd_append(d, pf, scratch, (uint64_t)frames)) return 0;
    if (frames < want) return 1;
  }
  return 1;
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
 * actually reached the file, and `pf->written` is advanced by that SAME
 * number. Both halves of that matter, and they are the same fact stated twice:
 * `pf->written` is this module's claim about how much of the file exists, and
 * the counter is its claim about how much of that is silence. Neither may
 * count a byte the disk refused, and neither may forget one it took.
 *
 * Bumping the counter up front breaks the first: a pad that fails would charge
 * for silence that never reached the file — a disk-full stop reporting roughly
 * twice the silence it wrote, once the re-pad below charges again.
 *
 * Leaving `pf->written` untouched on failure breaks the second, which is what
 * #718 found. A pad is CHUNKED, and a filling disk does not fail on a chunk
 * boundary: it short-writes. The bytes before the short return are on disk and
 * cannot be taken back, so a cycle that abandons the whole span re-pads bytes
 * the file already has — the next cycle (and the unconditional final one) pad
 * from a `written` that is behind the real file length, and the stream ends
 * LONGER than `elapsed`. That is not a lost tail, it is a permanent offset:
 * every frame after the gap sits later in the file than its frame number says,
 * so #679's salvage and daw_export lay the whole remainder of the take out
 * against the wrong clock. Advancing by what landed makes the re-pad top up
 * only the part that did not, which is also what keeps the counter's two
 * cycles summing to the gap exactly once.
 *
 * What happens to a TORN tail — a short write stopping mid-frame, or even
 * mid-float — is le_pd_whole_frames_landed's business, not this function's:
 * the count is floored and the residue is rewound so the next append still
 * lands on a frame boundary. The rule lives there because it is the same rule
 * le_pd_drain_ring needs (#718 and #790 are one bug in two functions), and its
 * reasoning is written out once, above it.
 *
 * The gap LIST can still name a span the disk refused — position is
 * diagnostic. The total stays a count of silence genuinely on disk, which is
 * what the manifest documents it as. */
static int le_pd_catch_up(le_perf_drain* d, le_pd_file* pf,
                          uint64_t elapsed) {
  if (pf->written >= elapsed || pf->channels <= 0) return 1;
  const uint64_t gap = elapsed - pf->written;

  if (d->gap_count < LE_PD_MAX_GAPS) {
    d->gaps[d->gap_count].frame = pf->written;
    d->gaps[d->gap_count].duration_frames = gap;
    d->gap_count++;
  }

  /* le_pd_append credits `pf->written` by exactly the frames that landed,
   * success or failure, so the difference is the silence genuinely on disk. */
  const uint64_t before = pf->written;
  const int ok = le_pd_append(d, pf, NULL, gap);
  const uint64_t padded_frames = pf->written - before;
  if (padded_frames > 0) {
    atomic_fetch_add_explicit(&d->engine->a_perf_zero_filled_frames,
                              padded_frames, memory_order_relaxed);
  }
  return ok;
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
 * `report_disk_full` is an explicit parameter, not a read of d->self_stopped:
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

  /* The take's identity and its ordered parts (#1198): every sealed part with
   * its digest, then each stream's open part (no digest yet), stream by
   * stream in index order — the order playback and export use them in. */
  if (off < 0 || off >= LE_PD_JSON_BUF) goto done; /* truncated */
  {
    char take_hex[33];
    for (int i = 0; i < 16; ++i) {
      snprintf(take_hex + 2 * i, 3, "%02x", d->take_id[i]);
    }
    uint64_t overs = d->overs;
    if (d->master_file.w.file != NULL) overs += d->master_file.part_overs;
    for (int32_t c = 0; c < LE_MAX_MONITORED_INPUTS; ++c) {
      if (d->monitor_file[c].w.file != NULL) overs += d->monitor_file[c].part_overs;
    }
    off += snprintf(buf + off, (size_t)LE_PD_JSON_BUF - (size_t)off,
                   "  \"take_id\": \"%s\",\n"
                   "  \"encoding\": \"f32\",\n"
                   "  \"volume_generation\": %lld,\n"
                   "  \"ring_seconds\": %d,\n"
                   "  \"overs\": %llu,\n"
                   "  \"parts\": [",
                   take_hex, (long long)d->volume_generation, d->ring_seconds,
                   (unsigned long long)overs);
  }
  {
    int first_part = 1;
    for (int32_t k = -1; k < LE_MAX_MONITORED_INPUTS; ++k) {
      const le_pd_file* pf = k < 0 ? &d->master_file : &d->monitor_file[k];
      if (k >= 0 && !(d->engine->perf.input_mask & (1u << k))) continue;
      const uint64_t frame_bytes = (uint64_t)pf->channels * sizeof(float);
      for (int i = 0; i < d->sealed_count && off >= 0 && off < LE_PD_JSON_BUF;
           ++i) {
        const le_pd_sealed_part* sp = &d->sealed[i];
        if (sp->stream != pf->stream) continue;
        char name[64];
        char sha_hex[2 * LE_SHA256_BYTES + 1];
        le_pd_part_filename(sp->stream, sp->index, name, sizeof(name));
        for (int b = 0; b < LE_SHA256_BYTES; ++b) {
          snprintf(sha_hex + 2 * b, 3, "%02x", sp->sha256[b]);
        }
        off += snprintf(buf + off, (size_t)LE_PD_JSON_BUF - (size_t)off,
                       "%s{\"stream\": %d, \"index\": %d, \"file\": \"%s\", "
                       "\"frames\": %llu, \"bytes\": %llu, \"overs\": %llu, "
                       "\"sha256\": \"%s\"}",
                       first_part ? "" : ", ", sp->stream, sp->index, name,
                       (unsigned long long)sp->frames,
                       (unsigned long long)(LE_PD_HEADER_BYTES +
                                            sp->frames * frame_bytes),
                       (unsigned long long)sp->overs, sha_hex);
        first_part = 0;
      }
      if (pf->w.file != NULL && off >= 0 && off < LE_PD_JSON_BUF) {
        char name[64];
        le_pd_part_filename(pf->stream, pf->part_index, name, sizeof(name));
        off += snprintf(buf + off, (size_t)LE_PD_JSON_BUF - (size_t)off,
                       "%s{\"stream\": %d, \"index\": %d, \"file\": \"%s\", "
                       "\"frames\": %llu, \"bytes\": %llu, \"overs\": %llu}",
                       first_part ? "" : ", ", pf->stream, pf->part_index,
                       name, (unsigned long long)pf->part_frames,
                       (unsigned long long)(LE_PD_HEADER_BYTES +
                                            pf->part_frames * frame_bytes),
                       (unsigned long long)pf->part_overs);
        first_part = 0;
      }
    }
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
                   "\"kind\": %d, \"restore_id\": %u, \"filename\": \"%s\"}",
                   i == 0 ? "" : ", ", m->channel, m->slot, m->generation,
                   (unsigned long long)m->frame, m->frame_count,
                   m->lane_count, m->kind, m->restore_id, m->filename);
  }
  if (off < 0 || off >= LE_PD_JSON_BUF) goto done; /* truncated */
  off += snprintf(buf + off, (size_t)LE_PD_JSON_BUF - (size_t)off, "],\n");
  if (d->layers_dropped)
    off += snprintf(buf + off, (size_t)LE_PD_JSON_BUF - (size_t)off,
                   "  \"layers_dropped\": %u,\n", d->layers_dropped);
  /* Retired images the engine refused to stage (copy allocation failure or
   * a full staging ring): their retires are logged but have no manifest
   * entry, so the renderer must not treat them as complete either. */
  const uint32_t layer_overruns = atomic_load_explicit(
      &d->engine->a_perf_layer_overruns, memory_order_relaxed);
  if (layer_overruns)
    off += snprintf(buf + off, (size_t)LE_PD_JSON_BUF - (size_t)off,
                   "  \"layer_overruns\": %u,\n", layer_overruns);
  /* The backing player (#1200) was playing and routed to the captured bus:
   * master.pcm may hold audio the stems never reproduce (the backing is not
   * perf-logged). A muted bus or a zero level still counts. */
  if (atomic_load_explicit(&d->engine->a_perf_backing_blocks,
                           memory_order_relaxed) != 0u)
    off += snprintf(buf + off, (size_t)LE_PD_JSON_BUF - (size_t)off,
                   "  \"backing_in_master\": true,\n");

  /* The thread's own stop first: it happened before any disarm could. */
  const char* stopped_early = NULL;
  if (d->stop_reason == LE_PERF_STOP_RESERVE_REACHED) {
    stopped_early = "reserve_reached";
  } else if (d->stop_reason == LE_PERF_STOP_SLOW_STORAGE) {
    stopped_early = "slow_storage";
  } else if (report_disk_full ||
             d->stop_reason == LE_PERF_STOP_WRITE_FAILED) {
    stopped_early = "disk_full";
  }
  if (stopped_early != NULL) {
    off += snprintf(buf + off, (size_t)LE_PD_JSON_BUF - (size_t)off,
                   "  \"stopped_early\": \"%s\",\n", stopped_early);
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
            d->sidecar_dir);
    snprintf(final_path, sizeof(final_path), "%s/performance.json",
            d->sidecar_dir);

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
/* The streams a take writes: the master, then each captured input. */
static le_pd_file* le_pd_stream(le_perf_drain* d, int32_t k) {
  if (k < 0) return &d->master_file;
  if (!(d->engine->perf.input_mask & (1u << k))) return NULL;
  return &d->monitor_file[k];
}

/* Bytes taking stream `pf` from its frames to `to` costs: the samples, and
 * the header of every part it would open (le_pd_append opens one only when
 * the next frame needs it, so a full open part adds nothing by itself). */
static uint64_t le_pd_cost_to(const le_perf_drain* d, const le_pd_file* pf,
                              uint64_t to) {
  if (to <= pf->written) return 0;
  const uint64_t frames = to - pf->written;
  const uint64_t capacity = le_pd_part_capacity(d, pf);
  const uint64_t room = pf->w.file != NULL && pf->part_frames < capacity
                            ? capacity - pf->part_frames
                            : 0;
  const uint64_t rest = frames > room ? frames - room : 0;
  const uint64_t new_parts = (rest + capacity - 1) / capacity;
  return frames * (uint64_t)pf->channels * sizeof(float) +
         new_parts * LE_PD_HEADER_BYTES;
}

/* The last frame every stream can reach together within `budget` bytes: the
 * C twin of RecordingFormat.remainingFramesTogether, counted in absolute
 * frames because the streams can stand a block apart at a cycle's start. */
static uint64_t le_pd_frames_within(le_perf_drain* d, uint64_t budget) {
  uint64_t lowest = UINT64_MAX;
  uint64_t highest = 0;
  uint64_t frame_bytes = 0;
  for (int32_t k = -1; k < LE_MAX_MONITORED_INPUTS; ++k) {
    const le_pd_file* pf = le_pd_stream(d, k);
    if (pf == NULL) continue;
    if (pf->written < lowest) lowest = pf->written;
    if (pf->written > highest) highest = pf->written;
    frame_bytes += (uint64_t)pf->channels * sizeof(float);
  }
  if (frame_bytes == 0) return lowest;
  /* Every frame past `highest` costs at least frame_bytes, so `hi` is out
   * of reach and `lo` (which costs nothing) is not. */
  uint64_t lo = lowest;
  uint64_t hi = highest + budget / frame_bytes + 1;
  while (lo + 1 < hi) {
    const uint64_t mid = lo + (hi - lo) / 2;
    uint64_t cost = 0;
    for (int32_t k = -1; k < LE_MAX_MONITORED_INPUTS && cost <= budget; ++k) {
      const le_pd_file* pf = le_pd_stream(d, k);
      if (pf != NULL) cost += le_pd_cost_to(d, pf, mid);
    }
    if (cost <= budget) {
      lo = mid;
    } else {
      hi = mid;
    }
  }
  return lo;
}

/* Whether every stream holds at least `frame` frames. With pops capped at
 * `elapsed` they all hold exactly the same count; ">=" keeps a stream that
 * somehow stood past the stop frame from holding the take open forever. */
static int le_pd_all_streams_reached(le_perf_drain* d, uint64_t frame) {
  for (int32_t k = -1; k < LE_MAX_MONITORED_INPUTS; ++k) {
    const le_pd_file* pf = le_pd_stream(d, k);
    if (pf != NULL && pf->written < frame) return 0;
  }
  return 1;
}

/* The fewest frames any stream holds. */
static uint64_t le_pd_lowest_written(le_perf_drain* d) {
  uint64_t lowest = UINT64_MAX;
  for (int32_t k = -1; k < LE_MAX_MONITORED_INPUTS; ++k) {
    const le_pd_file* pf = le_pd_stream(d, k);
    if (pf != NULL && pf->written < lowest) lowest = pf->written;
  }
  return lowest == UINT64_MAX ? 0 : lowest;
}

/* Publishes the take's overs so far: every sealed part, and each open one. */
static void le_pd_publish_overs(le_perf_drain* d) {
  uint64_t overs = d->overs;
  for (int32_t k = -1; k < LE_MAX_MONITORED_INPUTS; ++k) {
    const le_pd_file* pf = le_pd_stream(d, k);
    if (pf != NULL && pf->w.file != NULL) overs += pf->part_overs;
  }
  atomic_store_explicit(&d->engine->a_perf_overs, overs, memory_order_relaxed);
}

/* Publishes the thread's own stop: the engine's reason first (unless a
 * disarm already set one), then the self-stopped flag the app polls. Only
 * after the sidecar carrying the same reason is written. */
static void le_pd_publish_stop(le_perf_drain* d) {
  int32_t none = LE_PERF_STOP_NONE;
  atomic_compare_exchange_strong_explicit(&d->engine->a_perf_stop_reason,
                                          &none, d->stop_reason,
                                          memory_order_relaxed,
                                          memory_order_relaxed);
  atomic_store_explicit(&d->self_stopped, 1, memory_order_release);
}

/* Publishes what this cycle flushed (#1198 D4): every stream's open part,
 * how many sealed parts and layer files are final, events.log's length and
 * the frames every stream holds. Only after the flush, so a checkpoint never
 * names bytes still in a stdio buffer. Allocation-free: a struct copy under
 * a lock held for nothing else. */
static void le_pd_publish_progress(le_perf_drain* d) {
  le_pcp_progress p;
  memset(&p, 0, sizeof(p));
  uint64_t frames = UINT64_MAX;
  uint64_t overs = d->overs;
  for (int32_t k = -1; k < LE_MAX_MONITORED_INPUTS; ++k) {
    const le_pd_file* pf = le_pd_stream(d, k);
    if (pf == NULL) continue;
    le_pcp_stream* s = &p.streams[p.stream_count++];
    s->stream = pf->stream;
    s->channels = pf->channels;
    if (pf->w.file != NULL) {
      s->open_index = pf->part_index;
      s->open_frames = pf->part_frames;
      s->open_overs = pf->part_overs;
      overs += pf->part_overs;
    }
    if (pf->written < frames) frames = pf->written;
  }
  p.sealed_count = d->sealed_count;
  p.layer_count = d->layer_count;
  p.events_bytes = d->events_bytes;
  p.frames = frames == UINT64_MAX ? 0 : frames;
  p.overs = overs;
  le_pd_mutex_lock(&d->progress_lock);
  d->published = p;
  le_pd_mutex_unlock(&d->progress_lock);
}

/* One checkpoint of the latest published progress. Never on the drain
 * thread. A failure leaves the other slot standing and is counted; the take
 * goes on. */
static int le_pd_checkpoint(le_perf_drain* d) {
  le_pd_mutex_lock(&d->write_lock);
  le_pcp_progress p;
  le_pd_mutex_lock(&d->progress_lock);
  p = d->published;
  le_pd_mutex_unlock(&d->progress_lock);
  const int ok = le_pcp_write(&d->cp_writer, &d->cp_take, &p);
  le_pd_mutex_unlock(&d->write_lock);
  if (!ok) {
    atomic_fetch_add_explicit(&d->engine->a_perf_checkpoint_failures, 1u,
                              memory_order_relaxed);
  }
  return ok;
}

/* The checkpoint thread: every `checkpoint_ms` (never, with 0), on request,
 * and once more when the take stops. Polls like the drain thread, so a stop
 * is never more than a poll away. */
static void le_pd_checkpoint_thread_main(void* arg) {
  le_perf_drain* d = (le_perf_drain*)arg;
  le_pd_thread_lower_own_priority();
  uint64_t next_ms = 0;
  if (d->checkpoint_ms > 0 && le_pd_now_ms(&next_ms)) {
    next_ms += (uint64_t)d->checkpoint_ms;
  }
  for (;;) {
    le_pd_sleep_ms(LE_PD_POLL_MS);
    const int stop = atomic_load_explicit(&d->cp_stop, memory_order_acquire);
    const int now =
        atomic_exchange_explicit(&d->cp_now, 0, memory_order_acq_rel);
    int due = 0;
    uint64_t now_ms = 0;
    if (d->checkpoint_ms > 0 && le_pd_now_ms(&now_ms) && now_ms >= next_ms) {
      due = 1;
      next_ms += (uint64_t)d->checkpoint_ms;
      if (next_ms <= now_ms) next_ms = now_ms + (uint64_t)d->checkpoint_ms;
    }
    if (stop || now || due) le_pd_checkpoint(d);
    if (stop) return;
  }
}

int le_perf_checkpoint_now_for_test(struct le_engine* engine) {
  if (engine == NULL || engine->perf.drain == NULL) return 0;
  return le_pd_checkpoint(engine->perf.drain);
}

static int le_pd_drain_cycle(le_perf_drain* d, int final) {
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
  /* After the acquire above: a drop in any block counted in `elapsed` is
   * visible here (the audio thread records it before that block's release
   * add). A drop in a later block may or may not be; either is handled. */
  const uint64_t first_drop = atomic_load_explicit(
      &e->a_perf_first_drop_frame, memory_order_relaxed);

  const int sample_every =
      atomic_load_explicit(&g_pd_free_sample_cycles, memory_order_relaxed);
  if (!final && ++d->cycles_since_sample >=
                    (sample_every > 0 ? sample_every : LE_PD_FREE_SAMPLE_CYCLES)) {
    le_pd_sample_free(d);
  }

  /* Performance event log (part 3): drain both perf-log rings — the audio-
   * thread-producer log_ring first, then the control-thread-producer
   * log_ctrl_ring — and append every entry to events.log. Order between the
   * two streams is a file-write-order interleaving, not a global frame sort
   * (see docs/design/performance-event-log-format.md): each stream is
   * monotonic in frame on its own, but a control-side param change and an
   * audio-thread command from the same drain interval can land in either
   * order in the file.
   *
   * Written before the audio, with the retired layers below (#1198): they
   * come off the same reserve budget, so the frames the audio may still take
   * are counted after them. */
  if (!le_pd_drain_log_ring(d, &e->perf.log_ring)) ok = 0;
  if (ok && !le_pd_drain_log_ring(d, &e->perf.log_ctrl_ring)) ok = 0;

  /* Retired-layer persistence (part 5, D-LAYER): each staged layer is its
   * own self-contained file (open, write, fclose — not a long-lived stream
   * like the parts), so there is nothing to flush separately below: the
   * fclose inside le_pd_write_staged_layer has already pushed every byte out
   * of stdio and into the page cache before the manifest entry is recorded.
   * That is the same guarantee le_pd_flush gives the long-lived streams —
   * visible to other processes, NOT on the device. */
  if (ok && !le_pd_drain_layer_staging(d)) ok = 0;

  /* Where every stream must end (#1198): the frame a take already stopped
   * at, the first frame a ring dropped, or the last frame the reserve
   * budget pays for, whichever comes first. Nothing past it is written. */
  uint64_t cap = d->stop_frame;
  int32_t cap_reason = LE_PERF_STOP_NONE;
  if (first_drop < cap) {
    cap = first_drop;
    cap_reason = LE_PERF_STOP_SLOW_STORAGE;
  }
  if (d->has_budget) {
    const uint64_t affordable = le_pd_frames_within(d, le_pd_budget(d));
    if (affordable < cap) {
      cap = affordable;
      cap_reason = LE_PERF_STOP_RESERVE_REACHED;
    }
  }
  if (d->layer_over_budget) {
    const uint64_t here = le_pd_lowest_written(d);
    if (here < cap) {
      cap = here;
      cap_reason = LE_PERF_STOP_RESERVE_REACHED;
    }
  }

  /* Never past `elapsed` this cycle either (#1198 review): a frame at or
   * below it belongs to a counted block, whose drop the load above has seen;
   * a frame past it may sit in one ring while another ring is dropping it
   * right now. Left in the ring, it is read next cycle against a drop record
   * that is then complete, so every stream ends each cycle at the same frame
   * and a stop is always exact. */
  const uint64_t pop_to = elapsed < cap ? elapsed : cap;
  if (ok && !le_pd_drain_ring(d, &d->master_file, &e->perf.master_ring,
                              scratch, LE_PD_SCRATCH_SAMPLES, pop_to)) {
    ok = 0;
  }
  for (int32_t c = 0; ok && c < LE_MAX_MONITORED_INPUTS; ++c) {
    if (!(e->perf.input_mask & (1u << c))) continue;
    if (!le_pd_drain_ring(d, &d->monitor_file[c], &e->perf.monitor_ring[c],
                          scratch, LE_PD_SCRATCH_SAMPLES, pop_to)) {
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

  /* Silence fills only up to the cap: a dropped frame ends the take, it is
   * never padded over (#1198). */
  const uint64_t fill_to = elapsed < cap ? elapsed : cap;
  if (ok) {
    if (!le_pd_catch_up(d, &d->master_file, fill_to)) {
      ok = 0;
    }
    for (int32_t c = 0; ok && c < LE_MAX_MONITORED_INPUTS; ++c) {
      if (!(e->perf.input_mask & (1u << c))) continue;
      if (!le_pd_catch_up(d, &d->monitor_file[c], fill_to)) ok = 0;
    }
  }

  /* The take stops once every stream holds exactly the cap. A cap past what
   * the rings have shown so far (a drop or a budget end in a block not yet
   * counted) waits for the next cycle. */
  if (ok && d->stop_reason == LE_PERF_STOP_NONE &&
      cap_reason != LE_PERF_STOP_NONE && le_pd_all_streams_reached(d, cap)) {
    d->stop_reason = cap_reason;
    d->stop_frame = cap;
  }

  /* The PCM files stay open for the whole capture session (never closed
   * until disarm), so without an explicit flush here their buffered writes
   * would sit invisible to any other reader (a crash-consistency check, or
   * this very drain cycle's sidecar reporting a capture_frames count nothing
   * has actually reached disk for yet) until fclose. This is THE flush the
   * ~250 ms cadence documented in perf_drain.h refers to. */
  if (ok && (d->master_file.w.file == NULL || !le_pd_flush(d->master_file.w.file))) {
    ok = 0;
  }
  for (int32_t c = 0; ok && c < LE_MAX_MONITORED_INPUTS; ++c) {
    if (!(e->perf.input_mask & (1u << c))) continue;
    if (d->monitor_file[c].w.file == NULL || !le_pd_flush(d->monitor_file[c].w.file)) {
      ok = 0;
    }
  }
  if (ok && !le_pd_flush(d->events_file)) ok = 0;

  /* The take's last pass seals every open part, so the final sidecar lists
   * each one with its sizes, digest and overs — attempted even after a failed
   * write, since a part that holds whole frames is still a part of the take.
   * Its result counts like any other write. */
  if (final) {
    if (d->master_file.w.file != NULL && !le_pd_seal_part(d, &d->master_file)) {
      ok = 0;
    }
    for (int32_t c = 0; c < LE_MAX_MONITORED_INPUTS; ++c) {
      if (d->monitor_file[c].w.file == NULL) continue;
      if (!le_pd_seal_part(d, &d->monitor_file[c])) ok = 0;
    }
  }

  le_pd_publish_overs(d);
  le_pd_publish_progress(d);

  /* Write the sidecar (with the disk_full marker, if this cycle just failed)
   * BEFORE publishing d->self_stopped — le_perf_drain_self_stopped
   * lets a caller observe that flag while the thread is still alive (unlike
   * device_changed, only ever checked after a full join), so the store must
   * happen strictly after the marker it implies is already durably on disk,
   * never before. */
  if (!ok && d->stop_reason == LE_PERF_STOP_NONE) {
    d->stop_reason = LE_PERF_STOP_WRITE_FAILED;
  }
  const int sidecar_ok =
      le_pd_write_sidecar(d, !ok, elapsed < d->stop_frame ? elapsed
                                                           : d->stop_frame);
  if (d->stop_reason != LE_PERF_STOP_NONE) le_pd_publish_stop(d);
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
   * than LE_PERF_RING_SECONDS_DEFAULT of audio piling into master_ring inside one
   * cycle, an overrun, and le_pd_catch_up padding the take with zero-filled
   * silence.
   *
   * The deadline is re-based off ITSELF, not off `now`, so a cycle that ran
   * long does not push the next one out by its own duration — the cadence is
   * of cycle STARTS. What that means when a cycle DOES overrun, stated
   * precisely because it is the load-bearing behaviour under exactly the
   * conditions #710 shows up in:
   *
   *   - Overrun by a FULL interval or more: the re-based deadline is still in
   *     the past, so it resyncs to now + LE_PD_FLUSH_MS. The missed cycles are
   *     dropped rather than made up — running the writer harder to catch up is
   *     the opposite of what a background writer should do on a busy machine.
   *   - Overrun by LESS than one interval: the re-based deadline is already
   *     past, so the next cycle fires at the very next 10 ms poll. While the
   *     overrun persists, cycles run effectively back-to-back at poll
   *     granularity. That is deliberate for #710 — the rings hold only
   *     LE_PERF_RING_SECONDS_DEFAULT, and draining them promptly is what keeps
   *     zero-filled silence out of the take — but it is the wrong direction
   *     for load: combined with the priority drop, the worst case is more
   *     drain CPU exactly when the machine is busiest. The trade is taken
   *     knowingly; data loss is unrecoverable and CPU contention is not.
   *
   * This can only ever make cycles MORE frequent, never less: a real sleep is
   * always at least as long as its request, so the accumulator's 25th tick
   * always landed at or after 250 ms of true elapsed time, and this fires at
   * the first poll wake at or after exactly that. The one case where the
   * accumulator fired sooner is a nanosleep cut short by a signal — it would
   * credit a full 10 ms for a partial sleep — and firing at the true 250 ms
   * instead is the documented contract, comfortably inside the 2 s ring. */
  uint64_t next_flush_ms = 0;
  if (le_pd_now_ms(&next_flush_ms)) next_flush_ms += LE_PD_FLUSH_MS;

  while (atomic_load_explicit(&d->running, memory_order_acquire)) {
    le_pd_sleep_ms(LE_PD_POLL_MS);
    uint64_t now_ms = 0;
    if (le_pd_now_ms(&now_ms)) {
      if (now_ms < next_flush_ms) continue;
      next_flush_ms += LE_PD_FLUSH_MS;
      if (next_flush_ms <= now_ms) next_flush_ms = now_ms + LE_PD_FLUSH_MS;
    }
    /* else: the clock could not be read. FIRE rather than skip (see
     * le_pd_now_ms) — a cycle that runs early costs one extra write on a
     * deprioritized thread, while a cycle that never runs loses the take. The
     * deadline is left untouched, so a clock that comes back resyncs it on the
     * next poll; a persistent failure degrades to one cycle per poll, which is
     * the expensive-but-correct direction, not a stall. */
    if (!le_pd_drain_cycle(d, 0)) {
      if (d->stop_reason == LE_PERF_STOP_NONE) {
        d->stop_reason = LE_PERF_STOP_WRITE_FAILED;
      }
      le_pd_publish_stop(d);
      break;
    }
    /* The reserve or a dropped frame ended the take: every stream already
     * holds its last frame, and the final pass below writes nothing past it. */
    if (d->stop_reason != LE_PERF_STOP_NONE) break;
  }

  /* Final pass regardless of how we got here (a graceful stop request, or a
   * self-stop above): best-effort drain + one last sidecar flush,
   * so the on-disk state reflects everything captured up to this moment.
   * Its own failure is not actionable — the thread is exiting either way. */
  le_pd_drain_cycle(d, 1);
  /* Whatever ended the take, its last state is made durable now, not at the
   * next interval: a self-stop can be followed by a crash before any
   * disarm. */
  atomic_store_explicit(&d->cp_now, 1, memory_order_release);
}

/* Closes every file `d` opened, without sealing (a start that failed half
 * way: nothing was published, nothing is a take yet). */
static void le_pd_close_all(le_perf_drain* d) {
  if (d->events_file != NULL) fclose(d->events_file);
  le_wav_abandon(&d->master_file.w);
  for (int32_t c = 0; c < LE_MAX_MONITORED_INPUTS; ++c) {
    le_wav_abandon(&d->monitor_file[c].w);
  }
}

le_perf_drain* le_perf_drain_start(le_engine* engine,
                                   const le_perf_target* target,
                                   int32_t ring_seconds) {
  if (engine == NULL || target == NULL || target->capture_dir == NULL ||
      target->capture_dir[0] == '\0') {
    return NULL;
  }
  const char* sidecar_dir =
      target->live_sidecar_dir != NULL && target->live_sidecar_dir[0] != '\0'
          ? target->live_sidecar_dir
          : target->capture_dir;
  /* Reject rather than silently truncate into a wrong path. */
  const char* mirror_dir = target->mirror_dir != NULL ? target->mirror_dir : "";
  if (strlen(target->capture_dir) >= LE_PD_PATH_MAX ||
      strlen(sidecar_dir) >= LE_PD_PATH_MAX ||
      strlen(mirror_dir) >= LE_PD_PATH_MAX || target->checkpoint_ms < 0) {
    return NULL;
  }
  if (mirror_dir[0] != '\0' && !le_pd_mkdir_recursive(mirror_dir)) {
    return NULL;
  }
  if (!le_pd_mkdir_recursive(target->capture_dir)) return NULL;
  if (sidecar_dir != target->capture_dir &&
      !le_pd_mkdir_recursive(sidecar_dir)) {
    return NULL;
  }

  le_perf_drain* d = (le_perf_drain*)calloc(1, sizeof(le_perf_drain));
  if (d == NULL) return NULL;
  d->engine = engine;
  snprintf(d->capture_dir, sizeof(d->capture_dir), "%s", target->capture_dir);
  snprintf(d->sidecar_dir, sizeof(d->sidecar_dir), "%s", sidecar_dir);
  memcpy(d->take_id, target->take_id, sizeof(d->take_id));
  d->volume_generation = target->volume_generation;
  d->part_bytes =
      target->part_bytes != 0 ? target->part_bytes : LE_PERF_PART_BYTES;
  d->ring_seconds = ring_seconds;
  d->stop_reason = LE_PERF_STOP_NONE;
  d->stop_frame = LE_PD_NO_LIMIT;
  d->reserve_bytes = target->reserve_bytes;
  /* Read before the first header is written, so the budget counts every
   * byte the take puts on the volume. */
  le_pd_sample_free(d);

  snprintf(d->mirror_dir, sizeof(d->mirror_dir), "%s", mirror_dir);
  d->checkpoint_ms = target->checkpoint_ms;
  le_pcp_read_boot_id(d->boot_id, sizeof(d->boot_id));
  le_pd_mutex_init(&d->progress_lock);
  le_pd_mutex_init(&d->write_lock);
  d->cp_take.capture_dir = d->capture_dir;
  d->cp_take.mirror_dir = d->mirror_dir;
  d->cp_take.take_id = d->take_id;
  d->cp_take.volume_generation = d->volume_generation;
  d->cp_take.sample_rate = engine->sample_rate;
  d->cp_take.boot_id = d->boot_id;
  d->cp_take.sealed = d->sealed;
  d->cp_take.layer_names = d->layers[0].filename;
  d->cp_take.layer_stride = sizeof(d->layers[0]);
  if (!le_pcp_writer_init(&d->cp_writer)) {
    le_pcp_writer_free(&d->cp_writer);
    le_pd_mutex_destroy(&d->progress_lock);
    le_pd_mutex_destroy(&d->write_lock);
    free(d);
    return NULL;
  }

  d->master_file.stream = 0;
  d->master_file.channels = engine->perf.master_channels;
  int ok = le_pd_open_part(d, &d->master_file);
  for (int32_t c = 0; ok && c < LE_MAX_MONITORED_INPUTS; ++c) {
    if (!(engine->perf.input_mask & (1u << c))) continue;
    d->monitor_file[c].stream = 1 + c;
    d->monitor_file[c].channels = 2;
    ok = le_pd_open_part(d, &d->monitor_file[c]);
  }

  if (ok) {
    char path[LE_PD_FULL_PATH_MAX];
    snprintf(path, sizeof(path), "%s/events.log", d->capture_dir);
    d->events_file = fopen(path, "wb");
    ok = d->events_file != NULL &&
         le_pd_write_events_header(d->events_file, engine->sample_rate);
    if (ok) {
      le_pd_count_bytes(d, 12); /* "PLEV", version, sample rate */
      d->events_bytes = 12;
    }
  }

  if (ok) {
    /* The opened parts and events.log are what the first checkpoint names. */
    le_pd_publish_progress(d);
    ok = le_pd_thread_start(&d->cp_thread, LE_PD_CHECKPOINT_ENTRY, d);
    if (ok) {
      atomic_store_explicit(&d->running, 1, memory_order_release);
      if (!le_pd_thread_start(&d->thread, LE_PD_DRAIN_ENTRY, d)) {
        atomic_store_explicit(&d->cp_stop, 1, memory_order_release);
        le_pd_thread_join(d->cp_thread);
        ok = 0;
      }
    }
  }
  if (!ok) {
    le_pd_close_all(d);
    le_pcp_writer_free(&d->cp_writer);
    le_pd_mutex_destroy(&d->progress_lock);
    le_pd_mutex_destroy(&d->write_lock);
    free(d);
    return NULL;
  }
  return d;
}

void le_perf_drain_stop(le_perf_drain* drain, le_perf_stop_reason reason) {
  if (drain == NULL) return;
  if (!atomic_load_explicit(&drain->self_stopped, memory_order_acquire) &&
      reason == LE_PERF_STOP_DEVICE_CHANGED) {
    atomic_store_explicit(&drain->device_changed, 1, memory_order_release);
  }
  atomic_store_explicit(&drain->running, 0, memory_order_release);
  le_pd_thread_join(drain->thread);
  /* The caller's reason, unless the thread already recorded its own (the
   * final pass included: a frame dropped just before the disarm still ends
   * the take there). */
  int32_t none = LE_PERF_STOP_NONE;
  atomic_compare_exchange_strong_explicit(&drain->engine->a_perf_stop_reason,
                                          &none, (int32_t)reason,
                                          memory_order_relaxed,
                                          memory_order_relaxed);

  /* The last checkpoint, after the final pass sealed the parts: the thread
   * writes it on its way out. */
  atomic_store_explicit(&drain->cp_stop, 1, memory_order_release);
  le_pd_thread_join(drain->cp_thread);

  /* The final pass sealed (and closed) every part it could; whatever is
   * still open here failed to seal and is closed as it stands — its header
   * keeps zero sizes, which recovery reads as a part to be measured. */
  le_pd_close_all(drain);
  le_pcp_writer_free(&drain->cp_writer);
  le_pd_mutex_destroy(&drain->progress_lock);
  le_pd_mutex_destroy(&drain->write_lock);
  free(drain);
}
