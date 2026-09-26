#pragma once
#include <stddef.h>
#include <stdint.h>
#include <string.h>
#include "pedal_link.h"

// Private ring UART: SLIP framing (RFC 1055), CRC-16/CCITT-FALSE and version 2.
// Fixed messages: STATE is the canonical pedal-state payload. INPUT is
// boot nonce, cumulative detent count and cumulative button edge count (LE32).
// Counter snapshots recover dropped short presses as well as missing detents.
namespace ring_link {
constexpr uint8_t VERSION = 2, STATE = 1, INPUT_STATE = 2;
constexpr uint8_t END = 0xc0, ESC = 0xdb, ESC_END = 0xdc, ESC_ESC = 0xdd;
constexpr size_t MAX_PAYLOAD = PEDAL_LINK_STATE_LEN, MAX_BODY = MAX_PAYLOAD + 4;
constexpr size_t MAX_FRAME = MAX_BODY * 2 + 2;
constexpr uint32_t SNAPSHOT_MS = 20, STATE_MS = 100, TIMEOUT_MS = 500;

inline uint16_t crc16(const uint8_t *p, size_t length) {
  uint16_t crc = 0xffff;
  while (length--) {
    crc ^= (uint16_t)*p++ << 8;
    for (uint8_t i = 0; i < 8; ++i)
      crc = (uint16_t)((crc << 1) ^ ((crc & 0x8000) ? 0x1021 : 0));
  }
  return crc;
}
inline size_t payloadLength(uint8_t type) { return type == STATE ? PEDAL_LINK_STATE_LEN : type == INPUT_STATE ? 12 : 0; }
inline void put32(uint8_t *p, uint32_t value) {
  for (uint8_t i = 0; i < 4; ++i) p[i] = (uint8_t)(value >> (8 * i));
}
inline uint32_t get32(const uint8_t *p) {
  return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24;
}
inline size_t encode(uint8_t type, const uint8_t *payload, uint8_t *out) {
  const size_t n = payloadLength(type);
  if (!n) return 0;
  uint8_t body[MAX_BODY] = {VERSION, type};
  memcpy(body + 2, payload, n);
  const uint16_t crc = crc16(body, n + 2);
  body[n + 2] = (uint8_t)crc;
  body[n + 3] = (uint8_t)(crc >> 8);
  size_t cursor = 0;
  out[cursor++] = END;
  for (size_t i = 0; i < n + 4; ++i) {
    if (body[i] == END || body[i] == ESC) {
      out[cursor++] = ESC;
      out[cursor++] = body[i] == END ? ESC_END : ESC_ESC;
    } else out[cursor++] = body[i];
  }
  out[cursor++] = END;
  return cursor;
}

struct Parser {
  uint8_t body[MAX_BODY] = {};
  size_t used = 0;
  bool escape = false, rejected = false;
  uint32_t dropped = 0;
  bool push(uint8_t byte, uint8_t &type, const uint8_t *&payload) {
    if (byte == END) {
      bool valid = !escape && !rejected && used >= 4 && body[0] == VERSION &&
                   payloadLength(body[1]) && used == payloadLength(body[1]) + 4;
      if (valid) valid = crc16(body, used - 2) == (uint16_t)(body[used - 2] | (uint16_t)body[used - 1] << 8);
      if (valid) { type = body[1]; payload = body + 2; }
      else if (used || escape || rejected) ++dropped;
      used = 0; escape = rejected = false;
      return valid;
    }
    if (rejected) return false;
    if (escape) {
      escape = false;
      if (byte == ESC_END) byte = END;
      else if (byte == ESC_ESC) byte = ESC;
      else { rejected = true; return false; }
    } else if (byte == ESC) { escape = true; return false; }
    if (used == MAX_BODY) { rejected = true; return false; }
    body[used++] = byte;
    return false;
  }
};

struct InputDelta {
  int32_t detents = 0;
  uint32_t edges = 0;
  bool reset = false, pressed = false;
};
struct InputTracker {
  bool live = false, pressed = false;
  uint32_t session = 0, count = 0, edges = 0, lastMs = 0;
  InputDelta accept(const uint8_t *p, uint32_t now) {
    const uint32_t nextSession = get32(p), nextCount = get32(p + 4), nextEdges = get32(p + 8);
    InputDelta result;
    result.pressed = (nextEdges & 1) != 0;
    if (!live || nextSession != session || (uint32_t)(now - lastMs) >= TIMEOUT_MS) {
      result.reset = true;
    } else {
      const uint32_t difference = nextCount - count;
      // Do not cast an out-of-range unsigned value to signed. Counts wrap.
      result.detents = difference <= INT32_MAX ? (int32_t)difference : -(int32_t)(~difference) - 1;
      result.edges = nextEdges - edges;
      // A physical encoder cannot move this far inside the 500 ms lease.
      // Corruption/restart must not become a long burst of phantom actions.
      if (result.detents > 256 || result.detents < -256 || result.edges > 32) {
        result.detents = 0; result.edges = 0; result.reset = true;
      }
    }
    session = nextSession; count = nextCount; edges = nextEdges; pressed = result.pressed;
    live = true; lastMs = now;
    return result;
  }
  bool expire(uint32_t now) {
    if (!live || (uint32_t)(now - lastMs) < TIMEOUT_MS) return false;
    live = false; pressed = false;
    return true;
  }
};
}  // namespace ring_link
