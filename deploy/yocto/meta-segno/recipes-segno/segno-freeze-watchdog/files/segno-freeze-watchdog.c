/*
 * segno-freeze-watchdog: reboot the console warm, with a record, when exec or
 * storage stops working while the kernel and PID 1 live on (#1527).
 *
 * On 2026-11-01 the console stayed frozen for 9.5 hours: commands failed with
 * "command not found", dropbear could not start a session, and the journal had
 * stopped, but PID 1 kept feeding the hardware watchdog, so nothing reset the
 * board. The power cut that ended it erased the ramoops RAM.
 *
 * Every SEGNO_WATCHDOG_INTERVAL_MS this runs one round of probes on its probe
 * thread: an uncached read of a file on / from every CPU and of one on /data,
 * and an exec of
 * a trivial program. A round that fails, or does not finish within
 * SEGNO_WATCHDOG_DEADLINE_MS, counts as failed. After at least
 * SEGNO_WATCHDOG_MIN_FAILURES failed rounds in a row spanning
 * SEGNO_WATCHDOG_FAIL_AFTER_MS since the last pass, it logs why, dumps the
 * blocked tasks and CPU backtraces into the kernel log, and panics the kernel
 * through sysrq, which writes the log into ramoops and resets warm
 * (freeze_watchdog.c, fw_recover).
 *
 * It never execs anything itself and opens every path at startup. The unit
 * runs it at SCHED_FIFO 85, above the audio callback (80) and the effects
 * workers (79), pinned to core 0, where neither runs; it locks its memory
 * here.
 *
 * Exit status: 1 when it cannot start (including a first round that fails),
 * 3 when it asked for the reboot and is still running (only possible with a
 * test trigger, or a failed one).
 */
#define _GNU_SOURCE
#include "freeze_watchdog.h"

#include <errno.h>
#include <fcntl.h>
#include <sched.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/reboot.h>
#include <unistd.h>

static const char *env_or(const char *name, const char *fallback) {
    const char *v = getenv(name);
    return v != NULL && v[0] != '\0' ? v : fallback;
}

static int64_t env_num(const char *name, int64_t fallback) {
    const char *v = getenv(name);
    if (v == NULL || v[0] == '\0') return fallback;
    char *end;
    long long n = strtoll(v, &end, 10);
    return *end == '\0' && n > 0 ? n : fallback;
}

/* "0", "0-3", "1,2": the CPUs this process may run on. */
static void cpus_of_self(char *out, size_t len) {
    cpu_set_t set;
    out[0] = '\0';
    if (sched_getaffinity(0, sizeof set, &set) != 0) {
        snprintf(out, len, "?");
        return;
    }
    size_t used = 0;
    for (int cpu = 0; cpu < CPU_SETSIZE && used + 8 < len; cpu++) {
        if (CPU_ISSET(cpu, &set))
            used += snprintf(out + used, len - used, "%s%d", used ? "," : "", cpu);
    }
}

