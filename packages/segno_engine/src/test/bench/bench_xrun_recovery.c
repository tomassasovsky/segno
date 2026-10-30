/*
 * bench_xrun_recovery.c — the on-device proof that one missed deadline costs
 * one glitch and not the session (#1516).
 *
 * NOT part of the test gate: it needs the console's real sound card, so it
 * runs on the appliance with segno.service stopped. Build it with
 * ./bench_xrun_recovery.sh.
 *
 * What it does:
 *   - opens the device the way the app does (ALSA only, an 8-period ring, the
 *     callback thread on SCHED_FIFO 80) with the input monitored, so every
 *     period is captured, processed and played;
 *   - pins the callback thread to one CPU (--cpu) and, for each stall in
 *     --stalls (ms), starts a SCHED_FIFO thread on that CPU above the
 *     callback (--hog-prio, below the sound card's IRQ thread). By default
 *     it overloads the callback the way a too-heavy effects chain does: for
 *     10 s it spins --duty (0.95) of every period and sleeps the rest, so the
 *     callback gets less time than a period needs, period after period, and
 *     the device underruns and overruns hundreds of times. --duty 1 spins
 *     solidly instead, one missed deadline as long as the stall;
 *   - after each stall it waits --settle-ms, then counts the frames the
 *     callback processes over --window-ms and reads the streams' states from
 *     /proc/asound.
 *
 * Why the sustained overload is the default: it is what wedged the console
 * (#1516), and a single solid stall did not (8 of 8 recovered, 1 to 250 ms,
 * on the code before the fix). Under it, about half of the 10 s runs at 48
 * kHz / 32 ended with playback PREPARED, capture RUNNING with hw_ptr 0, and
 * the callback thread asleep in ppoll for good; --repeats 8 makes a run
 * that never wedges on the old code unlikely (about 1 in 250).
 *
 * A stall passes when, after the settle, the callback processes at least
 * half the frames the window implies and playback is RUNNING, and, for a
 * solid stall more than twice the ring long (so the device must have dropped
 * out), it was counted as an xrun of some kind. A stall that wedges the
 * duplex loop prints both streams' /proc status twice, 200 ms apart, and the
 * callback thread's wait channel and stack, then reopens the device for the
 * next stall. Exit status 0 when every stall passes.
 */
#define _GNU_SOURCE 1

#include <dirent.h>
#include <errno.h>
#include <pthread.h>
#include <sched.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include "segno_engine_api.h"

typedef struct {
  int32_t rate;
  int32_t period;
  int cpu;
  int hog_prio;
  int settle_ms;
  int window_ms;
  int repeats;
  int stalls[32];
  int stall_count;
  const char* playback;
  const char* capture;
  double duty;  /* share of each slice the hog spins, 1 = one solid stall */
  int slice_us; /* the hog's on/off cycle when duty < 1 */
} xr_opts;

static le_engine* g_e;
static long g_tid = -1;
static int g_card = -1;

static double now_s(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (double)ts.tv_sec + (double)ts.tv_nsec / 1e9;
}

static void sleep_ms(int ms) {
  struct timespec ts = {ms / 1000, (long)(ms % 1000) * 1000000L};
  nanosleep(&ts, NULL);
}

/* The callback thread: the one task of this process on SCHED_FIFO. */
static long find_rt_task(void) {
  DIR* d = opendir("/proc/self/task");
  if (d == NULL) return -1;
  long found = -1;
  struct dirent* de;
  while ((de = readdir(d)) != NULL) {
    const long tid = strtol(de->d_name, NULL, 10);
    if (tid <= 0) continue;
    struct sched_param sp;
    if (sched_getscheduler((pid_t)tid) == SCHED_FIFO &&
        sched_getparam((pid_t)tid, &sp) == 0) {
      found = tid;
    }
  }
  closedir(d);
  return found;
}

/* The card this process holds: the playback substream whose owner_pid is us. */
static int find_card(void) {
  for (int c = 0; c < 16; ++c) {
    char path[96];
    snprintf(path, sizeof(path), "/proc/asound/card%d/pcm0p/sub0/status", c);
    FILE* f = fopen(path, "r");
    if (f == NULL) continue;
    char line[160];
    long owner = -1;
    while (fgets(line, sizeof(line), f) != NULL) {
      if (sscanf(line, "owner_pid : %ld", &owner) == 1) break;
    }
    fclose(f);
    if (owner == (long)getpid()) return c;
  }
  return -1;
}

