/*
 * engine_watch_forks.c — counts and logs every fork() of the process (#1367).
 *
 * A fork copies the app's page tables and write-protects its private pages,
 * and the real-time audio thread stalls for milliseconds behind it. The app
 * starts its helpers with posix_spawn, which runs no atfork handler, so a
 * line from here names a fork from a dependency (Dart's Process.start, a
 * plugin, a library).
 *
 * glibc runs pthread_atfork prepare handlers in the forking thread, before the
 * page-table copy, for every fork() and for none of posix_spawn, vfork or
 * system(). The handler is installed by a constructor when the library loads,
 * before any engine exists, so a fork at startup is counted too. The line is
 * built on the stack and written with one write(2), so a fork from any thread
 * costs only this and never takes a lock.
 *
 * Its own translation unit, Linux only, listed after the other platform TUs
 * in CMakeLists.txt and named to sort after them in the scripts that glob
 * src/platform/engine_*.c: the watch must not move the code of the other
 * TUs. With these lines in engine_linux.c, the arm64 bench's 64-lane mixer
 * figure read about one point of the period higher.
 */
#if defined(__linux__)

#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <time.h>
#include <unistd.h>

#include "engine_platform.h" /* le_platform_fork_count */

static _Atomic uint64_t g_le_forks;

static void le_fork_prepare(void) {
  const uint64_t n =
      atomic_fetch_add_explicit(&g_le_forks, 1, memory_order_relaxed) + 1;
  struct timespec now = {0, 0};
  (void)clock_gettime(CLOCK_MONOTONIC, &now);
  char line[192];
  int len = snprintf(line, sizeof(line),
                     "segno/fork n=%llu monotonic=%lld.%03lds: the app process "
                     "forked, which stalls the audio thread (#1367)\n",
                     (unsigned long long)n, (long long)now.tv_sec,
                     (long)(now.tv_nsec / 1000000));
  if (len <= 0) return;
  if (len >= (int)sizeof(line)) len = (int)sizeof(line) - 1;
  const ssize_t written = write(STDERR_FILENO, line, (size_t)len);
  (void)written; /* nothing to do about a failed diagnostic line */
}

__attribute__((constructor)) static void le_fork_watch_install(void) {
  (void)pthread_atfork(le_fork_prepare, NULL, NULL);
}

uint64_t le_platform_fork_count(void) {
  return atomic_load_explicit(&g_le_forks, memory_order_relaxed);
}

#else
typedef int segno_engine_watch_forks_tu_unused; /* keep the TU non-empty */
#endif
