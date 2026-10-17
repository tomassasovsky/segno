// The console sketch's ring-update bridge (#1342): RING_BRIDGE from the Pi
// turns the board into a byte pipe between the Pi's UART and the ring's, with
// the panel dark and nothing of its own on the wire, until BRIDGE_END or 5 s
// of silence from the Pi.
#include <cassert>
#include <cstdio>
#include <vector>

#include "../console_board/console_board.ino"

static void at(uint32_t now) {
  fake_arduino::now = now;
  loop();
}

static std::vector<uint8_t> flatten(std::vector<std::vector<uint8_t>> &chunks) {
  std::vector<uint8_t> out;
  for (const auto &c : chunks) out.insert(out.end(), c.begin(), c.end());
  chunks.clear();
  return out;
}

static void fromPi(const uint8_t *bytes, size_t n) {
  for (size_t i = 0; i < n; ++i) fake_arduino::received.push_back(bytes[i]);
}

static std::vector<uint8_t> updateFrame(uint8_t type) {
  uint8_t out[RING_UPDATE_MAX_FRAME];
  return std::vector<uint8_t>(out, out + ring_update_encode(type, nullptr, 0, out));
}

static unsigned hellos(const std::vector<uint8_t> &bytes) {
  pedal_link_parser parser;
  pedal_link_parser_init(&parser);
  unsigned count = 0;
  for (const uint8_t b : bytes) {
    uint8_t type, len;
    const uint8_t *payload;
    if (pedal_link_parser_push(&parser, b, &type, &payload, &len) && type == PEDAL_LINK_TYPE_HELLO) ++count;
  }
  return count;
}

static void enter(uint32_t now, const std::vector<uint8_t> &after = {}) {
  uint8_t frame[PEDAL_LINK_MAX_FRAME];
  const size_t n = pedal_link_encode_ring_bridge(frame);
  fromPi(frame, n);
  fromPi(after.data(), after.size());
  at(now);
  assert(g_bridging);
}

int main() {
  fake_arduino::analog[26] = fake_arduino::analog[27] = 4095;
  setup();
  uint32_t now = 1000;
  at(now);
  fake_arduino::sent.clear();
  ringLink.sent.clear();

  // The bytes after RING_BRIDGE, in the same read, already belong to the ring.
  const std::vector<uint8_t> query = updateFrame(RING_UPDATE_QUERY);
  enter(now += 10, query);
  for (const uint32_t pixel : ind.shown) assert(pixel == 0);
  at(now += 1);
  assert(flatten(ringLink.sent) == query);

  // Both directions, byte for byte, and no HELLO or ring STATE of its own.
  const std::vector<uint8_t> big(3000, 0x5a);
  for (size_t i = 0; i < big.size(); i += 500) {
    fromPi(big.data() + i, 500);
    at(now += 400);  // well past the hello cadence, but never idle
  }
  assert(flatten(ringLink.sent) == big);
  for (const uint8_t b : {0xc0, 0xb5, 0x81, 0x01, 0xc0}) ringLink.received.push_back(b);
  at(now += 1);
  const std::vector<uint8_t> back = flatten(fake_arduino::sent);
  assert((back == std::vector<uint8_t>{0xc0, 0xb5, 0x81, 0x01, 0xc0}));
  assert(hellos(back) == 0);

  // BRIDGE_END reaches the ring too, then the board is itself again.
  const std::vector<uint8_t> end = updateFrame(RING_UPDATE_BRIDGE_END);
  fromPi(end.data(), end.size());
  at(now += 1);
  assert(!g_bridging);
  assert(flatten(ringLink.sent).size() >= end.size());
  assert(hellos(flatten(fake_arduino::sent)) == 1);

  // A Pi that goes quiet does not strand the board.
  enter(now += 10);
  at(now += BRIDGE_IDLE_MS - 1);
  assert(g_bridging);
  at(now += 2);
  assert(!g_bridging && hellos(flatten(fake_arduino::sent)) == 1);

  // The magic guards the bridge against a checksum-valid accident.
  const uint8_t wrong[2] = {'R', 'X'};
  uint8_t frame[PEDAL_LINK_MAX_FRAME];
  const size_t n = pedal_link_encode(PEDAL_LINK_TYPE_RING_BRIDGE, wrong, 2, frame);
  fromPi(frame, n);
  at(now += 10);
  assert(!g_bridging);

  std::puts("Console ring-update bridge: ALL PASSED");
}
