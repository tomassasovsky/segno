#include <cstdio>
#include <cstdlib>
#include <vector>
#include "ring_link.h"
#define CHECK(x, msg) do { if (!(x)) { std::fprintf(stderr, "FAIL %s:%d %s\n", __FILE__, __LINE__, msg); std::exit(1); } } while (0)
using namespace ring_link;
static std::vector<uint8_t> frame(uint8_t type, const uint8_t *payload) {
  uint8_t out[MAX_FRAME]; const auto n = encode(type, payload, out); return {out, out + n};
}
static int feed(Parser &p, const std::vector<uint8_t> &bytes) {
  uint8_t type; const uint8_t *payload; int count = 0;
  for (uint8_t byte : bytes) if (p.push(byte, type, payload)) ++count;
  return count;
}
static void framing() {
  CHECK(crc16((const uint8_t *)"123456789", 9) == 0x29b1, "published CCITT-FALSE check vector");
  uint8_t payload[PEDAL_LINK_STATE_LEN] = {};
  for (unsigned value = 0; value < 256; ++value) {
    for (unsigned i = 0; i < sizeof(payload); ++i) payload[i] = value + i;
    Parser parser;
    const auto packet = frame(STATE, payload);
    uint8_t type = 0; const uint8_t *decoded = nullptr; bool valid = false;
    for (uint8_t byte : packet) if (parser.push(byte, type, decoded)) valid = true;
    CHECK(valid && type == STATE && !memcmp(decoded, payload, sizeof(payload)), "escaped payload round trip");
  }
  const auto good = frame(STATE, payload);
  for (size_t i = 1; i + 1 < good.size(); ++i) {
    auto bad = good; bad[i] ^= 0x01;
    Parser parser;
    CHECK(feed(parser, bad) == 0, "single-byte corruption rejected");
    CHECK(feed(parser, good) == 1, "next complete frame recovers after corruption");
  }
  for (size_t cut = 1; cut < good.size(); ++cut) {
    Parser parser;
    feed(parser, {good.begin(), good.begin() + cut});
    CHECK(feed(parser, good) >= 1, "truncated message cannot eat next frame");
  }
  Parser parser;
  CHECK(!feed(parser, std::vector<uint8_t>(1000, 0x44)), "oversize discarded");
  CHECK(feed(parser, good) == 1, "oversize resynchronizes");
  CHECK(feed(parser, {END, ESC, 0x01, END}) == 0, "invalid SLIP escape rejected");
  // Captured previous-version wire shape: version 1, STATE, nineteen zero
  // bytes and its valid little-endian CRC 0xd79c. It must not be accepted as
  // the new state merely because its checksum is valid.
  std::vector<uint8_t> oldState(25, 0);
  oldState[0] = oldState[24] = END;
  oldState[1] = 1; oldState[2] = STATE;
  oldState[22] = 0x9c; oldState[23] = 0xd7;
  CHECK(!feed(parser, oldState), "old ring-link version is rejected");
  CHECK(feed(parser, good) == 1, "current ring-link state recovers after an old frame");
}
static void snapshot(uint8_t *p, uint32_t boot, uint32_t count, uint32_t edges) {
  put32(p, boot); put32(p + 4, count); put32(p + 8, edges);
}
static void recovery() {
  uint8_t p[12]; InputTracker input;
  snapshot(p, 1, 100, 0);
  CHECK(input.accept(p, 0).reset, "first connection establishes baseline without phantom turns");
  snapshot(p, 1, 103, 2);
  auto delta = input.accept(p, 80);
  CHECK(delta.detents == 3 && delta.edges == 2 && !delta.pressed, "lost snapshot still recovers short press and release");
  delta = input.accept(p, 100);
  CHECK(delta.detents == 0 && delta.edges == 0, "duplicate snapshot is idempotent");
  snapshot(p, 1, 101, 3);
  delta = input.accept(p, 120);
  CHECK(delta.detents == -2 && delta.pressed, "negative turns and held button");
  CHECK(!input.expire(619) && input.expire(620) && !input.pressed, "timeout releases held button");
  snapshot(p, 1, 170, 8);
  CHECK(input.accept(p, 650).reset, "reconnect ignores actions while disconnected");
  snapshot(p, 2, 0, 0);
  CHECK(input.accept(p, 670).reset, "ring reboot resets counters without volume jump");
  input = {}; snapshot(p, 3, UINT32_MAX, UINT32_MAX - 1);
  input.accept(p, UINT32_MAX - 20);
  snapshot(p, 3, 1, 0);
  delta = input.accept(p, 0);
  CHECK(delta.detents == 2 && delta.edges == 2, "counter and millisecond wrap");
  snapshot(p, 3, 0, 1);
  CHECK(input.accept(p, 20).detents == -1, "reverse movement across count zero");
  snapshot(p, 3, 5000, 1000);
  CHECK(input.accept(p, 40).reset, "implausible motion never becomes an event storm");
}
int main() { framing(); recovery(); std::puts("Ring framing and recovery: ALL PASSED"); }
