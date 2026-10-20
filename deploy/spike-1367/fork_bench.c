// fork_bench: what starting a child process costs a SCHED_FIFO thread in a
// large process (#1367).
//
// The process maps and writes a working set the size of the app's, runs a few
// ordinary threads that keep writing into it (the Flutter engines' stand-in),
// and runs one SCHED_FIFO thread that wakes every 667 us (96 kHz / 64 frames)
// and writes one word into every page of its own buffers. That thread records,
// per cycle, how late it finished against its deadline and how many minor page
// faults it took since the end of the previous cycle (getrusage(RUSAGE_THREAD),
// so a fault on the wake-up path counts too). A control thread starts
// /bin/true on a fixed interval with the mechanism under test:
//
//   none           no launches (baseline)
//   fork           fork() + exec, with the pipe handshake Dart's
//                  ProcessStarter uses (child blocks on a pipe until the
//                  parent writes one byte, then execs)
//   vfork          vfork() + exec
//   spawn          posix_spawn() (glibc: clone(CLONE_VM|CLONE_VFORK))
//   fork-dontfork  fork, with the RT buffers and the sample log marked
//                  MADV_DONTFORK (the shielding #914 applies). The thread's
//                  stack is not shielded: see the brainstorm doc for why it
//                  cannot be.
//
// Build (static, aarch64), from this directory:
//   docker run --rm --platform linux/arm64 -v "$PWD":/w -w /w gcc:14 gcc -O2 -static -pthread -o fork_bench fork_bench.c
// Run (root, for SCHED_FIFO):
//   ./fork_bench <mode> [seconds=20] [ws_mb=512] [rt_mb=4] [interval_ms=200]
//                [mlock=1] [rt_cpu=2] [prio=70]
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <sched.h>
#include <signal.h>
#include <spawn.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/resource.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

extern char **environ;

#define PERIOD_NS 666667L
#define APP_THREADS 2

enum mode { M_NONE, M_FORK, M_VFORK, M_SPAWN, M_FORK_DF };
static const char *mode_names[] = {"none", "fork", "vfork", "spawn",
                                   "fork-dontfork"};

struct sample {
  int32_t done_ns;  // finish time minus the cycle's scheduled start
  int32_t wake_ns;  // wake-up time minus the scheduled start
  int32_t faults;   // minor faults the RT thread took this cycle
  int32_t launching;
};

static enum mode g_mode;
static size_t g_page;
static uint8_t *g_ws;
static size_t g_ws_bytes;
static uint8_t *g_rt;
static size_t g_rt_bytes;
static struct sample *g_samples;
static size_t g_samples_bytes;
static long g_cycles;
static int g_interval_ms;
static int g_rt_cpu;
static int g_prio;
static atomic_int g_launching;
static atomic_int g_stop;
static long g_launches;
static int64_t *g_launch_call_ns;  // time inside fork()/vfork()/posix_spawn()
static int64_t *g_launch_total_ns; // until the child has been reaped

static int64_t now_ns(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (int64_t)ts.tv_sec * 1000000000L + ts.tv_nsec;
}

