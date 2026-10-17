/*
 * segno-ring-flash - put the ring carrier's XIAO on the firmware this image
 * ships (#1342).
 *
 * The ring has no SWD path; it is updated through the console Pico, which
 * bridges the Pi's UART to the ring's while this runs (ring_flash.c). Runs
 * after segno-console-flash, so the console already has the bridge, and
 * before segno.service, so the app never shares the line with an update.
 *
 * A boot with a current ring costs one QUERY. An update takes about ten
 * seconds. Exit status is 0 on every path: the app must start whatever the
 * ring does, and the journal has the reason.
 *
 * The ring keeps booting its previous firmware if anything here fails; the
 * next boot tries again, up to MAX_ATTEMPTS per firmware version, so an image
 * the ring keeps rejecting does not slow every boot. A ring that does not
 * answer at all (no updater yet, or no ring) is recorded the same way, per
 * shipped version, so later boots skip the 1.5 s wait for it.
 */
#define _DEFAULT_SOURCE /* cfmakeraw, CRTSCTS */

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>

#include "ring_flash.h"

#define MAX_ATTEMPTS 3
#define MAX_IMAGE (512u * 1024u) /* one partition */

static void log_line(const char *message) {
  fprintf(stderr, "segno-ring-flash: %s\n", message);
}

static const char *env(const char *name, const char *fallback) {
  const char *value = getenv(name);
  return value && *value ? value : fallback;
}

typedef struct {
  int fd;
  char attempts_path[512];
  char want[16];
} uart;

static void uart_write(void *ctx, const uint8_t *bytes, size_t n) {
  const uart *u = ctx;
  while (n) {
    const ssize_t done = write(u->fd, bytes, n);
    if (done < 0) {
      if (errno == EINTR) continue;
      return;
    }
    bytes += done;
    n -= (size_t)done;
  }
}

static int uart_read(void *ctx, unsigned timeout_ms) {
  const uart *u = ctx;
  struct pollfd p = {u->fd, POLLIN, 0};
  for (;;) {
    const int ready = poll(&p, 1, (int)timeout_ms);
    if (ready < 0 && errno == EINTR) continue;
    if (ready <= 0) return -1;
    uint8_t byte;
    const ssize_t got = read(u->fd, &byte, 1);
    if (got == 1) return byte;
    if (got < 0 && errno == EINTR) continue;
    return -1;
  }
}

static unsigned uart_now(void *ctx) {
  (void)ctx;
  struct timespec t;
  clock_gettime(CLOCK_MONOTONIC, &t);
  return (unsigned)(t.tv_sec * 1000u + t.tv_nsec / 1000000);
}

static void uart_log(void *ctx, const char *message) {
  (void)ctx;
  log_line(message);
}

/* Whether a record file says "firmware=<want>" (the silent record). */
static int recorded_for(const char *path, const char *want) {
  FILE *f = fopen(path, "r");
  if (!f) return 0;
  char firmware[16] = "";
  const int got = fscanf(f, "firmware=%15s", firmware);
  fclose(f);
  return got == 1 && strcmp(firmware, want) == 0;
}

/* attempts: "firmware=M.m count=N". Counts updates started at this version. */
static int attempts_for(const char *path, const char *want) {
  FILE *f = fopen(path, "r");
  if (!f) return 0;
  char firmware[16] = "";
  int count = 0;
  const int got = fscanf(f, "firmware=%15s count=%d", firmware, &count);
  fclose(f);
  return got == 2 && strcmp(firmware, want) == 0 ? count : 0;
}

static void write_record(const char *path, const char *line) {
  char tmp[600];
  snprintf(tmp, sizeof(tmp), "%s.tmp", path);
  FILE *f = fopen(tmp, "w");
  if (!f) return;
  const int ok = fputs(line, f) >= 0;
  if (fclose(f) == 0 && ok) rename(tmp, path);
  else unlink(tmp);
}

static void uart_attempt(void *ctx) {
  const uart *u = ctx;
  char line[64];
  snprintf(line, sizeof(line), "firmware=%s count=%d\n", u->want, attempts_for(u->attempts_path, u->want) + 1);
  write_record(u->attempts_path, line);
}

/* mkdir -p: the state directory lives on /data, which starts empty. */
static void make_dirs(const char *path) {
  char partial[512];
  snprintf(partial, sizeof(partial), "%s", path);
  for (char *p = partial + 1; *p; ++p) {
    if (*p != '/') continue;
    *p = 0;
    mkdir(partial, 0755);
    *p = '/';
  }
  mkdir(partial, 0755);
}

static int hex_digest(const char *hex, uint8_t *out) {
  if (strlen(hex) != 64) return 0;
  for (int i = 0; i < 32; ++i) {
    unsigned byte;
    if (sscanf(hex + 2 * i, "%2x", &byte) != 1) return 0;
    out[i] = (uint8_t)byte;
  }
  return 1;
}

