/* See freeze_watchdog.h. */
#define _GNU_SOURCE
#include "freeze_watchdog.h"

#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <spawn.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

/* What a read probe reads: one block at offset 0. O_DIRECT needs the size,
 * offset and buffer aligned to the logical block size, which is 512 or 4096
 * on every disk this runs on. */
#define FW_BLOCK 4096

/* The probe thread's stack. The default 8 MiB would all be locked and
 * resident under mlockall(MCL_FUTURE); the probes need a few KiB. */
#define FW_PROBE_STACK (256 * 1024)

int64_t fw_now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

void fw_sleep_ms(int64_t ms) {
    if (ms <= 0) return;
    struct timespec ts = {.tv_sec = ms / 1000, .tv_nsec = (ms % 1000) * 1000000};
    while (clock_nanosleep(CLOCK_MONOTONIC, 0, &ts, &ts) == EINTR) {
    }
}

/* --- The decision --------------------------------------------------------- */

void fw_tracker_start(struct fw_tracker *t, int64_t now_ms) {
    t->last_ok_ms = now_ms;
    t->failures = 0;
}

int fw_tracker_record(struct fw_tracker *t, const struct fw_policy *p,
                      int64_t now_ms, int ok) {
    if (ok) {
        t->last_ok_ms = now_ms;
        t->failures = 0;
        return 0;
    }
    t->failures++;
    return t->failures >= p->min_failures &&
           now_ms - t->last_ok_ms >= p->fail_after_ms;
}

/* --- Probes --------------------------------------------------------------- */

int fw_probe_exec(void *ctx, char *why, size_t why_len) {
    const char *path = ctx;
    char *argv[] = {(char *)path, NULL};
    char *envp[] = {NULL};
    pid_t pid;
    /* glibc's posix_spawn is clone(CLONE_VM | CLONE_VFORK): no page tables
     * are copied, and an exec that fails (ENOENT, EIO) is its return value. */
    int rc = posix_spawn(&pid, path, NULL, NULL, argv, envp);
    if (rc != 0) {
        snprintf(why, why_len, "exec %s: %s", path, strerror(rc));
        return -1;
    }
    int status;
    while (waitpid(pid, &status, 0) < 0) {
        if (errno != EINTR) {
            snprintf(why, why_len, "exec %s: waitpid: %s", path, strerror(errno));
            return -1;
        }
    }
    if (WIFEXITED(status) && WEXITSTATUS(status) == 0) return 0;
    if (WIFSIGNALED(status))
        snprintf(why, why_len, "exec %s: killed by signal %d", path, WTERMSIG(status));
    else
        snprintf(why, why_len, "exec %s: exited %d", path, WEXITSTATUS(status));
    return -1;
}

int fw_read_probe_open(struct fw_read_probe *r, const char *path,
                       char *why, size_t why_len) {
    r->path = path;
    r->fd = -1;
    r->direct = 1;
    if (posix_memalign(&r->buf, FW_BLOCK, FW_BLOCK) != 0) {
        snprintf(why, why_len, "read %s: no memory for the buffer", path);
        return -1;
    }
    /* The descriptor stays open: every round reads through it, so a
     * filesystem that has gone (an ext4 shut down after an error, a disk
     * that stopped answering) fails the read rather than an open. */
    r->fd = open(path, O_RDONLY | O_DIRECT | O_CLOEXEC);
    if (r->fd < 0 && errno == EINVAL) {
        /* A filesystem without O_DIRECT: read through the cache, dropping
         * the page first so the read still reaches the disk. */
        r->direct = 0;
        r->fd = open(path, O_RDONLY | O_CLOEXEC);
    }
    if (r->fd < 0) {
        snprintf(why, why_len, "open %s: %s", path, strerror(errno));
        return -1;
    }
    return 0;
}

int fw_probe_read(void *ctx, char *why, size_t why_len) {
    struct fw_read_probe *r = ctx;
    if (!r->direct) posix_fadvise(r->fd, 0, FW_BLOCK, POSIX_FADV_DONTNEED);
    ssize_t n = pread(r->fd, r->buf, FW_BLOCK, 0);
    if (n < 0) {
        snprintf(why, why_len, "read %s: %s", r->path, strerror(errno));
        return -1;
    }
    if (n == 0) {
        snprintf(why, why_len, "read %s: the file is empty", r->path);
        return -1;
    }
    return 0;
}

