#ifndef RING_UPDATE_H
#define RING_UPDATE_H
/*
 * ring_update.h - firmware updates for the ring carrier's XIAO, carried on the
 * same UART as the ring link (#1342).
 *
 * The Pi's segno-ring-flash puts the console Pico into bridge mode (pedal-link
 * RING_BRIDGE), then talks to the XIAO directly. The XIAO writes the image
 * into the other half of an RP2350 bootrom A/B partition pair and reboots into
 * it on trial (try-before-you-buy); only CONFIRM, which proves the new image
 * can hear the Pi through the console, makes it permanent. Anything short of
 * that leaves the previous image booting.
 *
 * Frames use ring_frame.h. Body: RING_UPDATE_CHANNEL, type, payload. The
 * channel byte is never a ring-link version, so the ring link ignores these
 * frames and this protocol does not move when the ring link does: any console
 * can update any updater-capable ring. The channel, QUERY and the HELLO layout
 * are frozen; a later revision adds message types and bumps
 * RING_UPDATE_PROTOCOL.
 *
 * Plain C99, header-only, shared by the XIAO, the console's bridge, the Pi
 * tool and the host tests.
 */
#include <stddef.h>
#include <stdint.h>
#include <string.h>

#include "ring_frame.h"

#ifdef __cplusplus
extern "C" {
#endif

#define RING_UPDATE_CHANNEL 0xb5u
#define RING_UPDATE_PROTOCOL 1u

/* Pi -> ring */
#define RING_UPDATE_QUERY 0x01u    /* [] -> HELLO */
#define RING_UPDATE_BEGIN 0x02u    /* [size u32, sha256 32] -> ACK */
#define RING_UPDATE_DATA 0x03u     /* [offset u32, 1..RING_UPDATE_CHUNK bytes] -> ACK */
#define RING_UPDATE_COMMIT 0x04u   /* [] -> ACK, then a flash-update reboot */
#define RING_UPDATE_CONFIRM 0x05u  /* [] -> ACK; buys the image on trial */
/* Pi -> console: leave bridge mode. The ring ignores it. */
#define RING_UPDATE_BRIDGE_END 0x06u
/* ring -> Pi */
#define RING_UPDATE_HELLO 0x81u    /* [fw major, fw minor, protocol, flags, partition] */
#define RING_UPDATE_ACK 0x82u      /* [for type, status, value u32] */

/* HELLO flags. TRIAL: a flash-update boot awaits CONFIRM. NO_TABLE: flash has
 * no partition table, so this ring can only be updated over USB. */
#define RING_UPDATE_FLAG_TRIAL 0x01u
#define RING_UPDATE_FLAG_NO_TABLE 0x02u

/* ACK status. The value is the next offset expected (BEGIN/DATA), else 0. */
#define RING_UPDATE_OK 0u
#define RING_UPDATE_BAD_STATE 1u   /* no BEGIN, or BEGIN while on trial */
#define RING_UPDATE_BAD_SIZE 2u    /* empty, or larger than the partition */
#define RING_UPDATE_BAD_OFFSET 3u  /* not the next chunk */
#define RING_UPDATE_DIGEST 4u      /* the received image is not the one announced */
#define RING_UPDATE_FLASH 5u       /* the bootrom refused a flash or buy operation */
#define RING_UPDATE_NO_TABLE 6u

#define RING_UPDATE_CHUNK 1024u
#define RING_UPDATE_DIGEST_LEN 32u
#define RING_UPDATE_HELLO_LEN 5u
#define RING_UPDATE_ACK_LEN 6u
#define RING_UPDATE_BEGIN_LEN (4u + RING_UPDATE_DIGEST_LEN)
/* Channel, type, the largest payload (DATA). */
#define RING_UPDATE_MAX_BODY (2u + 4u + RING_UPDATE_CHUNK)
/* Room for a body and its CRC in a ring_frame_parser. */
#define RING_UPDATE_PARSER_CAPACITY (RING_UPDATE_MAX_BODY + 2u)
#define RING_UPDATE_MAX_FRAME RING_FRAME_ENCODED_MAX(RING_UPDATE_MAX_BODY)

static inline void ring_update_put32(uint8_t *p, uint32_t v) {
  p[0] = (uint8_t)v; p[1] = (uint8_t)(v >> 8); p[2] = (uint8_t)(v >> 16); p[3] = (uint8_t)(v >> 24);
}
static inline uint32_t ring_update_get32(const uint8_t *p) {
  return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24;
}

/* Frames one message into `out` (RING_UPDATE_MAX_FRAME bytes). */
static inline size_t ring_update_encode(uint8_t type, const uint8_t *payload, size_t n, uint8_t *out) {
  uint8_t body[RING_UPDATE_MAX_BODY];
  if (n > RING_UPDATE_MAX_BODY - 2u) return 0;
  body[0] = RING_UPDATE_CHANNEL;
  body[1] = type;
  if (n) memcpy(body + 2, payload, n);
  return ring_frame_encode(body, n + 2, out);
}

/* Whether a parsed body is an update message; sets type, payload and length. */
static inline int ring_update_message(const uint8_t *body, size_t length, uint8_t *type,
                                      const uint8_t **payload, size_t *n) {
  if (length < 2 || body[0] != RING_UPDATE_CHANNEL) return 0;
  *type = body[1];
  *payload = body + 2;
  *n = length - 2;
  return 1;
}

#ifdef __cplusplus
}
#endif
#endif /* RING_UPDATE_H */
