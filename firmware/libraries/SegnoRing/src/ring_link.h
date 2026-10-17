#pragma once
#include <stddef.h>
#include <stdint.h>
#include <string.h>

#include "ring_frame.h"
#include "ring_update.h"

// The private UART between the console board's Pico (GP13 TX / GP14 RX) and the
// ring carrier's XIAO RP2350 (D9 RX / D10 TX). SLIP framing (RFC 1055),
// CRC-16/CCITT-FALSE, version 3.
//
// The ring renders from a five-byte STATE the console derives from each app
// frame, not from the app's pedal-link frame itself, so a pedal-link protocol
// change never needs the ring reflashed. INPUT_STATE carries the boot nonce, a
// cumulative detent count and a cumulative button edge count (LE32 each):
// counter snapshots recover dropped short presses as well as missing detents.
// Framing is ring_frame.h's. Firmware updates share the wire on their own
// channel (ring_update.h); the parser here skips those frames without
// counting them as noise.
namespace ring_link {
constexpr uint8_t VERSION = 3, STATE = 1, INPUT_STATE = 2;
constexpr uint8_t END = RING_FRAME_END, ESC = RING_FRAME_ESC;
constexpr uint8_t ESC_END = RING_FRAME_ESC_END, ESC_ESC = RING_FRAME_ESC_ESC;
constexpr size_t STATE_LEN = 5, INPUT_LEN = 12;
constexpr size_t MAX_PAYLOAD = INPUT_LEN, MAX_BODY = MAX_PAYLOAD + 4;
constexpr size_t MAX_FRAME = RING_FRAME_ENCODED_MAX(MAX_BODY - 2);
constexpr uint32_t SNAPSHOT_MS = 20, STATE_MS = 100, TIMEOUT_MS = 500;

// STATE flags. LIVE: the app is connected and has not said goodbye; without it
// the ring goes dark. ACTIVE: the transport is doing something worth a comet.
// LOADED: a loop exists, so a stopped transport freezes the comet in place.
// DIMMED: the console idled and the screens dimmed; the ring dims with them
// (#1349). A ring firmware that predates it ignores the bit.
constexpr uint8_t FLAG_LIVE = 1, FLAG_ACTIVE = 2, FLAG_LOADED = 4, FLAG_DIMMED = 8;
// The share of normal output the console's LEDs keep while dimmed: ~20 %. A
// lit channel stays at least 1, so a dimmed breathe never reaches black and a
// faint hue component does not vanish.
constexpr uint8_t DIM_LEVEL = 51;
inline uint8_t dimChannel(uint8_t value) {
  if (!value) return 0;
  const uint8_t dimmed = (uint8_t)((value * DIM_LEVEL + 127) / 255);
  return dimmed ? dimmed : 1;
}

struct RingState {
  uint8_t r = 0, g = 0, b = 0;  // the activity colour, black when none
  uint8_t gain = 0;             // master level, 0..255
  uint8_t flags = 0;
};

inline void encodeState(const RingState &s, uint8_t *p) {
  p[0] = s.r; p[1] = s.g; p[2] = s.b; p[3] = s.gain; p[4] = s.flags;
}
inline RingState decodeState(const uint8_t *p) {
  RingState s;
  s.r = p[0]; s.g = p[1]; s.b = p[2]; s.gain = p[3]; s.flags = p[4];
  return s;
}

inline uint16_t crc16(const uint8_t *p, size_t length) { return ring_frame_crc16(p, length); }
inline size_t payloadLength(uint8_t type) {
  return type == STATE ? STATE_LEN : type == INPUT_STATE ? INPUT_LEN : 0;
}
inline void put32(uint8_t *p, uint32_t value) {
  for (uint8_t i = 0; i < 4; ++i) p[i] = (uint8_t)(value >> (8 * i));
}
inline uint32_t get32(const uint8_t *p) {
  return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24;
}
inline size_t encode(uint8_t type, const uint8_t *payload, uint8_t *out) {
  const size_t n = payloadLength(type);
  if (!n) return 0;
  uint8_t body[MAX_BODY - 2] = {VERSION, type};
  memcpy(body + 2, payload, n);
  return ring_frame_encode(body, n + 2, out);
}

struct Parser {
  uint8_t body[MAX_BODY] = {};
  size_t used = 0;
  bool escape = false, rejected = false, update = false;
  uint32_t dropped = 0;
  bool push(uint8_t byte, uint8_t &type, const uint8_t *&payload) {
    if (byte == END) {
      bool valid = !update && !escape && !rejected && used >= 4 && body[0] == VERSION &&
                   payloadLength(body[1]) && used == payloadLength(body[1]) + 4;
      if (valid) valid = crc16(body, used - 2) == (uint16_t)(body[used - 2] | (uint16_t)body[used - 1] << 8);
      if (valid) { type = body[1]; payload = body + 2; }
      else if (!update && (used || escape || rejected)) ++dropped;
      used = 0; escape = rejected = update = false;
      return valid;
    }
    if (update || rejected) return false;
    if (escape) {
      escape = false;
      if (byte == ESC_END) byte = END;
      else if (byte == ESC_ESC) byte = ESC;
      else { rejected = true; return false; }
    } else if (byte == ESC) { escape = true; return false; }
    // An update-channel frame is someone else's message, not line noise.
    if (used == 0 && byte == RING_UPDATE_CHANNEL) { update = true; return false; }
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
// Console side: turns cumulative snapshots into the clicks and edges since the
// last one. A new session, a 500 ms gap or an implausible jump resets the
// baseline instead of replaying turns.
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
