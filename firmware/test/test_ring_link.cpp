// The private ring link on its own: SLIP escaping, CRC and version checks,
// recovery after line noise, and the counter tracker's wrap and lease rules.
#include <cassert>
#include <cstdio>
#include <vector>

#include <ring_link.h>

static std::vector<uint8_t> frame(uint8_t type, const uint8_t *payload) {
  uint8_t out[ring_link::MAX_FRAME];
  return std::vector<uint8_t>(out, out + ring_link::encode(type, payload, out));
}

static bool parse(ring_link::Parser &parser, const std::vector<uint8_t> &bytes, uint8_t &type,
                  std::vector<uint8_t> &payload) {
  bool got = false;
  for (const uint8_t byte : bytes) {
    const uint8_t *p;
    if (parser.push(byte, type, p)) {
      payload.assign(p, p + ring_link::payloadLength(type));
      got = true;
    }
  }
  return got;
}

static void roundTripAndEscapes() {
  // Every byte that needs escaping, in a state and in a snapshot.
  ring_link::RingState s;
  s.r = ring_link::END; s.g = ring_link::ESC; s.b = 0; s.gain = 255; s.flags = 7;
  uint8_t payload[ring_link::STATE_LEN];
  ring_link::encodeState(s, payload);
  const auto bytes = frame(ring_link::STATE, payload);
  for (size_t i = 1; i + 1 < bytes.size(); ++i) assert(bytes[i] != ring_link::END);
  ring_link::Parser parser;
  uint8_t type = 0;
  std::vector<uint8_t> got;
  assert(parse(parser, bytes, type, got) && type == ring_link::STATE);
  const auto back = ring_link::decodeState(got.data());
  assert(back.r == s.r && back.g == s.g && back.b == s.b && back.gain == 255 && back.flags == 7);

  uint8_t input[ring_link::INPUT_LEN];
  ring_link::put32(input, 0xc0dbc0db);
  ring_link::put32(input + 4, 0xffffffff);
  ring_link::put32(input + 8, 3);
  assert(parse(parser, frame(ring_link::INPUT_STATE, input), type, got));
  assert(type == ring_link::INPUT_STATE && ring_link::get32(got.data()) == 0xc0dbc0db);
  assert(parser.dropped == 0);
}

static void rejectsAndRecovers() {
  ring_link::RingState s;
  uint8_t payload[ring_link::STATE_LEN];
  ring_link::encodeState(s, payload);
  const auto good = frame(ring_link::STATE, payload);
  ring_link::Parser parser;
  uint8_t type;
  std::vector<uint8_t> got;
  auto corrupt = good;
  corrupt[3] ^= 0x10;  // CRC mismatch
  assert(!parse(parser, corrupt, type, got) && parser.dropped == 1);
  auto version = good;
  version[1] = 2;  // the #1082 draft's version
  assert(!parse(parser, version, type, got) && parser.dropped == 2);
  std::vector<uint8_t> noise = {0x12, 0x34, ring_link::ESC, 0x00};
  noise.insert(noise.end(), good.begin(), good.end());
  assert(parse(parser, noise, type, got));  // the next END resynchronises

  // Firmware-update frames share the wire (ring_update.h). They are not ring
  // state and not noise either, however long they are.
  const uint32_t before = parser.dropped;
  std::vector<uint8_t> chunk(4 + RING_UPDATE_CHUNK, ring_link::END);
  uint8_t update[RING_UPDATE_MAX_FRAME];
  std::vector<uint8_t> traffic(update, update + ring_update_encode(RING_UPDATE_DATA, chunk.data(), chunk.size(), update));
  traffic.insert(traffic.end(), good.begin(), good.end());
  got.clear();
  assert(parse(parser, traffic, type, got) && type == ring_link::STATE && parser.dropped == before);
}

static void trackerWrapsAndLeases() {
  ring_link::InputTracker tracker;
  uint8_t p[ring_link::INPUT_LEN];
  auto snap = [&](uint32_t session, uint32_t count, uint32_t edges, uint32_t now) {
    ring_link::put32(p, session);
    ring_link::put32(p + 4, count);
    ring_link::put32(p + 8, edges);
    return tracker.accept(p, now);
  };
  assert(snap(1, 0xfffffffe, 0, 0).reset);
  auto d = snap(1, 1, 0, 20);  // wraps forward by three
  assert(!d.reset && d.detents == 3);
  d = snap(1, 0xffffffff, 0, 40);  // back by two across the wrap
  assert(!d.reset && d.detents == -2);
  d = snap(1, 0xffffffff + 1000u, 0, 60);  // impossible inside one lease
  assert(d.reset && d.detents == 0);
  d = snap(1, 999, 1, 60 + ring_link::TIMEOUT_MS);  // lapsed lease
  assert(d.reset && d.pressed);
  assert(!tracker.expire(60 + ring_link::TIMEOUT_MS + 10));
  assert(tracker.expire(60 + 2 * ring_link::TIMEOUT_MS));
}

int main() {
  roundTripAndEscapes();
  rejectsAndRecovers();
  trackerWrapsAndLeases();
  std::puts("Ring link v3 framing, recovery and counters: ALL PASSED");
}