static void *map_touched(size_t bytes, int dontfork) {
  void *p = mmap(NULL, bytes, PROT_READ | PROT_WRITE,
                 MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
  if (p == MAP_FAILED) {
    perror("mmap");
    exit(1);
  }
  if (dontfork && madvise(p, bytes, MADV_DONTFORK) != 0) {
    perror("madvise(MADV_DONTFORK)");
    exit(1);
  }
  memset(p, 1, bytes);
  return p;
}

static void pin(int cpu) {
  cpu_set_t set;
  CPU_ZERO(&set);
  CPU_SET(cpu, &set);
  pthread_setaffinity_np(pthread_self(), sizeof(set), &set);
}

// The Flutter engines' stand-in: keep writing words into random pages of the
// working set, so they take their own copy-on-write faults after a fork and
// compete for the same locks the RT thread waits on.
static void *app_thread(void *arg) {
  uint64_t x = 0x9e3779b97f4a7c15ULL ^ (uintptr_t)arg;
  size_t pages = g_ws_bytes / g_page;
  setpriority(PRIO_PROCESS, 0, 10);
  while (!atomic_load(&g_stop)) {
    for (int i = 0; i < 64; i++) {
      x ^= x << 13;
      x ^= x >> 7;
      x ^= x << 17;
      g_ws[(x % pages) * g_page + (x & 0xff)] = (uint8_t)x;
    }
    usleep(200);
  }
  return NULL;
}

static void *rt_thread(void *arg) {
  (void)arg;
  pin(g_rt_cpu);
  struct sched_param sp = {.sched_priority = g_prio};
  if (pthread_setschedparam(pthread_self(), SCHED_FIFO, &sp) != 0) {
    fprintf(stderr, "SCHED_FIFO %d refused (run as root)\n", g_prio);
    exit(1);
  }
  size_t rt_pages = g_rt_bytes / g_page;
  struct timespec next;
  struct rusage ru;
  getrusage(RUSAGE_THREAD, &ru);
  long prev_faults = ru.ru_minflt;
  clock_gettime(CLOCK_MONOTONIC, &next);
  for (long i = 0; i < g_cycles; i++) {
    next.tv_nsec += PERIOD_NS;
    if (next.tv_nsec >= 1000000000L) {
      next.tv_nsec -= 1000000000L;
      next.tv_sec++;
    }
    clock_nanosleep(CLOCK_MONOTONIC, TIMER_ABSTIME, &next, NULL);
    int64_t start = (int64_t)next.tv_sec * 1000000000L + next.tv_nsec;
    int64_t woke = now_ns();
    int launching = atomic_load(&g_launching);
    // One store into every page of the RT buffers: the worst case for
    // copy-on-write, since each page faults once after each fork.
    size_t off = (size_t)(i & 63) * 64;
    for (size_t p = 0; p < rt_pages; p++) g_rt[p * g_page + off] = (uint8_t)i;
    getrusage(RUSAGE_THREAD, &ru);
    int64_t done = now_ns();
    g_samples[i].wake_ns = (int32_t)(woke - start);
    g_samples[i].done_ns = (int32_t)(done - start);
    g_samples[i].faults = (int32_t)(ru.ru_minflt - prev_faults);
    prev_faults = ru.ru_minflt;
    g_samples[i].launching = launching | atomic_load(&g_launching);
  }
  atomic_store(&g_stop, 1);
  return NULL;
}

static void launch_once(long n) {
  char *argv[] = {"/bin/true", NULL};
  pid_t pid = -1;
  int status;
  atomic_store(&g_launching, 1);
  int64_t t0 = now_ns(), t1;
  switch (g_mode) {
    case M_FORK:
    case M_FORK_DF: {
      int go[2];
      if (pipe2(go, O_CLOEXEC) != 0) {
        perror("pipe2");
        exit(1);
      }
      pid = fork();
      if (pid == 0) {
        char c;
        if (read(go[0], &c, 1) != 1) _exit(126);
        execv(argv[0], argv);
        _exit(127);
      }
      t1 = now_ns();
      if (write(go[1], "1", 1) != 1) perror("write");
      close(go[0]);
      close(go[1]);
      break;
    }
    case M_VFORK:
      pid = vfork();
      if (pid == 0) {
        execv(argv[0], argv);
        _exit(127);
      }
      t1 = now_ns();
      break;
    case M_SPAWN:
      if (posix_spawn(&pid, argv[0], NULL, NULL, argv, environ) != 0)
        pid = -1;
      t1 = now_ns();
      break;
    default:
      return;
  }
  if (pid < 0) {
    perror("launch");
    exit(1);
  }
  waitpid(pid, &status, 0);
  int64_t t2 = now_ns();
  atomic_store(&g_launching, 0);
  g_launch_call_ns[n] = t1 - t0;
  g_launch_total_ns[n] = t2 - t0;
}

static int cmp_i32(const void *a, const void *b) {
  int32_t x = *(const int32_t *)a, y = *(const int32_t *)b;
  return (x > y) - (x < y);
}
static int cmp_i64(const void *a, const void *b) {
  int64_t x = *(const int64_t *)a, y = *(const int64_t *)b;
  return (x > y) - (x < y);
}

int main(int argc, char **argv) {
  if (argc < 2) {
    fprintf(stderr,
            "usage: %s none|fork|vfork|spawn|fork-dontfork "
            "[seconds] [ws_mb] [rt_mb] [interval_ms] "
            "[mlock] [rt_cpu] [prio]\n",
            argv[0]);
    return 2;
  }
  g_mode = (enum mode)-1;
  for (int m = 0; m <= M_FORK_DF; m++)
    if (strcmp(argv[1], mode_names[m]) == 0) g_mode = (enum mode)m;
  if ((int)g_mode < 0) {
    fprintf(stderr, "unknown mode %s\n", argv[1]);
    return 2;
  }
  int seconds = argc > 2 ? atoi(argv[2]) : 20;
  int ws_mb = argc > 3 ? atoi(argv[3]) : 512;
  int rt_mb = argc > 4 ? atoi(argv[4]) : 4;
  g_interval_ms = argc > 5 ? atoi(argv[5]) : 200;
  int do_mlock = argc > 6 ? atoi(argv[6]) : 1;
  g_rt_cpu = argc > 7 ? atoi(argv[7]) : 2;
  g_prio = argc > 8 ? atoi(argv[8]) : 70;
  if (seconds < 1 || seconds > 120 || g_prio < 1 || g_prio > 75) {
    fprintf(stderr, "seconds must be 1..120 and prio 1..75\n");
    return 2;
  }

  g_page = (size_t)sysconf(_SC_PAGESIZE);
  int dontfork = g_mode == M_FORK_DF;
  if (do_mlock && mlockall(MCL_CURRENT | MCL_FUTURE) != 0) perror("mlockall");

  g_ws_bytes = (size_t)ws_mb << 20;
  g_rt_bytes = (size_t)rt_mb << 20;
  g_cycles = (long)seconds * 1000000000L / PERIOD_NS;
  g_samples_bytes = ((g_cycles * sizeof(struct sample)) + g_page - 1) &
                    ~(g_page - 1);
  g_ws = map_touched(g_ws_bytes, 0);
  g_rt = map_touched(g_rt_bytes, dontfork);
  g_samples = map_touched(g_samples_bytes, dontfork);
  long max_launches = (long)seconds * 1000 / (g_interval_ms ? g_interval_ms : 1) + 2;
  g_launch_call_ns = calloc(max_launches, sizeof(int64_t));
  g_launch_total_ns = calloc(max_launches, sizeof(int64_t));

  pthread_t apps[APP_THREADS], rt;
  for (int i = 0; i < APP_THREADS; i++)
    pthread_create(&apps[i], NULL, app_thread, (void *)(uintptr_t)(i + 1));

  pthread_create(&rt, NULL, rt_thread, NULL);

  // The control thread is this one, on another CPU, at normal priority.
  pin(g_rt_cpu == 0 ? 1 : 0);
  usleep(500000);  // let the RT thread settle before the first launch
  while (!atomic_load(&g_stop)) {
    if (g_mode != M_NONE && g_launches < max_launches) {
      launch_once(g_launches);
      g_launches++;
    }
    usleep((useconds_t)g_interval_ms * 1000);
  }
  pthread_join(rt, NULL);
  for (int i = 0; i < APP_THREADS; i++) pthread_join(apps[i], NULL);

  // Skip the first 0.5 s (start-up, before any launch).
  long skip = 500000000L / PERIOD_NS;
  long n = g_cycles - skip;
  int32_t *done = malloc(n * sizeof(int32_t));
  long misses = 0, fault_cycles = 0, faults = 0, max_faults = 0;
  long launch_cycles = 0, launch_faults = 0;
  int32_t max_wake = 0;
  for (long i = 0; i < n; i++) {
    struct sample *s = &g_samples[i + skip];
    done[i] = s->done_ns;
    if (s->done_ns > PERIOD_NS) misses++;
    if (s->wake_ns > max_wake) max_wake = s->wake_ns;
    if (s->faults > 0) fault_cycles++;
    faults += s->faults;
    if (s->faults > max_faults) max_faults = s->faults;
    if (s->launching) {
      launch_cycles++;
      launch_faults += s->faults;
    }
  }
  qsort(done, n, sizeof(int32_t), cmp_i32);
  qsort(g_launch_call_ns, g_launches, sizeof(int64_t), cmp_i64);
  qsort(g_launch_total_ns, g_launches, sizeof(int64_t), cmp_i64);
  int64_t call_p50 = g_launches ? g_launch_call_ns[g_launches / 2] : 0;
  int64_t call_max = g_launches ? g_launch_call_ns[g_launches - 1] : 0;
  int64_t total_p50 = g_launches ? g_launch_total_ns[g_launches / 2] : 0;

  printf(
      "mode=%s ws_mb=%d rt_mb=%d page=%zu mlock=%d prio=%d cycles=%ld "
      "launches=%ld\n",
      mode_names[g_mode], ws_mb, rt_mb, g_page, do_mlock, g_prio, n,
      g_launches);
  printf(
      "  done_us p50=%.1f p99=%.1f p99.9=%.1f max=%.1f  max_wake_us=%.1f  "
      "missed(>667us)=%ld\n",
      done[n / 2] / 1e3, done[(long)(n * 0.99)] / 1e3,
      done[(long)(n * 0.999)] / 1e3, done[n - 1] / 1e3, max_wake / 1e3,
      misses);
  printf(
      "  rt_faults total=%ld cycles_with_faults=%ld max_per_cycle=%ld "
      "(during launches: %ld faults over %ld cycles)\n",
      faults, fault_cycles, max_faults, launch_faults, launch_cycles);
  printf("  launch_call_us p50=%.1f max=%.1f  launch_to_reap_us p50=%.1f\n",
         call_p50 / 1e3, call_max / 1e3, total_p50 / 1e3);
  return 0;
}