int fw_ensure_probe_file(const char *path, char *why, size_t why_len) {
    struct stat st;
    if (stat(path, &st) == 0 && S_ISREG(st.st_mode) && st.st_size >= FW_BLOCK)
        return 0;

    char dir[512];
    snprintf(dir, sizeof dir, "%s", path);
    char *slash = strrchr(dir, '/');
    if (slash != NULL && slash != dir) {
        *slash = '\0';
        if (mkdir(dir, 0755) != 0 && errno != EEXIST) {
            snprintf(why, why_len, "mkdir %s: %s", dir, strerror(errno));
            return -1;
        }
    }

    char tmp[520];
    snprintf(tmp, sizeof tmp, "%s.tmp", path);
    char block[FW_BLOCK];
    static const char line[] = "segno-freeze-watchdog reads this block past the page cache\n";
    for (size_t i = 0; i < sizeof block; i++) block[i] = line[i % (sizeof line - 1)];

    int fd = open(tmp, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
    if (fd < 0) {
        snprintf(why, why_len, "create %s: %s", tmp, strerror(errno));
        return -1;
    }
    int ok = write(fd, block, sizeof block) == (ssize_t)sizeof block && fsync(fd) == 0;
    int saved = errno;
    close(fd);
    if (!ok || rename(tmp, path) != 0) {
        snprintf(why, why_len, "write %s: %s", path, strerror(ok ? errno : saved));
        unlink(tmp);
        return -1;
    }
    return 0;
}

/* --- The prober ----------------------------------------------------------- */

struct fw_prober {
    pthread_mutex_t lock;
    pthread_cond_t cond;
    const struct fw_probe *probes;
    int count;
    /* Round numbers: the caller raises `requested`, the thread copies it to
     * `finished` when the round is over. Equal means idle. */
    uint64_t requested;
    uint64_t finished;
    int result;
    char why[FW_WHY_MAX];
    /* The probe running now, and since when; -1 when idle. */
    int step;
    int64_t step_started_ms;
};

static void *prober_main(void *arg) {
    struct fw_prober *pr = arg;
    pthread_mutex_lock(&pr->lock);
    for (;;) {
        while (pr->finished == pr->requested) pthread_cond_wait(&pr->cond, &pr->lock);
        uint64_t round = pr->requested;
        pthread_mutex_unlock(&pr->lock);

        int result = 0;
        char why[FW_WHY_MAX] = "";
        for (int i = 0; i < pr->count; i++) {
            pthread_mutex_lock(&pr->lock);
            pr->step = i;
            pr->step_started_ms = fw_now_ms();
            pthread_mutex_unlock(&pr->lock);
            if (pr->probes[i].run(pr->probes[i].ctx, why, sizeof why) != 0) {
                result = -1;
                break;
            }
        }

        pthread_mutex_lock(&pr->lock);
        pr->step = -1;
        pr->result = result;
        memcpy(pr->why, why, sizeof why);
        pr->finished = round;
        pthread_cond_broadcast(&pr->cond);
    }
    return NULL;
}

struct fw_prober *fw_prober_start(const struct fw_probe *probes, int count,
                                  char *why, size_t why_len) {
    struct fw_prober *pr = calloc(1, sizeof *pr);
    if (pr == NULL) {
        snprintf(why, why_len, "no memory for the prober");
        return NULL;
    }
    pr->probes = probes;
    pr->count = count;
    pr->step = -1;
    pthread_mutex_init(&pr->lock, NULL);
    pthread_condattr_t ca;
    pthread_condattr_init(&ca);
    pthread_condattr_setclock(&ca, CLOCK_MONOTONIC);
    pthread_cond_init(&pr->cond, &ca);
    pthread_condattr_destroy(&ca);

    /* The thread inherits this process's scheduling (SCHED_FIFO and the CPU
     * the unit pins it to), so an audio overload cannot starve it either. */
    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setstacksize(&attr, FW_PROBE_STACK);
    pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
    pthread_t thread;
    int rc = pthread_create(&thread, &attr, prober_main, pr);
    pthread_attr_destroy(&attr);
    if (rc != 0) {
        snprintf(why, why_len, "pthread_create: %s", strerror(rc));
        free(pr);
        return NULL;
    }
    return pr;
}

int fw_prober_round(struct fw_prober *pr, int64_t deadline_ms,
                    char *why, size_t why_len) {
    pthread_mutex_lock(&pr->lock);
    if (pr->finished != pr->requested) {
        /* The last round is still stuck. */
        snprintf(why, why_len, "%s has not returned for %lld s",
                 pr->step >= 0 ? pr->probes[pr->step].name : "a probe",
                 (long long)((fw_now_ms() - pr->step_started_ms) / 1000));
        pthread_mutex_unlock(&pr->lock);
        return -1;
    }
    uint64_t round = ++pr->requested;
    pthread_cond_broadcast(&pr->cond);

    struct timespec until;
    clock_gettime(CLOCK_MONOTONIC, &until);
    until.tv_sec += deadline_ms / 1000;
    until.tv_nsec += (deadline_ms % 1000) * 1000000;
    if (until.tv_nsec >= 1000000000) {
        until.tv_sec++;
        until.tv_nsec -= 1000000000;
    }
    while (pr->finished != round) {
        if (pthread_cond_timedwait(&pr->cond, &pr->lock, &until) == ETIMEDOUT) break;
    }

    int result;
    if (pr->finished == round) {
        result = pr->result;
        if (result != 0) snprintf(why, why_len, "%s", pr->why);
    } else {
        result = -1;
        snprintf(why, why_len, "%s did not return within %lld ms",
                 pr->step >= 0 ? pr->probes[pr->step].name : "a probe",
                 (long long)deadline_ms);
    }
    pthread_mutex_unlock(&pr->lock);
    return result;
}

/* --- Recovery ------------------------------------------------------------- */

void fw_log(int kmsg_fd, int level, const char *fmt, ...) {
    char line[640];
    int prefix = snprintf(line, sizeof line, "<%d>", level);
    int head = snprintf(line + prefix, sizeof line - prefix, "segno-freeze-watchdog: ");
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(line + prefix + head, sizeof line - prefix - head - 1, fmt, ap);
    va_end(ap);
    size_t len = strlen(line);
    line[len++] = '\n';
    if (kmsg_fd >= 0) {
        /* One write is one kernel log record. */
        if (write(kmsg_fd, line, len) == (ssize_t)len) return;
    }
    fwrite(line + prefix, 1, len - prefix, stderr);
}

static int sysrq(const struct fw_recovery *r, char key) {
    if (write(r->sysrq_fd, &key, 1) == 1) return 0;
    fw_log(r->kmsg_fd, 2, "sysrq %c failed: %s", key, strerror(errno));
    return -1;
}

int fw_recover(const struct fw_recovery *r, const char *reason) {
    /* KERN_CRIT, so the line also passes loglevel=4 into the pstore console
     * copy, not only the dmesg record. */
    fw_log(r->kmsg_fd, 2, "rebooting: %s. Dumping blocked tasks and CPU backtraces first", reason);
    sysrq(r, 'w');
    sysrq(r, 'l');
    /* Time for the backtrace IPIs to come back and the dump to finish. */
    fw_sleep_ms(r->dump_wait_ms);
    /* Again, last: the dmesg record keeps the tail of the log, and a long
     * blocked-task dump could push the first line out of it. */
    fw_log(r->kmsg_fd, 2, "rebooting now: %s", reason);
    sysrq(r, 's');
    /* Emergency sync runs on a workqueue: let it start before the panic
     * stops every CPU. On a dead disk it never finishes, which is fine. */
    fw_sleep_ms(r->sync_wait_ms);
    /* A panic, not sysrq b: emergency_restart() dumps the log with reason
     * EMERG, which ramoops (max_reason OOPS) does not record, so b would
     * leave only the console copy, filtered at loglevel=4 and without the
     * KERN_INFO task dump. The panic writes the whole tail into a dmesg
     * record, and panic=10 resets the board warm. If the panic hung, the
     * kernel would stop feeding the hardware watchdog, which resets within
     * 12 s. Neither reset carries the tryboot argument. */
    return sysrq(r, 'c');
}

/* --- systemd -------------------------------------------------------------- */

void fw_notify(const char *state) {
    static int fd = -1;
    const char *path = getenv("NOTIFY_SOCKET");
    if (path == NULL || path[0] == '\0') return;
    struct sockaddr_un sa = {.sun_family = AF_UNIX};
    size_t n = strlen(path);
    if (n >= sizeof sa.sun_path) return;
    memcpy(sa.sun_path, path, n);
    if (sa.sun_path[0] == '@') sa.sun_path[0] = '\0'; /* abstract namespace */
    if (fd < 0) fd = socket(AF_UNIX, SOCK_DGRAM | SOCK_CLOEXEC | SOCK_NONBLOCK, 0);
    if (fd < 0) return;
    sendto(fd, state, strlen(state), MSG_NOSIGNAL | MSG_DONTWAIT, (struct sockaddr *)&sa,
           (socklen_t)(offsetof(struct sockaddr_un, sun_path) + n));
}
