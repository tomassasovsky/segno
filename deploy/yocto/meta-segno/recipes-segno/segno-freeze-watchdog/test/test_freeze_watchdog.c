/* Unit tests for segno-freeze-watchdog's decision, prober, probes and
 * recovery sequence (#1527), with fake probes and files standing in for
 * /dev/kmsg and /proc/sysrq-trigger. Built and run by
 * run_freeze_watchdog_tests.sh. */
#define _GNU_SOURCE
#include "freeze_watchdog.h"

#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <sched.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>

static int passed, failed;

#define CHECK(name, cond)                                         \
    do {                                                          \
        if (cond) {                                               \
            passed++;                                             \
        } else {                                                  \
            failed++;                                             \
            fprintf(stderr, "FAIL: %s (%s:%d)\n", name, __FILE__, __LINE__); \
        }                                                         \
    } while (0)

static char dir[256];

static void path_in(char *out, size_t len, const char *name) {
    snprintf(out, len, "%s/%s", dir, name);
}

static char *slurp(const char *path) {
    static char buf[8192];
    int fd = open(path, O_RDONLY);
    ssize_t n = fd < 0 ? 0 : read(fd, buf, sizeof buf - 1);
    if (fd >= 0) close(fd);
    buf[n > 0 ? n : 0] = '\0';
    return buf;
}

/* --- The decision --------------------------------------------------------- */

static void test_tracker(void) {
    struct fw_policy p = {.fail_after_ms = 60000, .min_failures = 3};
    struct fw_tracker t;

    fw_tracker_start(&t, 0);
    CHECK("a pass never reboots", fw_tracker_record(&t, &p, 5000, 1) == 0);

    /* One slow round under load. */
    fw_tracker_start(&t, 0);
    CHECK("one failure does not reboot", fw_tracker_record(&t, &p, 70000, 0) == 0);

    /* Three fast failures in a row, all inside the minute. */
    fw_tracker_start(&t, 0);
    fw_tracker_record(&t, &p, 5000, 0);
    fw_tracker_record(&t, &p, 10000, 0);
    CHECK("three failures inside the minute do not reboot",
          fw_tracker_record(&t, &p, 15000, 0) == 0);

    /* Failing every 5 s since the last pass at 0 s. */
    fw_tracker_start(&t, 0);
    int fired_at = -1;
    for (int s = 5; s <= 120 && fired_at < 0; s += 5)
        if (fw_tracker_record(&t, &p, s * 1000, 0)) fired_at = s;
    CHECK("failing every round reboots once a minute has passed", fired_at == 60);

    /* A pass in between starts the minute again. */
    fw_tracker_start(&t, 0);
    for (int s = 5; s <= 55; s += 5) fw_tracker_record(&t, &p, s * 1000, 0);
    fw_tracker_record(&t, &p, 60000, 1);
    CHECK("a pass clears the count", t.failures == 0);
    CHECK("the minute restarts at the pass", fw_tracker_record(&t, &p, 65000, 0) == 0);
    fired_at = -1;
    for (int s = 70; s <= 200 && fired_at < 0; s += 5)
        if (fw_tracker_record(&t, &p, s * 1000, 0)) fired_at = s;
    CHECK("then reboots a minute after the pass", fired_at == 120);

    /* A probe stuck for long: two rounds noticed it, the minute is over. */
    fw_tracker_start(&t, 0);
    fw_tracker_record(&t, &p, 10000, 0);
    CHECK("a long gap with too few failures does not reboot",
          fw_tracker_record(&t, &p, 90000, 0) == 0);
    CHECK("the third failure does", fw_tracker_record(&t, &p, 95000, 0) == 1);
}

/* --- The prober, with fake probes ----------------------------------------- */

static int fake_pass(void *ctx, char *why, size_t len) {
    (void)why, (void)len;
    (*(int *)ctx)++;
    return 0;
}

static int fake_fail(void *ctx, char *why, size_t len) {
    snprintf(why, len, "%s", (const char *)ctx);
    return -1;
}

/* Blocks until a byte arrives on the pipe: a read stuck on a dead disk. */
static int fake_hang(void *ctx, char *why, size_t len) {
    (void)why, (void)len;
    char c;
    while (read(*(int *)ctx, &c, 1) < 0 && errno == EINTR) {
    }
    return 0;
}

static int fake_policy(void *ctx, char *why, size_t len) {
    (void)why, (void)len;
    *(int *)ctx = sched_getscheduler(0);
    return 0;
}

