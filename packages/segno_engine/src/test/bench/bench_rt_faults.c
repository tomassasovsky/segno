/*
 * bench_rt_faults.c — the on-device proof that the audio thread does not
 * fault or miss a deadline while the player records, overdubs and toggles
 * FX, and the measure of what a fork still costs it (#900, #906, #1367).
 *
 * NOT part of the test gate: it needs the console's real sound card, so it
 * runs on the appliance with segno.service stopped. Build it with
 * ./bench_rt_faults.sh (CI's native-bench-arm64 job uploads the arm64 build).
 *
 * What it does, for --seconds of wall clock:
 *   - opens the device the way the app does (ALSA only, an 8-period ring, the
 *     callback thread on SCHED_FIFO 80), with an 8-track engine and a 60 s
 *     recording cap;
 *   - with --fork-ms N, a forker thread starts /bin/true every N ms with plain
 *     fork(), in the pattern Dart's Process.start uses (the child blocks on a
 *     pipe until the parent has registered it, then execs), so every fork
 *     copies the page tables and write-protects the whole process while the
 *     callback runs. Off by default: the app does not fork (#1373);
 *   - the main thread plays the looper like a person: a fresh take on a track,
 *     its finalize, two overdub passes, a punch-out, FX enabled and disabled
 *     and retyped on its lanes and on the input monitor every --fx-ms, the
 *     snapshot polled every 20 ms like the UI does, and every few takes the
 *     tracks cleared and the cycle started again on the next track;
 *   - the window runs from --warmup to --seconds: at each end it samples the
 *     callback thread's own minflt/majflt from /proc/self/task/<tid>/stat, and
 *     the engine's callback telemetry. Both samples are taken on time, not at
 *     a cycle boundary: one cycle can outlast a short run (#1403).
 *
 * Expected, and the exit status:
 *   - with no forks (the app as shipped): 0 page faults on the callback
 *     thread, 0 late periods (a period service longer than its deadline) and
 *     0 xruns in the window (#1406). Every xrun kind counts. miniaudio's ALSA
 *     data loop reports them (capture overrun, playback underrun, playback
 *     slip resync), and that loop is the callback thread: each one means the
 *     thread did not read or write in time, and the listener hears it. The
 *     playback stop threshold is the ring boundary, so writei never returns
 *     -EPIPE and a playback underrun shows up as a resync, not as an
 *     underrun. None of them belongs to the device start: start-up overruns
 *     land before the 0.5 s settle and the warm-up, and the bench never
 *     reconfigures the device. An xrun with no fault and no late period
 *     still fails: the time was lost outside le_engine_process (in alsa-lib,
 *     the kernel, the scheduler or the driver), which late_periods does not
 *     measure, and the appliance dropped audio all the same;
 *   - with forced forks (the backstop): at most --max-faults-per-fork faults
 *     per fork on the callback thread (default 16). Not zero, by
 *     construction: the callback's own stack cannot be fork-shielded, and
 *     buffers inside miniaudio and alsa-lib are plain heap, so each fork costs
 *     a few copy-on-write faults on those pages, and each can wait for the
 *     page-table copy. Late periods and xruns are reported, not judged, here:
 *     no shielding makes a fork free, which is why the app does not fork. The
 *     engine's own buffers contribute nothing (the native fault test proves
 *     that with a shielded stack: test_engine_rt_memory.h);
 *   - either way, the window fails when it holds fewer than half the periods
 *     its length implies (an empty window proves nothing), or when the
 *     callback thread's stat could not be read at either end.
 */
#define _GNU_SOURCE 1

#include <dirent.h>
#include <errno.h>
#include <pthread.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#include "engine_platform.h" /* le_platform_fork_count */
#include "segno_engine_api.h"

typedef struct {
  double seconds;
  double warmup;
  int fork_ms;
  int max_faults_per_fork;
  int fx_ms;
  int32_t rate;
  int32_t period;
  const char* playback;
  const char* capture;
} rt_opts;

static double now_s(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (double)ts.tv_sec + (double)ts.tv_nsec * 1e-9;
}