static void read_file(const char* path, char* out, size_t cap) {
  out[0] = '\0';
  FILE* f = fopen(path, "r");
  if (f == NULL) return;
  const size_t n = fread(out, 1, cap - 1, f);
  out[n] = '\0';
  fclose(f);
}

/* "RUNNING", "PREPARED", "XRUN", ... for 'p'layback or 'c'apture. */
static void stream_state(char dir, char* out, size_t cap) {
  char path[96], buf[1024];
  snprintf(path, sizeof(path), "/proc/asound/card%d/pcm0%c/sub0/status",
           g_card, dir);
  read_file(path, buf, sizeof(buf));
  snprintf(out, cap, "?");
  const char* s = strstr(buf, "state: ");
  if (s != NULL) sscanf(s + 7, "%31s", out);
}

static void dump_streams(void) {
  char path[96], buf[1024];
  for (int pass = 0; pass < 2; ++pass) {
    for (int k = 0; k < 2; ++k) {
      const char dir = k == 0 ? 'p' : 'c';
      snprintf(path, sizeof(path), "/proc/asound/card%d/pcm0%c/sub0/status",
               g_card, dir);
      read_file(path, buf, sizeof(buf));
      printf("  --- %s (pass %d)\n%s", dir == 'p' ? "playback" : "capture",
             pass, buf);
    }
    if (pass == 0) sleep_ms(200);
  }
  snprintf(path, sizeof(path), "/proc/self/task/%ld/wchan", g_tid);
  read_file(path, buf, sizeof(buf));
  printf("  --- callback thread wchan: %s\n", buf);
  snprintf(path, sizeof(path), "/proc/self/task/%ld/stack", g_tid);
  read_file(path, buf, sizeof(buf));
  if (buf[0] != '\0') printf("  --- callback thread stack:\n%s", buf);
}

static int pin_to_cpu(pid_t tid, int cpu) {
  cpu_set_t set;
  CPU_ZERO(&set);
  CPU_SET(cpu, &set);
  return sched_setaffinity(tid, sizeof(set), &set);
}

static int open_device(const xr_opts* o) {
  le_config cfg;
  memset(&cfg, 0, sizeof(cfg));
  cfg.sample_rate = o->rate;
  cfg.buffer_frames = o->period;
  cfg.max_loop_frames = o->rate * 10;
  snprintf(cfg.playback_device_id, sizeof(cfg.playback_device_id), "%s",
           o->playback);
  snprintf(cfg.capture_device_id, sizeof(cfg.capture_device_id), "%s",
           o->capture);
  const int32_t rc = le_engine_start(g_e, &cfg);
  if (rc != LE_OK) {
    fprintf(stderr, "le_engine_start failed (%d); is segno.service "
                    "stopped?\n", rc);
    return 0;
  }
  sleep_ms(500);
  g_tid = find_rt_task();
  if (g_tid < 0) {
    fprintf(stderr, "no SCHED_FIFO thread: the callback did not get "
                    "real-time priority (run as root)\n");
    return 0;
  }
  if (pin_to_cpu((pid_t)g_tid, o->cpu) != 0) {
    fprintf(stderr, "could not pin the callback thread to cpu %d: %s\n",
            o->cpu, strerror(errno));
    return 0;
  }
  g_card = find_card();
  if (g_card < 0) {
    fprintf(stderr, "no /proc/asound playback stream owned by this process\n");
    return 0;
  }
  le_engine_set_monitor_input(g_e, 0, 1);
  sleep_ms(1000); /* past start-up overruns */
  return 1;
}

/* ---- the hog: the overload, as seen from the callback thread ---- */

typedef struct {
  int cpu;
  int ms;
  double duty;
  int slice_us;
} hog_arg;

/* Spins for the whole stall, or with duty < 1 for that share of every slice
 * and sleeps the rest: a sustained overload that leaves the callback thread
 * less than it needs for the whole stall, rather than nothing for part of
 * it. */
static void* hog_main(void* p) {
  const hog_arg* a = (const hog_arg*)p;
  pin_to_cpu(0, a->cpu);
  const double end = now_s() + a->ms / 1000.0;
  volatile unsigned long spin = 0;
  if (a->duty >= 1.0) {
    while (now_s() < end) ++spin;
    return NULL;
  }
  const double on_s = a->slice_us * a->duty / 1e6;
  const double slice_s = a->slice_us / 1e6;
  double slice_start = now_s();
  while (slice_start < end) {
    while (now_s() < slice_start + on_s) ++spin;
    const double next = slice_start + slice_s;
    const double rest = next - now_s();
    if (rest > 0) {
      struct timespec ts = {0, (long)(rest * 1e9)};
      nanosleep(&ts, NULL);
    }
    slice_start = next;
  }
  return NULL;
}