static void test_prober(void) {
    char why[FW_WHY_MAX];

    int first = 0, second = 0;
    struct fw_probe ok[] = {{"one", fake_pass, &first}, {"two", fake_pass, &second}};
    struct fw_prober *pr = fw_prober_start(ok, 2, why, sizeof why);
    CHECK("starts", pr != NULL);
    CHECK("a round of passing probes passes", fw_prober_round(pr, 1000, why, sizeof why) == 0);
    CHECK("every probe ran", first == 1 && second == 1);
    CHECK("each round runs them again",
          fw_prober_round(pr, 1000, why, sizeof why) == 0 && first == 2 && second == 2);

    int policy = -1;
    struct fw_probe pol[] = {{"policy", fake_policy, &policy}};
    pr = fw_prober_start(pol, 1, why, sizeof why);
    fw_prober_round(pr, 1000, why, sizeof why);
    CHECK("probes run at SCHED_OTHER", policy == SCHED_OTHER);

    int after = 0;
    struct fw_probe bad[] = {{"exec", fake_fail, "exec /bin/true: No such file or directory"},
                             {"after", fake_pass, &after}};
    pr = fw_prober_start(bad, 2, why, sizeof why);
    CHECK("a failing probe fails the round", fw_prober_round(pr, 1000, why, sizeof why) == -1);
    CHECK("with the probe's reason", strcmp(why, "exec /bin/true: No such file or directory") == 0);
    CHECK("and stops the round", after == 0);

    int fds[2];
    if (pipe(fds) != 0) abort();
    int ran = 0;
    struct fw_probe hang[] = {{"read /data/probe", fake_hang, &fds[0]}, {"exec", fake_pass, &ran}};
    pr = fw_prober_start(hang, 2, why, sizeof why);
    int64_t start = fw_now_ms();
    CHECK("a stuck probe fails the round", fw_prober_round(pr, 200, why, sizeof why) == -1);
    int64_t took = fw_now_ms() - start;
    CHECK("at its deadline", took >= 190 && took < 2000);
    CHECK("naming the stuck probe", strstr(why, "read /data/probe did not return within 200 ms") != NULL);
    start = fw_now_ms();
    CHECK("the next round fails while it is still stuck",
          fw_prober_round(pr, 200, why, sizeof why) == -1);
    CHECK("at once", fw_now_ms() - start < 100);
    CHECK("saying so", strstr(why, "read /data/probe has not returned for") != NULL);

    /* The disk comes back: the stuck round finishes, and the next one runs. */
    if (write(fds[1], "x", 1) != 1) abort();
    for (int i = 0; i < 100 && ran == 0; i++) fw_sleep_ms(10);
    fw_sleep_ms(50); /* for the thread to close the round it finished */
    if (write(fds[1], "x", 1) != 1) abort();
    CHECK("a round after it returned passes", fw_prober_round(pr, 1000, why, sizeof why) == 0);
}

/* --- The real probes ------------------------------------------------------ */

static void test_probes(void) {
    char why[FW_WHY_MAX];

    CHECK("exec of true passes", fw_probe_exec("/bin/true", why, sizeof why) == 0);
    CHECK("exec of a missing program fails",
          fw_probe_exec("/nonexistent/true", why, sizeof why) == -1);
    CHECK("saying what exec said", strstr(why, "exec /nonexistent/true: No such file or directory") != NULL);
    CHECK("exec of false fails", fw_probe_exec("/bin/false", why, sizeof why) == -1);
    CHECK("with its status", strstr(why, "exited 1") != NULL);

    char probe[300];
    path_in(probe, sizeof probe, "data/segno/probe");
    char data[300];
    path_in(data, sizeof data, "data");
    mkdir(data, 0755);
    CHECK("creates the probe file and its directory",
          fw_ensure_probe_file(probe, why, sizeof why) == 0);
    struct stat st;
    CHECK("one block long", stat(probe, &st) == 0 && st.st_size == 4096);
    char tmp[310];
    snprintf(tmp, sizeof tmp, "%s.tmp", probe);
    CHECK("leaves no temporary file", access(tmp, F_OK) != 0);

    struct fw_read_probe r;
    CHECK("opens the probe file", fw_read_probe_open(&r, probe, why, sizeof why) == 0);
    CHECK("reads it", fw_probe_read(&r, why, sizeof why) == 0);
    CHECK("and again", fw_probe_read(&r, why, sizeof why) == 0);
    cpu_set_t before, after;
    pthread_getaffinity_np(pthread_self(), sizeof before, &before);
    CHECK("reads it from every CPU", fw_probe_read_every_cpu(&r, why, sizeof why) == 0);
    pthread_getaffinity_np(pthread_self(), sizeof after, &after);
    CHECK("and puts the CPU mask back", CPU_EQUAL(&before, &after));

    /* An existing file is left as it is. */
    int fd = open(probe, O_WRONLY);
    if (fd < 0 || pwrite(fd, "KEEP", 4, 0) != 4) abort();
    close(fd);
    CHECK("an existing probe file is accepted", fw_ensure_probe_file(probe, why, sizeof why) == 0);
    CHECK("and not rewritten", strncmp(slurp(probe), "KEEP", 4) == 0);

    char empty[300];
    path_in(empty, sizeof empty, "empty");
    close(open(empty, O_WRONLY | O_CREAT, 0644));
    struct fw_read_probe e;
    CHECK("opens an empty file", fw_read_probe_open(&e, empty, why, sizeof why) == 0);
    CHECK("an empty read fails", fw_probe_read(&e, why, sizeof why) == -1);
    CHECK("saying so", strstr(why, "is empty") != NULL);

    struct fw_read_probe m;
    char missing[300];
    path_in(missing, sizeof missing, "missing");
    CHECK("a missing file cannot be opened", fw_read_probe_open(&m, missing, why, sizeof why) == -1);
    CHECK("saying which", strstr(why, missing) != NULL);

    /* A read error: a directory cannot be read (EISDIR), as a dead disk
     * returns EIO. Opened by hand: O_DIRECT refuses a directory. */
    struct fw_read_probe d = r;
    d.path = data;
    d.fd = open(data, O_RDONLY | O_DIRECTORY);
    CHECK("whose read fails", d.fd >= 0 && fw_probe_read(&d, why, sizeof why) == -1);
    CHECK("with the error", strstr(why, "Is a directory") != NULL);
    CHECK("from every CPU too", fw_probe_read_every_cpu(&d, why, sizeof why) == -1);
    CHECK("naming the CPU", strstr(why, "Is a directory (on CPU ") != NULL);
}

