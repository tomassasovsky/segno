#ifndef RING_FLASH_H
#define RING_FLASH_H
/*
 * ring_flash.h - the Pi's side of a ring firmware update (#1342): bridge the
 * console, ask the ring XIAO what it runs, and when that is not the image's
 * firmware, send it over SegnoRing's ring_update.h protocol.
 *
 * The transport and the clock are the caller's, so segno-ring-flash drives a
 * real UART and firmware/test/test_ring_update.cpp drives the actual ring
 * sketch on the host.
 */
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
  void *ctx;
  void (*write)(void *ctx, const uint8_t *bytes, size_t n);
  /* The next received byte, or -1 once timeout_ms pass without one. */
  int (*read)(void *ctx, unsigned timeout_ms);
  unsigned (*now_ms)(void *ctx);
  void (*log)(void *ctx, const char *message);
  /* Called once, just before an update is sent. */
  void (*attempt)(void *ctx);
} ring_flash_io;

typedef struct {
  const uint8_t *image;  /* the sealed TBYB image, ring_board.bin */
  size_t size;
  const uint8_t *digest; /* its SHA-256, from the version marker */
  uint8_t major, minor;  /* the firmware it is */
  int may_update;        /* 0: report, but do not send (too many attempts) */
} ring_flash_job;

typedef enum {
  RING_FLASH_CURRENT,    /* already running the image's firmware */
  RING_FLASH_UPDATED,    /* sent, booted on trial and confirmed */
  RING_FLASH_CONFIRMED,  /* found on trial with the image's firmware; confirmed */
  RING_FLASH_SILENT,     /* no answer: an old console or ring firmware, or no ring */
  RING_FLASH_NO_TABLE,   /* the ring needs its one USB install first */
  RING_FLASH_HELD,       /* differs, but may_update was 0 */
  RING_FLASH_FAILED      /* the ring still runs what it ran before */
} ring_flash_outcome;

ring_flash_outcome ring_flash_run(const ring_flash_io *io, const ring_flash_job *job);

/* How long to wait. Exposed so the host test can reason about them. */
#define RING_FLASH_QUERY_MS 1500u    /* first HELLO, through a just-bridged console */
#define RING_FLASH_ACK_MS 1500u      /* one chunk: the line, plus a sector erase */
#define RING_FLASH_COMMIT_MS 3000u   /* digest, first sector, reply */
#define RING_FLASH_REBOOT_MS 10000u  /* reboot, bootrom hash check, setup() */
#define RING_FLASH_RETRIES 3u

#ifdef __cplusplus
}
#endif
#endif /* RING_FLASH_H */