static int stall(const xr_opts* o, int ms) {
  pthread_attr_t attr;
  pthread_attr_init(&attr);
  pthread_attr_setinheritsched(&attr, PTHREAD_EXPLICIT_SCHED);
  pthread_attr_setschedpolicy(&attr, SCHED_FIFO);
  struct sched_param sp;
  memset(&sp, 0, sizeof(sp));
  sp.sched_priority = o->hog_prio;
  pthread_attr_setschedparam(&attr, &sp);
  cpu_set_t set;
  CPU_ZERO(&set);
  CPU_SET(o->cpu, &set);
  pthread_attr_setaffinity_np(&attr, sizeof(set), &set);
  hog_arg a = {o->cpu, ms, o->duty, o->slice_us};
  pthread_t t;
  const int rc = pthread_create(&t, &attr, hog_main, &a);
  pthread_attr_destroy(&attr);
  if (rc != 0) {
    fprintf(stderr, "could not start the SCHED_FIFO hog: %s\n", strerror(rc));
    return 0;
  }
  pthread_join(t, NULL);
  return 1;
}

static uint64_t frames_now(void) {
  le_snapshot s;
  le_engine_get_snapshot(g_e, &s);
  return s.frames_processed;
}

static void xruns_now(uint64_t out[LE_XRUN_KINDS]) {
  le_callback_telemetry t;
  le_engine_get_callback_telemetry(g_e, &t);
  for (int k = 0; k < LE_XRUN_KINDS; ++k) out[k] = t.session.xruns[k];
}

