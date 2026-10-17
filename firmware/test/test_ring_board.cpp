// The ring carrier's XIAO sketch on the host: the 35-pixel comet, breathe,
// gain arc and current limit, driven through the ring link exactly as the
// console sends it, and the encoder/button counters it reports back.
#include <cassert>
#include <cstdio>

#include "../ring_board/ring_board.ino"

static void at(uint32_t now) {
  fake_arduino::now = now;
  loop();
}

static void send(ring_link::RingState state, uint32_t now, bool corrupt = false) {
  uint8_t payload[ring_link::STATE_LEN], packet[ring_link::MAX_FRAME];
  ring_link::encodeState(state, payload);
  const size_t size = ring_link::encode(ring_link::STATE, payload, packet);
  if (corrupt) packet[size - 2] ^= 1;
  for (size_t i = 0; i < size; ++i) ringLink.received.push_back(packet[i]);
  at(now);
}

// The console resends the state every 100 ms; hold it there while time passes.
static void hold(ring_link::RingState state, uint32_t &now, uint32_t duration) {
  for (uint32_t step = 0; step < duration; step += 50) send(state, now += 50);
}

static ring_link::RingState live(Rgb c = {0, 0, 0}, uint8_t gain = 0, uint8_t flags = 0) {
  ring_link::RingState s;
  s.r = c.r; s.g = c.g; s.b = c.b; s.gain = gain;
  s.flags = ring_link::FLAG_LIVE | flags;
  return s;
}

static uint32_t shown(unsigned i) { return ring.getPixelColor(i); }

static uint32_t channelTotal() {
  uint32_t total = 0;
  for (unsigned i = 0; i < RING_N; ++i) {
    const uint32_t p = shown(i);
    total += (p >> 16) + ((p >> 8) & 255) + (p & 255);
  }
  return total;
}

static void expectDark() {
  for (unsigned i = 0; i < RING_N; ++i) assert(shown(i) == 0);
}

// The approved 40-pixel profile on 35 pixels: the two-pixel lead at 192, never
// brightening toward the tail, the first ~40 % at half the peak or more, and
// the last quarter of the ring dark.
static void cometProfile() {
  assert(RING_N == 35);
  assert(g_cometDuty[0] == 192 && g_cometDuty[1] == 192);
  for (unsigned i = 1; i < RING_N; ++i) assert(g_cometDuty[i] <= g_cometDuty[i - 1]);
  for (unsigned i = 0; i <= 14; ++i) assert(g_cometDuty[i] >= 96);
  for (unsigned i = 27; i < RING_N; ++i) assert(g_cometDuty[i] == 0);
  assert(g_cometDuty[26] > 0 && g_cometDuty[26] <= 2);  // the tail eases out
}

// Inspect transmitted duty: a second gamma pass would shorten the tail.
static void cometOutput() {
  g_ringPhase = 0;
  paintComet({0, 255, 0});
  showRing();
  assert(shown(0) == (192U << 8) && shown(RING_N - 1) == (192U << 8));
  for (unsigned behind = 0; behind < RING_N; ++behind) {
    const uint32_t p = shown((RING_N - behind) % RING_N);
    assert((p & 0xff00ff) == 0 && ((p >> 8) & 255) == g_cometDuty[behind]);
  }
  // A fractional phase blends neighbouring frames, including across the seam.
  g_ringPhase = RING_N - 0.5f;
  paintComet({0, 255, 0});
  showRing();
  assert(((shown(0) >> 8) & 255) == (192U + 0U + 1) / 2);
  // The weaker yellow channel survives to the tail with one gamma pass.
  g_ringPhase = 0;
  paintComet(Rgb{255, 235, 0});
  showRing();
  const unsigned yellowGreen = Adafruit_NeoPixel::gamma8(235);
  for (unsigned behind = 0; behind < 26; ++behind) {
    const uint32_t p = shown((RING_N - behind) % RING_N);
    const unsigned red = p >> 16, green = (p >> 8) & 255;
    assert(red > 0 && green == (red * yellowGreen + 127) / 255 && (p & 255) == 0);
  }
  // A white comet fits the budget at every quarter-pixel phase, undimmed.
  for (unsigned quarter = 0; quarter < RING_N * 4; ++quarter) {
    g_ringPhase = quarter / 4.0f;
    paintComet({255, 255, 255});
    uint32_t requested[RING_N];
    for (unsigned i = 0; i < RING_N; ++i) requested[i] = g_pixels[i];
    showRing();
    for (unsigned i = 0; i < RING_N; ++i) assert(shown(i) == requested[i]);
    assert(channelTotal() <= RING_CHANNEL_BUDGET);
  }
  // An over-budget frame is scaled uniformly to the ceiling.
  for (unsigned i = 0; i < RING_N; ++i) g_pixels[i] = 0xffffff;
  showRing();
  for (unsigned i = 0; i < RING_N; ++i) assert(shown(i) == 0x606060);
  assert(channelTotal() == RING_CHANNEL_BUDGET);
}