static int open_uart(const char *dev) {
  const int fd = open(dev, O_RDWR | O_NOCTTY);
  if (fd < 0) return -1;
  struct termios t;
  if (tcgetattr(fd, &t) != 0) {
    close(fd);
    return -1;
  }
  cfmakeraw(&t);
  cfsetispeed(&t, B115200);
  cfsetospeed(&t, B115200);
  t.c_cflag |= CLOCAL | CREAD;
  t.c_cflag &= ~(CSTOPB | PARENB | CRTSCTS);
  t.c_cc[VMIN] = 0;
  t.c_cc[VTIME] = 0;
  if (tcsetattr(fd, TCSANOW, &t) != 0) {
    close(fd);
    return -1;
  }
  tcflush(fd, TCIOFLUSH);
  return fd;
}

int main(void) {
  const char *dev = env("SEGNO_LINK_DEV", "/dev/ttyAMA3");
  const char *dir = env("SEGNO_RING_FW_DIR", "/usr/lib/segno/ring-board");
  const char *state = env("SEGNO_RING_STATE_DIR", "/data/segno/ring-board");
  char path[512], line[640];  // line holds a path and a sentence

  // The marker names what this image ships: "firmware=M.m size=N sha256=HEX".
  snprintf(path, sizeof(path), "%s/version", dir);
  FILE *marker = fopen(path, "r");
  if (!marker) {
    log_line("no ring firmware marker; nothing to enforce");
    return 0;
  }
  unsigned major = 0, minor = 0;
  unsigned long size = 0;
  char hex[80] = "";
  const int fields = fscanf(marker, "firmware=%u.%u size=%lu sha256=%79s", &major, &minor, &size, hex);
  fclose(marker);
  uint8_t digest[32];
  if (fields != 4 || major > 255 || minor > 255 || size == 0 || size > MAX_IMAGE || !hex_digest(hex, digest)) {
    log_line("the ring firmware marker is unreadable; refusing to guess");
    return 0;
  }

  snprintf(path, sizeof(path), "%s/ring_board.bin", dir);
  FILE *bin = fopen(path, "rb");
  static uint8_t image[MAX_IMAGE + 1];
  const size_t got = bin ? fread(image, 1, sizeof(image), bin) : 0;
  if (bin) fclose(bin);
  if (got != size) {
    log_line("the ring image does not match its marker; leaving the ring alone");
    return 0;
  }

  uart u;
  memset(&u, 0, sizeof(u));
  snprintf(u.want, sizeof(u.want), "%u.%u", major, minor);
  snprintf(u.attempts_path, sizeof(u.attempts_path), "%s/attempts", state);
  make_dirs(state);

  // A ring that did not answer for this shipped version will not answer now
  // either: no updater yet (its one USB install), or no ring. A new image asks
  // again; so does removing the record.
  char silent_path[520];
  snprintf(silent_path, sizeof(silent_path), "%s/silent", state);
  if (recorded_for(silent_path, u.want)) {
    snprintf(line, sizeof(line), "the ring did not answer when %s shipped; not asking (remove %s to ask again)",
             u.want, silent_path);
    log_line(line);
    return 0;
  }

  u.fd = open_uart(dev);
  if (u.fd < 0) {
    snprintf(line, sizeof(line), "cannot open %s: %s", dev, strerror(errno));
    log_line(line);
    return 0;
  }

  const ring_flash_io io = {&u, uart_write, uart_read, uart_now, uart_log, uart_attempt};
  const ring_flash_job job = {image, size, digest, (uint8_t)major, (uint8_t)minor,
                              attempts_for(u.attempts_path, u.want) < MAX_ATTEMPTS};
  const ring_flash_outcome outcome = ring_flash_run(&io, &job);
  tcdrain(u.fd);
  close(u.fd);

  if (outcome == RING_FLASH_SILENT) {
    snprintf(line, sizeof(line), "firmware=%s\n", u.want);
    write_record(silent_path, line);
    snprintf(line, sizeof(line), "recorded in %s: later boots of this image skip the wait", silent_path);
    log_line(line);
  } else {
    unlink(silent_path);
  }
  if (outcome == RING_FLASH_HELD) {
    // A cut line counts as much as a rejected image: say how to try again.
    snprintf(line, sizeof(line), "remove %s to let the next boot try %s again", u.attempts_path, u.want);
    log_line(line);
  }
  if (outcome == RING_FLASH_CURRENT || outcome == RING_FLASH_UPDATED || outcome == RING_FLASH_CONFIRMED) {
    unlink(u.attempts_path);
    if (outcome != RING_FLASH_CURRENT) {
      snprintf(path, sizeof(path), "%s/last-flashed", state);
      snprintf(line, sizeof(line), "firmware=%s\n", u.want);
      write_record(path, line);
    }
  }
  return 0;
}
