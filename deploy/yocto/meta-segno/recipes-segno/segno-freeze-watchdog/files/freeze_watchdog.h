/*
 * segno-freeze-watchdog: the parts the daemon is made of, kept apart from
 * main() so the tests can drive them with fake probes (#1527).
 *
 * The failure this exists for: the kernel and PID 1 stay alive, so the
 * hardware watchdog keeps being fed, while exec and the filesystems are dead.
 * Nothing can be started any more, so detection and recovery both live in one
 * process that is already running and never needs to exec anything itself.
 */
#ifndef SEGNO_FREEZE_WATCHDOG_H
#define SEGNO_FREEZE_WATCHDOG_H

#include <stddef.h>
#include <stdint.h>

#define FW_WHY_MAX 256

/* Monotonic milliseconds. */
int64_t fw_now_ms(void);
void fw_sleep_ms(int64_t ms);

/* --- The decision ---------------------------------------------------------
 *
 * One slow I/O under load must not reboot the console, and neither must a
 * stall the drive recovers from: nvme_core times a command out after 30 s and
 * then resets the controller. So a reboot needs both at least `min_failures`
 * failed rounds in a row and `fail_after_ms` since the last round that passed.
 */
struct fw_policy {
    int64_t fail_after_ms;
    int min_failures;
};

struct fw_tracker {
    int64_t last_ok_ms;
    int failures;
};

void fw_tracker_start(struct fw_tracker *t, int64_t now_ms);

/* Records one round. Returns 1 when the console should reboot. */
int fw_tracker_record(struct fw_tracker *t, const struct fw_policy *p,
                      int64_t now_ms, int ok);

/* --- Probes ---------------------------------------------------------------
 *
 * A probe returns 0 when it passed, and otherwise fills `why`.
 */
typedef int (*fw_probe_fn)(void *ctx, char *why, size_t why_len);

struct fw_probe {
    const char *name;
    fw_probe_fn run;
    void *ctx;
};

/* Starts a program (ctx is its path) and waits for it to exit 0. */
int fw_probe_exec(void *ctx, char *why, size_t why_len);

/* Reads the first block of a file past the page cache. */
struct fw_read_probe {
    const char *path;
    int fd;
    int direct; /* 1: O_DIRECT; 0: the cached page is dropped before each read */
    void *buf;
};

int fw_read_probe_open(struct fw_read_probe *r, const char *path,
                       char *why, size_t why_len);
int fw_probe_read(void *ctx, char *why, size_t why_len);

/* Creates `path` holding one block if it is missing or shorter, so the read
 * probe on /data has a file to read. Returns 0 on success. */
int fw_ensure_probe_file(const char *path, char *why, size_t why_len);

/* --- The prober -----------------------------------------------------------
 *
 * Runs each round's probes on its own thread, so a probe stuck in the kernel
 * (uninterruptible sleep on a dead disk) cannot block the caller. A stuck
 * round counts as failed at its deadline, and every round after it fails at
 * once until it returns: a thread in uninterruptible sleep cannot be stopped,
 * so no second one is started next to it.
 */
struct fw_prober;

struct fw_prober *fw_prober_start(const struct fw_probe *probes, int count,
                                  char *why, size_t why_len);

/* Runs one round, waiting at most `deadline_ms`. Returns 0 when every probe
 * passed, and otherwise -1 with `why` filled. */
int fw_prober_round(struct fw_prober *pr, int64_t deadline_ms,
                    char *why, size_t why_len);

/* --- Recovery -------------------------------------------------------------
 *
 * Both descriptors are opened at startup, since nothing can be opened by path
 * once the filesystems are gone.
 */
struct fw_recovery {
    int kmsg_fd;  /* /dev/kmsg */
    int sysrq_fd; /* /proc/sysrq-trigger */
    int64_t dump_wait_ms;
    int64_t sync_wait_ms;
};

/* One line in the kernel log at `level` (0-7), or on stderr when there is no
 * kernel log. The kernel log never waits on a disk; the journal's stream
 * socket does, once journald is stuck behind the dead filesystem. */
void fw_log(int kmsg_fd, int level, const char *fmt, ...)
    __attribute__((format(printf, 3, 4)));

/* Says why in the kernel log, dumps the blocked tasks (sysrq w) and every
 * CPU's backtrace (sysrq l), waits, syncs (sysrq s), and panics (sysrq c).
 * The panic writes the kernel log into a ramoops dmesg record and, with
 * panic=10, resets the board warm, so the record survives.
 *
 * Returns only when the panic did not happen: 0 when every write was
 * accepted (a trigger that is not the kernel's, in the tests), -1 when the
 * crash write failed. */
int fw_recover(const struct fw_recovery *r, const char *reason);

/* --- systemd --------------------------------------------------------------
 *
 * sd_notify(3)'s datagram, sent without waiting: libsystemd's sd_notify uses
 * a blocking send, and this process must never wait on anyone. A no-op
 * without $NOTIFY_SOCKET. */
void fw_notify(const char *state);

#endif