static void sleep_ms(int ms) {
  struct timespec ts = {ms / 1000, (long)(ms % 1000) * 1000000L};
  nanosleep(&ts, NULL);
}

/* Fields of /proc/self/task/<tid>/stat, counted from 1 as proc(5) does. */
typedef struct {
  long minflt, majflt;
  int policy;
} rt_task_stat;

static int read_task_stat(long tid, rt_task_stat* out) {
  char path[64];
  snprintf(path, sizeof(path), "/proc/self/task/%ld/stat", tid);
  FILE* f = fopen(path, "r");
  if (f == NULL) return 0;
  char buf[1024];
  const size_t n = fread(buf, 1, sizeof(buf) - 1, f);
  fclose(f);
  buf[n] = '\0';
  char* p = strrchr(buf, ')'); /* comm may contain spaces */
  if (p == NULL || p[1] == '\0' || p[2] == '\0') return 0;
  p += 3; /* past ") " and field 3, the state letter */
  long v[64] = {0};
  int i = 4;
  while (*p != '\0' && *p != '\n' && i < 64) {
    char* next = p;
    v[i++] = strtol(p, &next, 10);
    if (next == p) break; /* not a number: stop rather than spin */
    p = next;
    while (*p == ' ') ++p;
  }
  out->minflt = v[10];
  out->majflt = v[12];
  out->policy = (int)v[41];
  return 1;
}

/* The callback thread: the one task of this process on SCHED_FIFO. */
static long find_rt_task(void) {
  DIR* d = opendir("/proc/self/task");
  if (d == NULL) return -1;
  long found = -1;
  struct dirent* de;
  while ((de = readdir(d)) != NULL) {
    const long tid = strtol(de->d_name, NULL, 10);
    rt_task_stat st;
    if (tid > 0 && read_task_stat(tid, &st) && st.policy == 1 /* FIFO */) {
      found = tid;
    }
  }
  closedir(d);
  return found;
}

/* ---- the forker: Dart's Process.start, minus Dart ---- */

static volatile int g_stop = 0;
static long g_forks = 0;

static void* forker_main(void* arg) {
  const int ms = *(const int*)arg;
  while (!g_stop) {
    int fds[2];
    if (pipe(fds) == 0) {
      const pid_t pid = fork();
      if (pid == 0) {
        char byte;
        close(fds[1]);
        (void)read(fds[0], &byte, 1); /* wait until the parent registers us */
        execl("/bin/true", "true", (char*)NULL);
        _exit(127);
      }
      close(fds[0]);
      if (pid > 0) {
        (void)write(fds[1], "x", 1);
        waitpid(pid, NULL, 0);
        ++g_forks;
      }
      close(fds[1]);
    }
    sleep_ms(ms);
  }
  return NULL;
}

/* ---- the player ---- */

static const int32_t k_fx_types[] = {LE_FX_DELAY, LE_FX_REVERB, LE_FX_OCTAVER,
                                     LE_FX_ECHO};
#define K_FX_TYPES ((int)(sizeof(k_fx_types) / sizeof(k_fx_types[0])))

static le_engine* g_e;
static int g_fx_turn = 0;

/* ---- the measurement window ---- */

typedef struct {
  double at;
  int st_ok; /* read_task_stat succeeded */
  rt_task_stat st;
  le_callback_telemetry tel;
  long forks;
} rt_sample;

static long g_tid;
static double g_window_start; /* the end of the warm-up */
static double g_deadline;     /* the end of the run */
static int g_sampled = 0;
static rt_sample g_s0;

static void take_sample(rt_sample* out) {
  out->at = now_s();
  out->st_ok = read_task_stat(g_tid, &out->st);
  le_engine_get_callback_telemetry(g_e, &out->tel);
  out->forks = g_forks;
}

/* Whether the run has time left. Also takes the window's start sample the
 * first time it finds the warm-up over: the player calls this every 20 ms
 * poll, so the sample lands on time however long a cycle runs. */