static void lifecycle() {
  uint32_t now = 100000;
  at(now);
  expectDark();  // nothing from the console yet

  // Standby breathes green at the ambient level and never goes black.
  send(live(), now += 20);
  unsigned lowest = 255, highest = 0;
  now = 120000;  // an exact breathe-cycle boundary
  for (unsigned tick = 0; tick <= 60; ++tick) {
    send(live(), now += 20);
    assert(g_ringView == RING_BREATHE);
    const unsigned green = (shown(0) >> 8) & 255;
    assert(green > 0 && green <= 96);
    if (green < lowest) lowest = green;
    if (green > highest) highest = green;
    for (unsigned i = 0; i < RING_N; ++i) assert(shown(i) == (green << 8));
  }
  assert(highest == 96 && lowest < 16);

  // Activity: one revolution every 1100 ms.
  const Rgb amber = {255, 235, 0};
  const auto playingState = live(amber, 0, ring_link::FLAG_ACTIVE | ring_link::FLAG_LOADED);
  send(playingState, now += 20);
  g_ringPhase = 0;
  g_ringLastMs = now;
  hold(playingState, now, 550);
  assert(g_ringView == RING_COMET && std::fabs(g_ringPhase - RING_N / 2.0f) < 0.01f);
  hold(playingState, now, 550);
  assert(std::fabs(g_ringPhase) < 0.01f || std::fabs(g_ringPhase - RING_N) < 0.01f);
  send(playingState, now += 20);
  uint32_t playing[RING_N];
  for (unsigned i = 0; i < RING_N; ++i) playing[i] = shown(i);
  const float phase = g_ringPhase;

  // A Stop with a loop loaded freezes the comet, in the colour it played in.
  send(live({0, 0, 0}, 0, ring_link::FLAG_LOADED), now += 20);
  hold(live({0, 0, 0}, 0, ring_link::FLAG_LOADED), now, 200);
  assert(g_ringPhase == phase);
  for (unsigned i = 0; i < RING_N; ++i) assert(shown(i) == playing[i]);

  // A level change shows the arc for 900 ms, then the frozen comet returns.
  send(live({0, 0, 0}, 255, ring_link::FLAG_LOADED), now += 20);
  assert(g_ringView == RING_ARC);
  for (unsigned i = 0; i < RING_N; ++i) assert(shown(i) == (96U << 8));
  hold(live({0, 0, 0}, 255, ring_link::FLAG_LOADED), now, 850);
  assert(g_ringView == RING_ARC);
  hold(live({0, 0, 0}, 255, ring_link::FLAG_LOADED), now, 100);
  assert(g_ringView == RING_COMET && g_ringPhase == phase);
  send(live({0, 0, 0}, 128, ring_link::FLAG_LOADED), now += 20);
  const unsigned lit = (128 * RING_N + 254) / 255;
  for (unsigned i = 0; i < RING_N; ++i) assert(shown(i) == (i < lit ? (96U << 8) : 0));

  // Idle: the still arc drops to ~20 % on the next render, and comes back.
  const auto dimmedArc = live({0, 0, 0}, 128, ring_link::FLAG_LOADED | ring_link::FLAG_DIMMED);
  send(dimmedArc, now += 20);
  const uint32_t dimGreen = ring_link::dimChannel(96);
  assert(dimGreen == 19);
  for (unsigned i = 0; i < RING_N; ++i) assert(shown(i) == (i < lit ? (dimGreen << 8) : 0));
  send(live({0, 0, 0}, 128, ring_link::FLAG_LOADED), now += 20);
  for (unsigned i = 0; i < RING_N; ++i) assert(shown(i) == (i < lit ? (96U << 8) : 0));
  // A lit channel never dims to black.
  assert(ring_link::dimChannel(0) == 0 && ring_link::dimChannel(1) == 1 && ring_link::dimChannel(2) == 1);

  // Not live, a corrupt frame, or silence for 500 ms: dark.
  ring_link::RingState goodbye;
  send(goodbye, now += 1000);
  expectDark();
  send(live(), now += 20);
  assert(channelTotal() > 0);
  send(live(), now += 20, true);  // dropped; the last good one still holds
  assert(channelTotal() > 0 && g_parser.dropped == 1);
  at(now += 600);
  expectDark();
}

