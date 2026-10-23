#ifndef RING_FRAME_H
#define RING_FRAME_H
/*
 * ring_frame.h - the framing every message on the console <-> ring UART uses:
 * a body, its CRC-16/CCITT-FALSE (little-endian), SLIP-escaped (RFC 1055) and
 * delimited by END bytes. The body's first byte says whose message it is: the
 * ring-link version for ring_link.h, RING_UPDATE_CHANNEL for ring_update.h.
 *
 * Plain C99, header-only, so the XIAO, the console Pico, the Pi's
 * segno-ring-flash and the host tests all compile the same bytes.
 */
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define RING_FRAME_END 0xc0u
#define RING_FRAME_ESC 0xdbu
#define RING_FRAME_ESC_END 0xdcu
#define RING_FRAME_ESC_ESC 0xddu

/* The worst-case encoded size of a body of n bytes: every byte and both CRC
 * bytes escaped, plus the two END delimiters. */
#define RING_FRAME_ENCODED_MAX(n) (2u * ((n) + 2u) + 2u)

static inline uint16_t ring_frame_crc16(const uint8_t *p, size_t length) {
  uint16_t crc = 0xffff;
  while (length--) {
    crc ^= (uint16_t)(*p++ << 8);
    for (uint8_t i = 0; i < 8; ++i)
      crc = (uint16_t)((crc << 1) ^ ((crc & 0x8000) ? 0x1021 : 0));
  }
  return crc;
}

static inline size_t ring_frame_put(uint8_t byte, uint8_t *out) {
  if (byte == RING_FRAME_END || byte == RING_FRAME_ESC) {
    out[0] = RING_FRAME_ESC;
    out[1] = byte == RING_FRAME_END ? RING_FRAME_ESC_END : RING_FRAME_ESC_ESC;
    return 2;
  }
  out[0] = byte;
  return 1;
}

/* Frames `body` (n bytes, without CRC) into `out`, which must hold
 * RING_FRAME_ENCODED_MAX(n) bytes. Returns the encoded length. */
static inline size_t ring_frame_encode(const uint8_t *body, size_t n, uint8_t *out) {
  const uint16_t crc = ring_frame_crc16(body, n);
  size_t cursor = 0;
  out[cursor++] = RING_FRAME_END;
  for (size_t i = 0; i < n; ++i) cursor += ring_frame_put(body[i], out + cursor);
  cursor += ring_frame_put((uint8_t)crc, out + cursor);
  cursor += ring_frame_put((uint8_t)(crc >> 8), out + cursor);
  out[cursor++] = RING_FRAME_END;
  return cursor;
}

/* A decoder over a caller-owned buffer. A frame longer than the buffer, a bad
 * escape or a CRC mismatch is dropped, and the next END resynchronises. */
typedef struct {
  uint8_t *body;
  size_t capacity;
  size_t used;
  uint8_t escape, rejected;
  uint32_t dropped;
} ring_frame_parser;

static inline void ring_frame_parser_init(ring_frame_parser *p, uint8_t *buffer, size_t capacity) {
  p->body = buffer;
  p->capacity = capacity;
  p->used = 0;
  p->escape = p->rejected = 0;
  p->dropped = 0;
}

/* Returns 1 when `byte` completes a frame whose CRC checks; the body (without
 * CRC) is p->body and its length *length. */
static inline int ring_frame_parser_push(ring_frame_parser *p, uint8_t byte, size_t *length) {
  if (byte == RING_FRAME_END) {
    int valid = !p->escape && !p->rejected && p->used >= 3;
    if (valid) {
      const size_t n = p->used - 2;
      valid = ring_frame_crc16(p->body, n) == (uint16_t)(p->body[n] | p->body[n + 1] << 8);
      if (valid) *length = n;
    }
    if (!valid && (p->used || p->escape || p->rejected)) ++p->dropped;
    p->used = 0;
    p->escape = p->rejected = 0;
    return valid;
  }
  if (p->rejected) return 0;
  if (p->escape) {
    p->escape = 0;
    if (byte == RING_FRAME_ESC_END) byte = RING_FRAME_END;
    else if (byte == RING_FRAME_ESC_ESC) byte = RING_FRAME_ESC;
    else { p->rejected = 1; return 0; }
  } else if (byte == RING_FRAME_ESC) {
    p->escape = 1;
    return 0;
  }
  if (p->used == p->capacity) { p->rejected = 1; return 0; }
  p->body[p->used++] = byte;
  return 0;
}

#ifdef __cplusplus
}
#endif
#endif /* RING_FRAME_H */