static int time_left(void) {
  const double t = now_s();
  if (!g_sampled && t >= g_window_start) {
    take_sample(&g_s0);
    g_sampled = 1;
  }
  return t < g_deadline;
}

/* Polls like the UI (the poll files retired layers and posts shadows), and
 * flips an FX every fx_ms, for `ms` of wall clock or until the run ends. */
static void play_for(int ms, int fx_ms, int track) {
  const double end = now_s() + ms / 1000.0;
  double next_fx = now_s() + fx_ms / 1000.0;
  le_snapshot s;
  while (time_left() && now_s() < end) {
    le_engine_get_snapshot(g_e, &s);
    if (fx_ms > 0 && now_s() >= next_fx) {
      next_fx += fx_ms / 1000.0;
      const int turn = g_fx_turn++;
      const int lane = turn & 1;
      switch (turn % 4) {
        case 0: /* retype slot 0 and make sure the chain is on */
          le_engine_set_lane_fx(g_e, track, lane, 0,
                                k_fx_types[(turn / 4) % K_FX_TYPES]);
          le_engine_set_lane_fx_count(g_e, track, lane, 1, 0);
          break;
        case 1:
          le_engine_set_lane_fx_enabled(g_e, track, lane, 0, 0);
          break;
        case 2:
          le_engine_set_lane_fx_enabled(g_e, track, lane, 0, 1);
          break;
        default:
          le_engine_set_monitor_input_fx(g_e, 0, 0,
                                         k_fx_types[(turn / 4 + 1) % K_FX_TYPES]);
          le_engine_set_monitor_input_fx_count(g_e, 0, 1);
          break;
      }
    }
    sleep_ms(20);
  }
}

/* One cycle on [track]: a take, its finalize, two overdub passes, a
 * punch-out, and the drain. With a 2 s loop it takes about 10 s; it stops
 * early when the run ends. */
static void perform_cycle(int track, int fx_ms) {
  le_snapshot s;
  le_engine_record(g_e, track); /* a fresh take (immediate or quantized) */
  play_for(2000, fx_ms, track);
  le_engine_record(g_e, track); /* finalize */
  play_for(1500, fx_ms, track);
  if (!time_left()) return;
  le_engine_get_snapshot(g_e, &s);
  if (s.tracks[track].state != LE_TRACK_PLAYING) return;
  const int loop_ms = s.master_length_frames > 0
                          ? (int)(1000.0 * s.master_length_frames /
                                  (s.sample_rate > 0 ? s.sample_rate : 48000))
                          : 2000;
  le_engine_record(g_e, track); /* punch in */
  play_for(2 * loop_ms + loop_ms / 3, fx_ms, track);
  if (!time_left()) return;
  le_engine_record(g_e, track); /* punch out mid-pass: the drain runs */
  play_for(loop_ms, fx_ms, track);
}

static void usage(void) {
  fprintf(stderr,
          "usage: bench_rt_faults [--seconds N] [--warmup N] [--fork-ms N]\n"
          "         [--max-faults-per-fork N]\n"
          "         [--fx-ms N] [--rate HZ] [--period FRAMES]\n"
          "         [--playback ID] [--capture ID] [--list]\n");
}

static void list_devices(void) {
  le_device_info d[32];
  int32_t n = 0;
  if (le_enumerate_playback_devices(d, 32, &n) == LE_OK) {
    for (int i = 0; i < n; ++i)
      printf("playback %-24s %s%s\n", d[i].id, d[i].name,
             d[i].is_default ? " (default)" : "");
  }
  if (le_enumerate_capture_devices(d, 32, &n) == LE_OK) {
    for (int i = 0; i < n; ++i)
      printf("capture  %-24s %s%s\n", d[i].id, d[i].name,
             d[i].is_default ? " (default)" : "");
  }
}