static int parse_stalls(const char* v, xr_opts* o) {
  o->stall_count = 0;
  const char* q = v;
  for (;;) {
    char* e;
    const long ms = strtol(q, &e, 10);
    if (e == q || ms < 0 || ms > 600000 || o->stall_count == 32 ||
        (*e != ',' && *e != '\0')) {
      return 0;
    }
    o->stalls[o->stall_count++] = (int)ms;
    if (*e == '\0') return 1;
    q = e + 1;
  }
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

static void usage(void) {
  fprintf(stderr,
          "usage: bench_xrun_recovery [--rate HZ] [--period FRAMES]\n"
          "         [--stalls MS,MS,...] [--repeats N] [--cpu N]\n"
          "         [--hog-prio N] [--settle-ms N] [--window-ms N]\n"
          "         [--duty F] [--slice-us N]\n"
          "         [--playback ID] [--capture ID] [--list]\n");
}

int main(int argc, char** argv) {
  xr_opts o = {48000, 32, 3, 85, 1500, 1000, 8, {0}, 0, "", "", 0.95, 0};
  parse_stalls("10000", &o);
  for (int i = 1; i < argc; ++i) {
    const char* a = argv[i];
    const char* v = i + 1 < argc ? argv[i + 1] : NULL;
    if (strcmp(a, "--list") == 0) {
      setenv("SEGNO_ALSA_ONLY", "1", 0);
      list_devices();
      return 0;
    } else if (v != NULL && strcmp(a, "--playback") == 0) {
      o.playback = v, ++i;
    } else if (v != NULL && strcmp(a, "--capture") == 0) {
      o.capture = v, ++i;
    } else if (v != NULL && strcmp(a, "--duty") == 0) {
      o.duty = atof(v), ++i;
    } else if (v != NULL && strcmp(a, "--slice-us") == 0) {
      o.slice_us = atoi(v), ++i;
    } else if (v != NULL && strcmp(a, "--rate") == 0) {
      o.rate = atoi(v), ++i;
    } else if (v != NULL && strcmp(a, "--period") == 0) {
      o.period = atoi(v), ++i;
    } else if (v != NULL && strcmp(a, "--stalls") == 0) {
      if (!parse_stalls(v, &o)) {
        fprintf(stderr, "--stalls takes 1 to 32 comma-separated ms values\n");
        return 2;
      }
      ++i;
    } else if (v != NULL && strcmp(a, "--repeats") == 0) {
      o.repeats = atoi(v), ++i;
    } else if (v != NULL && strcmp(a, "--cpu") == 0) {
      o.cpu = atoi(v), ++i;
    } else if (v != NULL && strcmp(a, "--hog-prio") == 0) {
      o.hog_prio = atoi(v), ++i;
    } else if (v != NULL && strcmp(a, "--settle-ms") == 0) {
      o.settle_ms = atoi(v), ++i;
    } else if (v != NULL && strcmp(a, "--window-ms") == 0) {
      o.window_ms = atoi(v), ++i;
    } else {
      usage();
      return 2;
    }
  }
  if (o.slice_us <= 0) o.slice_us = (int)(1e6 * o.period / o.rate);
  if (o.repeats < 1 || o.window_ms < 100 || o.settle_ms < 0 ||
      o.duty <= 0.0 || o.duty > 1.0) {
    usage();
    return 2;
  }
  /* The appliance's audio path (segno-kiosk-launch exports the same three). */
  setenv("SEGNO_ALSA_ONLY", "1", 0);
  setenv("SEGNO_RT_AUDIO", "1", 0);
  setenv("SEGNO_ALSA_PERIODS", "8", 0);

  g_e = le_engine_create();
  if (!open_device(&o)) return 2;
  {
    char path[96], buf[4096];
    snprintf(path, sizeof(path), "/proc/asound/card%d/stream0", g_card);
    read_file(path, buf, sizeof(buf));
    printf("device: %s, card %d, %d Hz, %d-frame period, "
           "SEGNO_ALSA_PERIODS %s, callback thread %ld on cpu %d, hog "
           "SCHED_FIFO %d, duty %.2f of %d us\n%s\n",
           le_engine_device_name(g_e), g_card, (int)o.rate, (int)o.period,
           getenv("SEGNO_ALSA_PERIODS"), g_tid, o.cpu, o.hog_prio, o.duty,
           o.slice_us, buf);
  }

  int failures = 0, runs = 0;
  for (int r = 0; r < o.repeats; ++r) {
    for (int i = 0; i < o.stall_count; ++i) {
      const int ms = o.stalls[i];
      uint64_t x0[LE_XRUN_KINDS], x1[LE_XRUN_KINDS];
      xruns_now(x0);
      if (!stall(&o, ms)) return 2;
      sleep_ms(o.settle_ms);
      const uint64_t f0 = frames_now();
      const double t0 = now_s();
      sleep_ms(o.window_ms);
      const uint64_t f1 = frames_now();
      const double t1 = now_s();
      xruns_now(x1);
      char pb[32], cap[32];
      stream_state('p', pb, sizeof(pb));
      stream_state('c', cap, sizeof(cap));
      const double expected = (t1 - t0) * o.rate;
      const double ratio = expected > 0 ? (double)(f1 - f0) / expected : 0;
      uint64_t counted = 0;
      for (int k = 0; k < LE_XRUN_KINDS; ++k) counted += x1[k] - x0[k];
      const int flowing = ratio >= 0.5 && strcmp(pb, "RUNNING") == 0;
      /* A stall shorter than the ring can pass without a dropout; one twice
       * as long as the ring cannot, and must be counted. */
      const double ring_ms =
          1000.0 * o.period * atoi(getenv("SEGNO_ALSA_PERIODS")) / o.rate;
      const int must_count = o.duty >= 1.0 && ms > 2.0 * ring_ms;
      const int ok = flowing && (!must_count || counted > 0);
      ++runs;
      printf("stall %4d ms: %s  frames %.2f of expected, playback %s, "
             "capture %s, xruns +%llu (underrun %llu, overrun %llu, "
             "resync %llu)\n",
             ms, ok ? "ok    " : (flowing ? "UNCOUNTED" : "WEDGED"), ratio, pb, cap,
             (unsigned long long)counted,
             (unsigned long long)(x1[0] - x0[0]),
             (unsigned long long)(x1[1] - x0[1]),
             (unsigned long long)(x1[2] - x0[2]));
      fflush(stdout);
      if (!ok) ++failures;
      if (!flowing) {
        dump_streams();
        le_engine_stop(g_e);
        if (!open_device(&o)) return 2;
      }
    }
  }
  le_engine_stop(g_e);
  le_engine_destroy(g_e);
  printf("%s: %d of %d stalls left the duplex loop running\n",
         failures == 0 ? "PASS" : "FAIL", runs - failures, runs);
  return failures == 0 ? 0 : 1;
}