int main(void) {
    const char *exec_path = env_or("SEGNO_WATCHDOG_EXEC", "/bin/true");
    /* Shipped by the recipe for this alone, so nothing maps or locks it. */
    const char *root_file = env_or("SEGNO_WATCHDOG_ROOT_FILE", "/usr/lib/segno/freeze-watchdog-probe");
    const char *data_file = env_or("SEGNO_WATCHDOG_DATA_FILE", "/data/segno/freeze-watchdog-probe");
    const char *sysrq_path = env_or("SEGNO_WATCHDOG_SYSRQ", "/proc/sysrq-trigger");
    const char *kmsg_path = env_or("SEGNO_WATCHDOG_KMSG", "/dev/kmsg");
    int64_t interval_ms = env_num("SEGNO_WATCHDOG_INTERVAL_MS", 5000);
    int64_t deadline_ms = env_num("SEGNO_WATCHDOG_DEADLINE_MS", 10000);
    /* 90 s, so a stall the drive recovers from never reboots the console
     * mid-set. The NVMe driver answers a command's first timeout (30 s) with
     * an Abort and waits again; only the second (60 s) resets the
     * controller, and the reset takes seconds more. The stalled read can
     * also start up to one interval after the last pass. */
    struct fw_policy policy = {
        .fail_after_ms = env_num("SEGNO_WATCHDOG_FAIL_AFTER_MS", 90000),
        .min_failures = (int)env_num("SEGNO_WATCHDOG_MIN_FAILURES", 3),
    };
    struct fw_recovery recovery = {
        .dump_wait_ms = env_num("SEGNO_WATCHDOG_DUMP_WAIT_MS", 2000),
        .sync_wait_ms = env_num("SEGNO_WATCHDOG_SYNC_WAIT_MS", 1000),
    };
    char why[FW_WHY_MAX];

    recovery.kmsg_fd = open(kmsg_path, O_WRONLY | O_APPEND | O_CLOEXEC);
    if (recovery.kmsg_fd < 0) {
        fw_log(-1, 3, "cannot open %s: %s", kmsg_path, strerror(errno));
        return 1;
    }
    recovery.sysrq_fd = open(sysrq_path, O_WRONLY | O_APPEND | O_CLOEXEC);
    if (recovery.sysrq_fd < 0) {
        fw_log(recovery.kmsg_fd, 3, "cannot start: open %s: %s", sysrq_path, strerror(errno));
        return 1;
    }

    static struct fw_read_probe root_read, data_read;
    if (fw_ensure_probe_file(data_file, why, sizeof why) != 0 ||
        fw_read_probe_open(&root_read, root_file, why, sizeof why) != 0 ||
        fw_read_probe_open(&data_read, data_file, why, sizeof why) != 0) {
        fw_log(recovery.kmsg_fd, 3, "cannot start: %s", why);
        return 1;
    }

    static char root_name[300], data_name[300], exec_name[300];
    snprintf(root_name, sizeof root_name, "read %s on each CPU", root_file);
    snprintf(data_name, sizeof data_name, "read %s", data_file);
    snprintf(exec_name, sizeof exec_name, "exec %s", exec_path);
    static struct fw_probe probes[3];
    probes[0] = (struct fw_probe){root_name, fw_probe_read_every_cpu, &root_read};
    probes[1] = (struct fw_probe){data_name, fw_probe_read, &data_read};
    probes[2] = (struct fw_probe){exec_name, fw_probe_exec, (void *)exec_path};

    /* Before the probe thread exists, so MCL_FUTURE locks its stack too. A
     * page fault on a dead disk would otherwise stall this thread as well. */
    const char *locked = "locked";
    if (mlockall(MCL_CURRENT | MCL_FUTURE) != 0) {
        fw_log(recovery.kmsg_fd, 4, "mlockall: %s; running with memory that can be paged out",
               strerror(errno));
        locked = "NOT locked";
    }

    struct fw_prober *prober = fw_prober_start(probes, 3, why, sizeof why);
    if (prober == NULL) {
        fw_log(recovery.kmsg_fd, 3, "cannot start: %s", why);
        return 1;
    }
    /* Arm only on probes that work: a probe broken from the start (a program
     * an image no longer ships) would otherwise reboot the console a minute
     * after every boot. systemd tries again in 30 s, five times. */
    if (fw_prober_round(prober, deadline_ms, why, sizeof why) != 0) {
        fw_log(recovery.kmsg_fd, 3, "cannot start: the first probe round failed: %s", why);
        return 1;
    }

    struct sched_param sp = {0};
    sched_getparam(0, &sp);
    int policy_now = sched_getscheduler(0);
    char cpus[64];
    cpus_of_self(cpus, sizeof cpus);
    fw_log(recovery.kmsg_fd, 6,
           "watching %s, %s and %s every %lld ms; reboots after %d failed rounds "
           "and %lld s without a pass (%s %d, CPU %s, memory %s)",
           root_name, data_name, exec_name, (long long)interval_ms, policy.min_failures,
           (long long)(policy.fail_after_ms / 1000),
           policy_now == SCHED_FIFO ? "SCHED_FIFO" : "NOT SCHED_FIFO", sp.sched_priority,
           cpus, locked);

    fw_notify("READY=1");
    struct fw_tracker tracker;
    fw_tracker_start(&tracker, fw_now_ms());
    for (;;) {
        int ok = fw_prober_round(prober, deadline_ms, why, sizeof why) == 0;
        int64_t now = fw_now_ms();
        int failed_before = tracker.failures;
        int reboot_now = fw_tracker_record(&tracker, &policy, now, ok);
        if (!ok) {
            fw_log(recovery.kmsg_fd, 4, "probe failed (%d in a row, %lld s since the last pass): %s",
                   tracker.failures, (long long)((now - tracker.last_ok_ms) / 1000), why);
        } else if (failed_before > 0) {
            fw_log(recovery.kmsg_fd, 5, "probes pass again after %d failed rounds", failed_before);
        }
        if (reboot_now) {
            char reason[FW_WHY_MAX + 96];
            snprintf(reason, sizeof reason, "exec or storage dead: %d probe rounds failed over %lld s, the last: %s",
                     tracker.failures, (long long)((now - tracker.last_ok_ms) / 1000), why);
            int crash = fw_recover(&recovery, reason);
            /* Still here: the panic did not happen. With the kernel's
             * trigger that is a failure whatever the write returned, and
             * exiting would leave a restart that needs exec, so reboot(2).
             * It runs the device shutdown, which a dead disk can hang, but
             * it is all that is left. No sync(): that would wait on the
             * dead disk. A test trigger only exits. */
            if (strcmp(sysrq_path, "/proc/sysrq-trigger") == 0) {
                fw_log(recovery.kmsg_fd, 2, "sysrq did not reboot (%s); calling reboot(2)",
                       crash != 0 ? "the crash write failed" : "the crash write returned");
                reboot(RB_AUTOBOOT);
                fw_log(recovery.kmsg_fd, 2, "reboot(2): %s", strerror(errno));
            }
            return 3;
        }
        fw_notify("WATCHDOG=1");
        fw_sleep_ms(interval_ms);
    }
}