int main(int argc, char** argv) {
  rt_opts o = {120.0, 5.0, 0, 16, 500, 96000, 64, "", ""};
  for (int i = 1; i < argc; ++i) {
    const char* a = argv[i];
    const char* v = i + 1 < argc ? argv[i + 1] : NULL;
    if (strcmp(a, "--list") == 0) {
      setenv("SEGNO_ALSA_ONLY", "1", 0);
      list_devices();
      return 0;
    } else if (v != NULL && strcmp(a, "--seconds") == 0) {
      o.seconds = atof(v), ++i;
    } else if (v != NULL && strcmp(a, "--warmup") == 0) {
      o.warmup = atof(v), ++i;
    } else if (v != NULL && strcmp(a, "--fork-ms") == 0) {
      o.fork_ms = atoi(v), ++i;
    } else if (v != NULL && strcmp(a, "--max-faults-per-fork") == 0) {
      o.max_faults_per_fork = atoi(v), ++i;
    } else if (v != NULL && strcmp(a, "--fx-ms") == 0) {
      o.fx_ms = atoi(v), ++i;
    } else if (v != NULL && strcmp(a, "--rate") == 0) {
      o.rate = atoi(v), ++i;
    } else if (v != NULL && strcmp(a, "--period") == 0) {
      o.period = atoi(v), ++i;
    } else if (v != NULL && strcmp(a, "--playback") == 0) {
      o.playback = v, ++i;
    } else if (v != NULL && strcmp(a, "--capture") == 0) {
      o.capture = v, ++i;
    } else {
      usage();
      return 2;
    }
  }
  if (o.warmup < 0 || o.warmup >= o.seconds) {
    fprintf(stderr, "--warmup must be at least 0 and less than --seconds\n");
    return 2;
  }
  /* The appliance's audio path: direct ALSA, the callback on SCHED_FIFO 80,
   * and an 8-period ring (segno-kiosk-launch exports the same three). The
   * ring depth decides how long a stall the card absorbs before an xrun, so
   * at the engine's default of 2 the verdict would judge a ring a quarter
   * the size of the app's. */
  setenv("SEGNO_ALSA_ONLY", "1", 0);
  setenv("SEGNO_RT_AUDIO", "1", 0);
  setenv("SEGNO_ALSA_PERIODS", "8", 0);

  g_e = le_engine_create();
  le_config cfg;
  memset(&cfg, 0, sizeof(cfg));
  cfg.sample_rate = o.rate;
  cfg.buffer_frames = o.period;
  cfg.max_loop_frames = o.rate * 60;
  snprintf(cfg.playback_device_id, sizeof(cfg.playback_device_id), "%s",
           o.playback);
  snprintf(cfg.capture_device_id, sizeof(cfg.capture_device_id), "%s",
           o.capture);
  const int32_t rc = le_engine_start(g_e, &cfg);
  if (rc != LE_OK) {
    fprintf(stderr, "le_engine_start failed (%d); is segno.service stopped? "
                    "(--list shows the devices)\n", rc);
    return 2;
  }
  sleep_ms(500);
  g_tid = find_rt_task();
  if (g_tid < 0) {
    fprintf(stderr, "no SCHED_FIFO thread: the callback did not get real-time "
                    "priority (run as root, or with LimitRTPRIO)\n");
    return 2;
  }
  le_snapshot s;
  le_engine_get_snapshot(g_e, &s);
  printf("device: %s, %d Hz, %d-frame period, SEGNO_ALSA_PERIODS %s, "
         "callback thread %ld\n",
         le_engine_device_name(g_e), s.sample_rate, (int)o.period,
         getenv("SEGNO_ALSA_PERIODS"), g_tid);
  le_engine_set_monitor_input(g_e, 0, 1);

  pthread_t forker;
  if (o.fork_ms > 0) pthread_create(&forker, NULL, forker_main, &o.fork_ms);

  const double t_start = now_s();
  g_window_start = t_start + o.warmup;
  g_deadline = t_start + o.seconds;
  int track = 0;
  int takes = 0;
  while (time_left()) {
    perform_cycle(track, o.fx_ms);
    if (++takes % 3 == 0 && time_left()) { /* clear, so takes stay fresh */
      for (int c = 0; c < LE_MAX_TRACKS; ++c) le_engine_clear(g_e, c);
      play_for(500, o.fx_ms, track);
    }
    track = (track + 1) % 4;
  }
  /* time_left() returned 0, so the deadline has passed, and the call that
   * found it took the start sample if nothing had before. */
  rt_sample s1 = {0};
  take_sample(&s1);
  g_stop = 1;
  if (o.fork_ms > 0) pthread_join(forker, NULL);
  le_engine_stop(g_e);

  const rt_task_stat st0 = g_s0.st, st1 = s1.st;
  const le_callback_telemetry t0 = g_s0.tel, t1 = s1.tel;
  const double window_s = s1.at - g_s0.at;
  const long faults = (st1.minflt - st0.minflt) + (st1.majflt - st0.majflt);
  const uint64_t periods = t1.session.periods - t0.session.periods;
  const uint64_t late = t1.session.late_periods - t0.session.late_periods;
  uint64_t dx[LE_XRUN_KINDS];
  uint64_t xruns = 0;
  for (int k = 0; k < LE_XRUN_KINDS; ++k) {
    dx[k] = t1.session.xruns[k] - t0.session.xruns[k];
    xruns += dx[k];
  }
  printf("window: %.1f s measured after a %.1f s warm-up, %d-frame period "
         "(%u us)\n",
         window_s, g_s0.at - t_start, (int)o.period, t1.budget_us);
  printf("t0: calls %llu, periods %llu\nt1: calls %llu, periods %llu\n",
         (unsigned long long)t0.session.calls,
         (unsigned long long)t0.session.periods,
         (unsigned long long)t1.session.calls,
         (unsigned long long)t1.session.periods);
  const long forks = s1.forks - g_s0.forks;
  printf("forks in the window: %ld (engine counted %u in all)\n", forks,
         le_platform_fork_count());
  printf("callback thread faults: %ld minor, %ld major\n",
         st1.minflt - st0.minflt, st1.majflt - st0.majflt);
  const double expected =
      t1.budget_us > 0 ? window_s * 1e6 / t1.budget_us : 0.0;
  printf("periods: %llu (about %.0f expected), late: %llu, worst service "
         "since start %u us\n",
         (unsigned long long)periods, expected,
         (unsigned long long)late, t1.session.max_us);
  printf("xruns: %llu (capture overrun %llu, playback underrun %llu, "
         "playback resync %llu, backend overload %llu)\n",
         (unsigned long long)xruns,
         (unsigned long long)dx[LE_XRUN_CAPTURE_OVERRUN],
         (unsigned long long)dx[LE_XRUN_PLAYBACK_UNDERRUN],
         (unsigned long long)dx[LE_XRUN_PLAYBACK_RESYNC],
         (unsigned long long)dx[LE_XRUN_BACKEND_OVERLOAD]);
  int ok;
  if (!g_s0.st_ok || !s1.st_ok) {
    ok = 0;
    printf("FAIL: the callback thread's stat could not be read\n");
  } else if (periods == 0 || (double)periods < expected / 2) {
    ok = 0;
    printf("FAIL: the window holds too few periods to prove anything\n");
  } else if (forks == 0) {
    ok = faults == 0 && late == 0 && xruns == 0;
    if (ok) {
      printf("PASS: no fault, no late period and no xrun on the callback\n");
    } else if (faults != 0 || late != 0) {
      printf("FAIL: the callback faulted or ran late%s\n",
             xruns != 0 ? ", and the device dropped out" : "");
    } else {
      printf("FAIL: the device dropped out with no fault and no late period: "
             "the time was lost outside le_engine_process\n");
    }
  } else {
    const double per_fork = (double)faults / (double)forks;
    ok = per_fork <= (double)o.max_faults_per_fork;
    printf("faults per fork: %.2f (bound %d)\n%s\n", per_fork,
           o.max_faults_per_fork,
           ok ? "PASS: forks cost the callback only its stack and library pages"
              : "FAIL: more faults per fork than the stack and libraries explain");
  }
  le_engine_destroy(g_e);
  return ok ? 0 : 1;
}