static uint32_t lastSnapshot(int index) {
  ring_link::Parser parser;
  uint32_t value = 0;
  for (const auto &frame : ringLink.sent) {
    for (const uint8_t byte : frame) {
      uint8_t type;
      const uint8_t *payload;
      if (parser.push(byte, type, payload) && type == ring_link::INPUT_STATE)
        value = ring_link::get32(payload + index * 4);
    }
  }
  assert(parser.dropped == 0);
  return value;
}

static void turn(int clicks) {
  // ACZ11 clockwise: 11 -> 01 -> 00 -> 10 -> 11, A as the high bit.
  static const uint8_t cw[4] = {1, 0, 2, 3}, ccw[4] = {2, 0, 1, 3};
  for (int c = 0; c < (clicks < 0 ? -clicks : clicks); ++c) {
    for (const uint8_t state : clicks > 0 ? cw : ccw) {
      fake_arduino::digital[PIN_ENC_A] = state >> 1;
      fake_arduino::digital[PIN_ENC_B] = state & 1;
      encoderSample();
    }
  }
}

static void inputSnapshots() {
  uint32_t now = 300000;
  ringLink.sent.clear();
  at(now += 20);
  const uint32_t start = lastSnapshot(1);
  assert(lastSnapshot(0) == rp2040.nonce);
  turn(3);
  at(now += 20);
  assert(lastSnapshot(1) == start + 3);
  turn(-5);
  at(now += 20);
  assert(lastSnapshot(1) == start - 2);
  // A half click, reversed by contact bounce, counts nothing.
  fake_arduino::digital[PIN_ENC_A] = 0;
  encoderSample();
  fake_arduino::digital[PIN_ENC_A] = 1;
  encoderSample();
  at(now += 20);
  assert(lastSnapshot(1) == start - 2);
  // The button: an edge counts once it has held for 8 ms; odd means pressed.
  const uint32_t edges = lastSnapshot(2);
  fake_arduino::digital[PIN_ENC_SW] = LOW;
  at(now += 4);
  at(now += 10);
  at(now += 20);
  assert(lastSnapshot(2) == edges + 1);
  fake_arduino::digital[PIN_ENC_SW] = HIGH;
  at(now += 4);
  at(now += 10);
  at(now += 20);
  assert(lastSnapshot(2) == edges + 2);
}

int main() {
  fake_arduino::digital[PIN_ENC_A] = fake_arduino::digital[PIN_ENC_B] = HIGH;
  fake_arduino::digital[PIN_ENC_SW] = HIGH;
  setup();
  cometProfile();
  cometOutput();
  lifecycle();
  inputSnapshots();
  std::puts("Ring carrier: 35-pixel comet, breathe, gain arc, limit, dimming, lifecycle and input snapshots: ALL PASSED");
}