/* --- Recovery ------------------------------------------------------------- */

static void test_recover(void) {
    char kmsg[300], sysrq[300];
    path_in(kmsg, sizeof kmsg, "kmsg");
    path_in(sysrq, sizeof sysrq, "sysrq");
    struct fw_recovery r = {
        .kmsg_fd = open(kmsg, O_WRONLY | O_CREAT | O_APPEND, 0644),
        .sysrq_fd = open(sysrq, O_WRONLY | O_CREAT | O_APPEND, 0644),
        .dump_wait_ms = 50,
        .sync_wait_ms = 10,
    };
    int64_t start = fw_now_ms();
    CHECK("a trigger that is a file returns", fw_recover(&r, "the reason") == 0);
    CHECK("after the waits", fw_now_ms() - start >= 60);
    CHECK("dump blocked tasks, backtraces, sync, crash, in that order",
          strcmp(slurp(sysrq), "wlsc") == 0);
    const char *log = slurp(kmsg);
    const char *first = strstr(log, "<2>segno-freeze-watchdog: rebooting: the reason. Dumping");
    const char *last = strstr(log, "<2>segno-freeze-watchdog: rebooting now: the reason\n");
    CHECK("says why first", first != NULL);
    CHECK("and again last, at KERN_CRIT", last != NULL && first != NULL && last > first);

    close(r.sysrq_fd);
    r.sysrq_fd = -1;
    CHECK("a failed crash write is reported", fw_recover(&r, "no trigger") == -1);
    CHECK("and logged", strstr(slurp(kmsg), "sysrq c failed") != NULL);
    close(r.kmsg_fd);
}

/* --- systemd -------------------------------------------------------------- */

static void test_notify(void) {
    char sock[300];
    path_in(sock, sizeof sock, "notify");
    int fd = socket(AF_UNIX, SOCK_DGRAM, 0);
    struct sockaddr_un sa = {.sun_family = AF_UNIX};
    if (strlen(sock) >= sizeof sa.sun_path) abort();
    memcpy(sa.sun_path, sock, strlen(sock));
    if (fd < 0 || bind(fd, (struct sockaddr *)&sa, sizeof sa) != 0) abort();

    unsetenv("NOTIFY_SOCKET");
    fw_notify("READY=1");
    char buf[64];
    CHECK("no socket, nothing sent", recv(fd, buf, sizeof buf, MSG_DONTWAIT) < 0);

    setenv("NOTIFY_SOCKET", sock, 1);
    fw_notify("READY=1");
    ssize_t n = recv(fd, buf, sizeof buf - 1, MSG_DONTWAIT);
    buf[n > 0 ? n : 0] = '\0';
    CHECK("sends the state", strcmp(buf, "READY=1") == 0);
    close(fd);
    unsetenv("NOTIFY_SOCKET");
}

int main(void) {
    const char *tmp = getenv("TMPDIR");
    snprintf(dir, sizeof dir, "%s/freeze-watchdog-test.XXXXXX", tmp && *tmp ? tmp : "/tmp");
    if (mkdtemp(dir) == NULL) abort();

    test_tracker();
    test_prober();
    test_probes();
    test_recover();
    test_notify();

    printf("freeze_watchdog: %d passed, %d failed\n", passed, failed);
    return failed == 0 ? 0 : 1;
}
