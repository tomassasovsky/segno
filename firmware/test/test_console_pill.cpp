#include <cassert>
#include <cstdio>
#include <cstdlib>
#include <utility>

#include "../console_board/console_board.ino"
#include "stusb4500_sim.h"

static void at(uint32_t now) {
  fake_arduino::now = now;
  loop();
}

static void receive(pedal_state state, uint32_t now, bool corrupt = false) {
  uint8_t bytes[PEDAL_LINK_MAX_FRAME];
  const size_t size = pedal_link_encode_state(&state, bytes);
  if (corrupt) bytes[size - 1] ^= 1;
  for (size_t i = 0; i < size; ++i) fake_arduino::received.push_back(bytes[i]);
  at(now);
}

static void expectAllDark() {
  assert(ind.shown.size() == 80);
  for (const uint32_t pixel : ind.shown) assert(pixel == 0);
}

static uint32_t channelTotal() {
  uint32_t sum = 0;
  for (const uint32_t pixel : ind.shown) {
    sum += (pixel >> 16) + ((pixel >> 8) & 255) + (pixel & 255);
  }
  return sum;
}

static void expectButtonEvent(uint8_t button, bool down) {
  pedal_link_parser parser;
  pedal_link_parser_init(&parser);
  unsigned events = 0;
  for (const auto &frame : fake_arduino::sent) {
    for (const uint8_t byte : frame) {
      uint8_t type, length;
      const uint8_t *payload;
      if (pedal_link_parser_push(&parser, byte, &type, &payload, &length) &&
          type == PEDAL_LINK_TYPE_BUTTON) {
        assert(length == 2 && payload[0] == button && payload[1] == down);
        ++events;
      }
    }
  }
  assert(events == 1 && parser.dropped == 0);
}

static void buttonEdge(uint8_t button, uint8_t pin, bool down, uint32_t &now) {
  fake_arduino::sent.clear();
  fake_arduino::digital[pin] = down ? LOW : HIGH;
  at(now += 20);
  assert(g_btnStable[button] != down);  // A raw edge is not yet a press.
  at(now += 20);
  assert(g_btnStable[button] == down);
  expectButtonEvent(button, down);
}

// The ring carrier gets the last ring state the console sent on GP13.
static ring_link::RingState lastRingState() {
  ring_link::Parser parser;
  ring_link::RingState state;
  bool any = false;
  for (const auto &frame : ringLink.sent) {
    for (const uint8_t byte : frame) {
      uint8_t type;
      const uint8_t *payload;
      if (parser.push(byte, type, payload) && type == ring_link::STATE) {
        state = ring_link::decodeState(payload);
        any = true;
      }
    }
  }
  assert(any && parser.dropped == 0);
  return state;
}

static void expectRingDark() { assert(!(lastRingState().flags & ring_link::FLAG_LIVE)); }

// What the ring needs from each app frame: the activity colour (yellow as
// calibrated, #1064), the level, and whether it is live, active and loaded.
static void ringStateForwarding() {
  uint32_t now = 400000;
  pedal_state state = {};
  state.global_color = PEDAL_GLOBAL_AMBER;
  state.master_gain = 200;
  state.loop_length_micros = 1000000;
  ringLink.sent.clear();
  receive(state, now += 20);
  auto ring = lastRingState();
  assert(ring.r == 255 && ring.g == 235 && ring.b == 0 && ring.gain == 200);
  assert(ring.flags == (ring_link::FLAG_LIVE | ring_link::FLAG_ACTIVE | ring_link::FLAG_LOADED));
  // Every frame is forwarded at once, so the gain arc follows without delay.
  state.master_gain = 201;
  ringLink.sent.clear();
  receive(state, now += 1);
  assert(lastRingState().gain == 201);
  // Blue is the record-armed hint: coloured, but no comet.
  state.global_color = PEDAL_GLOBAL_BLUE;
  receive(state, now += 20);
  ring = lastRingState();
  assert(ring.b == 255 && ring.flags == (ring_link::FLAG_LIVE | ring_link::FLAG_LOADED));
  // Stopped and empty: live only, so the ring breathes.
  state.global_color = PEDAL_GLOBAL_OFF;
  state.loop_length_micros = 0;
  receive(state, now += 20);
  assert(lastRingState().flags == ring_link::FLAG_LIVE);
  // Without frames the state still goes out every 100 ms, and goes dark when
  // the app is gone.
  ringLink.sent.clear();
  at(now += 120);
  assert(lastRingState().flags == ring_link::FLAG_LIVE);
  at(now += 5001);
  expectRingDark();
}

// Every HELLO is followed by the PD trigger's status (#1352). Nothing answers
// on this bus, so the board reports the trigger as not read, with no contract.
static void pdStatusFollowsHello() {
  fake_arduino::sent.clear();
  at(fake_arduino::now + PEDAL_LINK_HELLO_MS + 1);
  uint8_t want[PEDAL_LINK_MAX_FRAME];
  const size_t n = pedal_link_encode_pd_status(PEDAL_PD_PROFILE_NOT_READ, 0, 0, 0, 0, want);
  bool found = false;
  for (size_t i = 0; i + 1 < fake_arduino::sent.size(); ++i) {
    if (fake_arduino::sent[i][1] != PEDAL_LINK_TYPE_HELLO) continue;
    assert(fake_arduino::sent[i + 1] == std::vector<uint8_t>(want, want + n));
    found = true;
  }
  assert(found);
}

// The last LEVEL the console sent the ring, or -1 for none.
static int lastRingLevel() {
  ring_link::Parser parser;
  int level = -1;
  for (const auto &frame : ringLink.sent) {
    for (const uint8_t byte : frame) {
      uint8_t type;
      const uint8_t *payload;
      if (parser.push(byte, type, payload) && type == ring_link::LEVEL) level = payload[0];
    }
  }
  assert(parser.dropped == 0);
  return level;
}

static void receiveLedLevel(uint8_t level, uint32_t now) {
  uint8_t bytes[PEDAL_LINK_MAX_FRAME];
  const size_t size = pedal_link_encode_led_level(level, bytes);
  assert(size == 5);
  for (size_t i = 0; i < size; ++i) fake_arduino::received.push_back(bytes[i]);
  at(now);
}

// LED_LEVEL (#1564): the pills and the ring fade to the app's level, under
// the idle dim, and go back to full when the app's frames stop. Without one
// the board shows what it always has.
static void ledLevel() {
  uint32_t now = 600000;
  pedal_state state = {};
  state.master_gain = 255;
  state.active_button_mask = 1;
  state.pedal_colors[0] = {255, 0, 0};
  receive(state, now += 20);
  assert(ind.shown[59] == (191u << 16));
  ringLink.sent.clear();
  receiveLedLevel(128, now += 1);
  at(now += RENDER_MS);  // one render: one fade step, not a jump
  assert(ind.shown[59] == ((uint32_t)ring_link::scaleChannel(191, 255 - LED_FADE_STEP) << 16));
  assert(lastRingLevel() == 255 - LED_FADE_STEP);
  for (int i = 0; i < 60; ++i) at(now += RENDER_MS);
  assert(ind.shown[59] == ((uint32_t)ring_link::scaleChannel(191, 128) << 16));
  assert(lastRingLevel() == 128);
  // The idle dim applies on top of the level.
  state.dimmed = 1;
  receive(state, now += 20);
  assert(ind.shown[59] ==
         ((uint32_t)ring_link::dimChannel(ring_link::scaleChannel(191, 128)) << 16));
  state.dimmed = 0;
  receive(state, now += 20);
  // A level of 0 is refused and changes nothing.
  const uint8_t zero[] = {PEDAL_LINK_SYNC, PEDAL_LINK_TYPE_LED_LEVEL, 1, 0,
                          PEDAL_LINK_TYPE_LED_LEVEL ^ 1};
  for (const uint8_t byte : zero) fake_arduino::received.push_back(byte);
  for (int i = 0; i < 10; ++i) at(now += RENDER_MS);
  assert(ind.shown[59] == ((uint32_t)ring_link::scaleChannel(191, 128) << 16));
  // The app is gone: dark, and full again for whoever connects next.
  at(now += 5001);
  expectAllDark();
  receive(state, now += 20);
  assert(ind.shown[59] == (191u << 16));
  ringLink.sent.clear();
  at(now += 120);
  assert(lastRingLevel() == 255);
}

// The last AMBIENT the board sent, as {sensor, level}, or {-1, -1}.
static std::pair<int, int> lastAmbient() {
  pedal_link_parser parser;
  pedal_link_parser_init(&parser);
  std::pair<int, int> last = {-1, -1};
  for (const auto &frame : fake_arduino::sent) {
    for (const uint8_t byte : frame) {
      uint8_t type, length;
      const uint8_t *payload;
      if (!pedal_link_parser_push(&parser, byte, &type, &payload, &length) ||
          type != PEDAL_LINK_TYPE_AMBIENT) continue;
      pedal_ambient ambient;
      assert(pedal_link_decode_ambient(payload, length, &ambient));
      last = {ambient.sensor, ambient.level};
    }
  }
  assert(parser.dropped == 0);
  return last;
}

static void runFor(unsigned long duration) {
  const unsigned long end = fake_arduino::now + duration;
  while (fake_arduino::now < end) at(fake_arduino::now + 10);
}

// AMBIENT (#1564): nothing on J22 is reported as no sensor from the first
// hello on; a sensor plugged in is found by two probes and reported once it
// has a second of light. The probe's pulls never reach a sample.
static void ambientLight() {
  fake_arduino::floating[PIN_AMBIENT] = true;
  fake_arduino::now = 900000;
  setup();
  fake_arduino::sent.clear();
  runFor(PEDAL_LINK_HELLO_MS + 20);
  assert(lastAmbient() == std::make_pair((int)PEDAL_AMBIENT_NONE, 0));
  assert(!fake_arduino::pullUp[PIN_AMBIENT] || g_ambientPhase != AMBIENT_SAMPLING);

  // A lead with the sensor reading 300 counts, and the 2.2 k holding the
  // pull-up to about 170 counts above that.
  fake_arduino::floating[PIN_AMBIENT] = false;
  fake_arduino::analog[PIN_AMBIENT] = 300;
  fake_arduino::loaded[PIN_AMBIENT] = 170;
  runFor(2 * AMBIENT_PROBE_MS + 2 * PEDAL_LINK_HELLO_MS + 100);
  const auto reading = lastAmbient();
  assert(reading.first == PEDAL_AMBIENT_READING);
  assert(std::abs(reading.second - 132) <= 1);  // 16 * log2(300)

  // Pulled out again: two probes later, no sensor.
  fake_arduino::floating[PIN_AMBIENT] = true;
  fake_arduino::sent.clear();
  runFor(2 * AMBIENT_PROBE_MS + PEDAL_LINK_HELLO_MS + 100);
  assert(lastAmbient() == std::make_pair((int)PEDAL_AMBIENT_NONE, 0));
  fake_arduino::floating[PIN_AMBIENT] = false;
  fake_arduino::analog[PIN_AMBIENT] = 0;
  fake_arduino::loaded[PIN_AMBIENT] = 0;
}

// A trigger that was not answering is asked again only every tenth hello,
// and provisioned and reported once it answers (J23 seated after boot).
static int simWrite(uint8_t reg, const uint8_t *data, uint8_t len) {
  return stusb_sim::busWrite(nullptr, reg, data, len);
}
static int simRead(uint8_t reg, uint8_t *data, uint8_t len) {
  return stusb_sim::busRead(nullptr, reg, data, len);
}

static void lateTrigger() {
  pd_trigger_nvm blank = {}, provisioned;
  pd_trigger_apply_profile(blank, provisioned);
  stusb_sim::attachContract(provisioned, 0x400759D6u, 200);
  Wire.device = {simWrite, simRead};
  uint8_t want[PEDAL_LINK_MAX_FRAME];
  const size_t n = pedal_link_encode_pd_status(PEDAL_PD_PROFILE_MATCHES, 0, 20000, 4700, 4700, want);
  bool reported = false;
  unsigned hellos = 0;
  for (; hellos < PD_RETRY_HELLOS && !reported; ++hellos) {
    const int writesBefore = stusb_sim::chip.writes;
    fake_arduino::sent.clear();
    at(fake_arduino::now + PEDAL_LINK_HELLO_MS + 1);
    for (const auto &frame : fake_arduino::sent)
      if (frame == std::vector<uint8_t>(want, want + n)) reported = true;
    // Between retries the bus is left alone.
    if (!reported) assert(stusb_sim::chip.writes == writesBefore);
  }
  assert(reported && hellos <= PD_RETRY_HELLOS);
  assert(stusb_sim::chip.erased == 0);  // it already held the profile
  Wire.device = {};
}

// The Song queue (#1077, #1323): the queued switch's pill fills left to right
// by the app's progress, every filled pixel at one level, in the colour and
// activity the app gave it. No local clock moves the fill, and a queue never
// lights the whole pill. When the queue ends on a lit pill it blends to the
// diffused curve over 300 ms.
static void songQueueFill() {
  const uint8_t level[8] = {28,69,151,191,191,151,69,28};
  const unsigned uniform = 110;  // the mean of level[]
  unsigned sum = 0;
  for (const uint8_t l : level) sum += l;
  assert((sum + 4) / 8 == uniform);
  pedal_state state = {};
  state.mode = PEDAL_MODE_REC;
  state.looper_mode = PEDAL_LOOPER_SONG;
  state.master_gain = 255;
  for (auto &color : state.pedal_colors) color = {0,255,0};
  // Track 2 waits on bank A; track 1 plays. Track 2 is group 2, track 1 is
  // group 3 (physical harness order, PILL_BUTTON).
  state.active_button_mask = (1u << PEDAL_BTN_TRACK1) | (1u << PEDAL_BTN_TRACK2);
  state.queued_button = PEDAL_BTN_TRACK2 + 1;
  uint32_t now = 200000;
  // Pixel p is physical left to right; group < 8 enters from the right.
  auto green = [](unsigned group, unsigned pixel) {
    return (ind.shown[pillPixelIndex(group, pixel)] >> 8) & 255;
  };
  for (const unsigned progress : {0U, 1U, 32U, 127U, 128U, 200U, 254U}) {
    state.queued_progress = (uint8_t)progress;
    receive(state, now += 20);
    for (unsigned pixel = 0; pixel < 8; ++pixel) {
      const int coverage = (int)progress * 8 - (int)pixel * 255;
      const unsigned fill = coverage <= 0 ? 0 : coverage >= 255 ? 255 : coverage;
      assert(green(2, pixel) == (uniform * fill + 127) / 255);
      assert(green(3, pixel) == level[pixel]);  // the playing section: steady
    }
    // Time alone never advances the fill.
    const auto held = ind.shown;
    at(now += 400);
    assert(ind.shown == held);
  }
  // Half way, exactly the left half is lit, all at the same level.
  state.queued_progress = 127;
  receive(state, now += 20);
  for (unsigned pixel = 0; pixel < 8; ++pixel) {
    assert(green(2, pixel) == (pixel < 3 ? uniform : pixel == 3 ? (uniform * 251 + 127) / 255 : 0));
  }
  // 254 leaves the rightmost pixel short of full.
  state.queued_progress = 254;
  receive(state, now += 20);
  assert(green(2, 7) < uniform && green(2, 6) == uniform);
  const unsigned last = green(2, 7);
  // The handoff: the engine's next frame has no queue and lights the
  // section. The pill starts from its last fill and reaches the diffused
  // curve 300 ms later, moving monotonically in between.
  state.queued_button = 0;
  state.queued_progress = 0;
  const uint32_t start = now += 20;
  receive(state, start);
  for (unsigned pixel = 0; pixel < 7; ++pixel) assert(green(2, pixel) == uniform);
  assert(green(2, 7) == last);
  at(start + 150);
  for (unsigned pixel = 0; pixel < 8; ++pixel) {
    const unsigned from = pixel == 7 ? last : uniform;
    const unsigned to = level[pixel];
    const unsigned lo = from < to ? from : to, hi = from < to ? to : from;
    assert(green(2, pixel) >= lo && green(2, pixel) <= hi);
    if (from != to) assert(green(2, pixel) != from && green(2, pixel) != to);
  }
  at(start + 300);
  for (unsigned pixel = 0; pixel < 8; ++pixel) assert(green(2, pixel) == level[pixel]);
  const auto diffused = ind.shown;
  at(start + 1000);
  assert(ind.shown == diffused);
  // A pill that leaves the queue dark goes dark at once.
  state.queued_button = PEDAL_BTN_TRACK2 + 1;
  state.queued_progress = 200;
  receive(state, now = start + 1020);
  state.queued_button = 0;
  state.queued_progress = 0;
  state.active_button_mask = 1u << PEDAL_BTN_TRACK1;
  receive(state, now += 20);
  for (unsigned pixel = 0; pixel < 8; ++pixel) assert(ind.shown[pillPixelIndex(2, pixel)] == 0);
  // A queued switch the app does not light stays dark, whatever the progress.
  state.queued_button = PEDAL_BTN_TRACK2 + 1;
  state.queued_progress = 200;
  receive(state, now += 20);
  for (unsigned pixel = 0; pixel < 8; ++pixel) assert(ind.shown[pillPixelIndex(2, pixel)] == 0);
  // Goodbye and a lost link darken a queued pill like every other.
  state.active_button_mask = (1u << PEDAL_BTN_TRACK1) | (1u << PEDAL_BTN_TRACK2);
  state.goodbye = 1;
  receive(state, now += 20);
  expectAllDark();
  state.goodbye = 0;
  receive(state, now += 20);
  assert(green(2, 0) > 0);
  at(now += 5001);
  expectAllDark();
}

static void receiveClearHold(uint8_t button, uint8_t progress, uint32_t now) {
  uint8_t bytes[PEDAL_LINK_MAX_FRAME];
  const size_t size = pedal_link_encode_clear_hold(button, progress, bytes);
  assert(size == 6);
  for (size_t i = 0; i < size; ++i) fake_arduino::received.push_back(bytes[i]);
  at(now);
}

// A clear-track hold (#1534): red grows from both ends of the held pill toward
// the centre by the app's progress, at the fill level, over what the pill
// shows. It ends on a message with no button, when the messages stop, and with
// the frame; it never lights a pill the app leaves dark.
static void clearHoldFill() {
  const uint8_t level[8] = {28,69,151,191,191,151,69,28};
  const unsigned ink = 110;  // PILL_FILL_LEVEL, the red channel when covered
  pedal_state state = {};
  state.mode = PEDAL_MODE_REC;
  state.master_gain = 255;
  for (auto &color : state.pedal_colors) color = {0,255,0};
  // Track 2 is held (group 2), track 1 plays beside it (group 3).
  state.active_button_mask = (1u << PEDAL_BTN_TRACK1) | (1u << PEDAL_BTN_TRACK2);
  uint32_t now = 300000;
  receive(state, now += 20);
  auto red = [](unsigned group, unsigned pixel) {
    return ind.shown[pillPixelIndex(group, pixel)] >> 16;
  };
  auto green = [](unsigned group, unsigned pixel) {
    return (ind.shown[pillPixelIndex(group, pixel)] >> 8) & 255;
  };
  auto expectNormal = [&](unsigned group) {
    for (unsigned pixel = 0; pixel < 8; ++pixel) {
      assert(red(group, pixel) == 0 && green(group, pixel) == level[pixel]);
    }
  };
  expectNormal(2);
  for (const unsigned progress : {0U, 1U, 32U, 64U, 128U, 200U, 254U}) {
    receiveClearHold(PEDAL_BTN_TRACK2 + 1, (uint8_t)progress, now += 20);
    for (unsigned pixel = 0; pixel < 8; ++pixel) {
      const unsigned depth = pixel < 4 ? pixel : 7 - pixel;
      const int coverage = (int)progress * 4 - (int)depth * 255;
      const unsigned fill = coverage <= 0 ? 0 : coverage >= 255 ? 255 : coverage;
      assert(red(2, pixel) == (ink * fill + 127) / 255);
      assert(green(2, pixel) == (level[pixel] * (255 - fill) + 127) / 255);
      // Both ends move together.
      assert(ind.shown[pillPixelIndex(2, pixel)] == ind.shown[pillPixelIndex(2, 7 - pixel)]);
      assert(red(3, pixel) == 0 && green(3, pixel) == level[pixel]);  // the neighbour
    }
  }
  // Half way, exactly the two outer pairs are red and the centre is untouched.
  receiveClearHold(PEDAL_BTN_TRACK2 + 1, 128, now += 20);
  for (unsigned pixel = 0; pixel < 8; ++pixel) {
    const bool outer = pixel < 2 || pixel > 5;
    const bool centre = pixel == 3 || pixel == 4;
    if (outer) assert(red(2, pixel) == ink && green(2, pixel) == 0);
    if (centre) assert(red(2, pixel) == 0 && green(2, pixel) == level[pixel]);
  }
  // Released early: the next message has no button and the pill is back at
  // once.
  receiveClearHold(0, 0, now += 20);
  expectNormal(2);
  // A refused CLEAR_HOLD (progress without a button) changes nothing.
  receiveClearHold(PEDAL_BTN_TRACK2 + 1, 128, now += 20);
  const uint32_t last = now;
  const auto filled = ind.shown;
  const uint8_t bad[2] = {0, 1};
  uint8_t bytes[PEDAL_LINK_MAX_FRAME];
  const size_t size = pedal_link_encode(PEDAL_LINK_TYPE_CLEAR_HOLD, bad, 2, bytes);
  for (size_t i = 0; i < size; ++i) fake_arduino::received.push_back(bytes[i]);
  at(now += 20);
  assert(ind.shown == filled);
  // Messages that stop leave the fill for less than the stale time, then the
  // pill is back by itself: a lost settling message cannot leave it red.
  at(now = last + PEDAL_LINK_CLEAR_HOLD_STALE_MS - 20);
  assert(ind.shown == filled);
  at(now = last + PEDAL_LINK_CLEAR_HOLD_STALE_MS + 20);
  expectNormal(2);
  // A hold on a pill the app does not light stays dark.
  state.active_button_mask = 1u << PEDAL_BTN_TRACK1;
  receive(state, now += 20);
  receiveClearHold(PEDAL_BTN_TRACK2 + 1, 200, now += 20);
  for (unsigned pixel = 0; pixel < 8; ++pixel) assert(ind.shown[pillPixelIndex(2, pixel)] == 0);
  // The hold fired (255): the board flashes the full red pill
  // PILL_CLEAR_FLASHES times, PILL_CLEAR_FLASH_MS on and as long dark, on its
  // own clock. The app's no-button message, its next frame (the cleared track,
  // here dark) and the stale-fill time all pass without cutting it short;
  // then the frame decides the pill.
  state.active_button_mask = (1u << PEDAL_BTN_TRACK1) | (1u << PEDAL_BTN_TRACK2);
  receive(state, now += 20);
  auto expectFull = [&](unsigned group) {
    for (unsigned pixel = 0; pixel < 8; ++pixel) {
      assert(red(group, pixel) == ink && green(group, pixel) == 0);
    }
  };
  auto expectDarkPill = [&](unsigned group) {
    for (unsigned pixel = 0; pixel < 8; ++pixel) assert(ind.shown[pillPixelIndex(group, pixel)] == 0);
  };
  const uint32_t fired = now += 20;
  receiveClearHold(PEDAL_BTN_TRACK2 + 1, 255, fired);
  expectFull(2);
  receiveClearHold(0, 0, now += 20);
  state.active_button_mask = 1u << PEDAL_BTN_TRACK1;
  receive(state, now += 20);
  unsigned onSlots = 0, offSlots = 0;
  for (uint32_t t = now - fired; t < PILL_CLEAR_FLASH_TOTAL_MS; t += 20) {
    at(now = fired + t);
    const bool on = (t / PILL_CLEAR_FLASH_MS) % 2 == 0;
    if (on) expectFull(2), ++onSlots;
    else expectDarkPill(2), ++offSlots;
    assert(red(3, 0) == 0 && green(3, 0) == level[0]);  // the neighbour plays on
  }
  assert(onSlots > 0 && offSlots > 0);
  at(now = fired + PILL_CLEAR_FLASH_TOTAL_MS);
  expectDarkPill(2);  // the cleared track, as the frame says
  assert(!g_clearFlashing[PEDAL_BTN_TRACK2]);
  // A new hold on the flashing pill wins at once; one on another pill does
  // not stop the flash.
  state.active_button_mask = (1u << PEDAL_BTN_TRACK1) | (1u << PEDAL_BTN_TRACK2);
  receive(state, now += 20);
  receiveClearHold(PEDAL_BTN_TRACK2 + 1, 255, now += 20);
  receiveClearHold(PEDAL_BTN_TRACK1 + 1, 64, now += 20);
  expectFull(2);
  assert(red(3, 0) == ink && red(3, 3) == 0);  // track 1 fills beside it
  receiveClearHold(PEDAL_BTN_TRACK2 + 1, 64, now += 20);
  assert(!g_clearFlashing[PEDAL_BTN_TRACK2]);
  for (unsigned pixel = 0; pixel < 8; ++pixel) {
    const bool end = pixel == 0 || pixel == 7;
    assert(red(2, pixel) == (end ? ink : 0));
    assert(green(2, pixel) == (end ? 0 : level[pixel]));
  }
  receiveClearHold(0, 0, now += 20);
  expectNormal(2);
  // Goodbye ends a flash too.
  receiveClearHold(PEDAL_BTN_TRACK2 + 1, 255, now += 20);
  state.goodbye = 1;
  receive(state, now += 20);
  expectAllDark();
  state.goodbye = 0;
  receive(state, now += 20);
  assert(!g_clearFlashing[PEDAL_BTN_TRACK2]);
  expectNormal(2);
  // Goodbye darkens a filling pill like every other.
  state.active_button_mask = (1u << PEDAL_BTN_TRACK1) | (1u << PEDAL_BTN_TRACK2);
  receive(state, now += 20);
  receiveClearHold(PEDAL_BTN_TRACK2 + 1, 128, now += 20);
  state.goodbye = 1;
  receive(state, now += 20);
  expectAllDark();
  // ...and ends it: the next lit frame, inside the stale time, has no fill.
  state.goodbye = 0;
  receive(state, now += 20);
  expectNormal(2);
  // A stale fill is forgotten, not just hidden: a frame much later shows the
  // pill as the app lights it.
  receiveClearHold(PEDAL_BTN_TRACK2 + 1, 128, now += 20);
  at(now += PEDAL_LINK_CLEAR_HOLD_STALE_MS + 20);
  assert(g_clearHold.button == 0);
  expectNormal(2);
  // A lost link ends it as well.
  receiveClearHold(PEDAL_BTN_TRACK2 + 1, 128, now += 20);
  at(now += PEDAL_LINK_FRAME_TIMEOUT_MS + 1);
  expectAllDark();
  assert(g_clearHold.button == 0);
  receive(state, now += 20);
}

// The confirmation's shape is named and fixed: three flashes, 120 ms on and
// 120 ms dark, about 0.7 s.
static void clearFlashConstants() {
  static_assert(PILL_CLEAR_FLASHES == 3, "three flashes");
  static_assert(PILL_CLEAR_FLASH_MS == 120, "120 ms each way");
  static_assert(PILL_CLEAR_FLASH_TOTAL_MS == 720, "about 0.7 s in all");
  // The flash outlives the stale-fill time, so it must not hang on it.
  static_assert(PILL_CLEAR_FLASH_TOTAL_MS > PEDAL_LINK_CLEAR_HOLD_STALE_MS, "runs past the stale time");
  static_assert(PILL_CLEAR_UNDER_RED == 85, "about a third");
  assert(pillReadsRed({255, 0, 0}) && pillReadsRed({232, 93, 93}));
  assert(!pillReadsRed({255, 255, 255}) && !pillReadsRed({238, 136, 85}) &&
         !pillReadsRed({232, 93, 143}) && !pillReadsRed({100, 0, 0}) && !pillReadsRed({0, 255, 0}));
}

// A clear hold on a pill the app already shows red (#1534): while the hold
// runs, the pill's own red drops to about a third and the fill is drawn at
// full brightness from both ends; releasing early restores it at once, and a
// fired hold flashes as on any other pill.
static void clearHoldUnderRed() {
  const uint8_t level[8] = {28,69,151,191,191,151,69,28};
  pedal_state state = {};
  state.mode = PEDAL_MODE_REC;
  state.master_gain = 255;
  for (auto &color : state.pedal_colors) color = {0,255,0};
  state.pedal_colors[PEDAL_BTN_TRACK2] = {255,0,0};  // recording red
  state.active_button_mask = (1u << PEDAL_BTN_TRACK1) | (1u << PEDAL_BTN_TRACK2);
  uint32_t now = 500000;
  receive(state, now += 20);
  auto red = [](unsigned pixel) { return ind.shown[pillPixelIndex(2, pixel)] >> 16; };
  auto expectRecording = [&]() {
    for (unsigned pixel = 0; pixel < 8; ++pixel) {
      assert(ind.shown[pillPixelIndex(2, pixel)] == (uint32_t)level[pixel] << 16);
    }
  };
  expectRecording();
  for (const unsigned progress : {0U, 64U, 128U, 200U, 254U}) {
    receiveClearHold(PEDAL_BTN_TRACK2 + 1, (uint8_t)progress, now += 20);
    for (unsigned pixel = 0; pixel < 8; ++pixel) {
      const unsigned depth = pixel < 4 ? pixel : 7 - pixel;
      const int coverage = (int)progress * 4 - (int)depth * 255;
      const unsigned fill = coverage <= 0 ? 0 : coverage >= 255 ? 255 : coverage;
      const unsigned under = (level[pixel] * PILL_CLEAR_UNDER_RED + 127) / 255;
      assert(red(pixel) == (under * (255 - fill) + PILL_PEAK * fill + 127) / 255);
      assert((ind.shown[pillPixelIndex(2, pixel)] & 0xFFFF) == 0);
    }
  }
  // Half way: full-brightness ends, a centre at about a third of its level.
  receiveClearHold(PEDAL_BTN_TRACK2 + 1, 128, now += 20);
  assert(red(0) == PILL_PEAK && red(1) == PILL_PEAK);
  assert(red(3) == (191u * 85 + 127) / 255 && red(3) < level[3] / 2);
  // Released early: recording brightness at once.
  receiveClearHold(0, 0, now += 20);
  expectRecording();
  // A pill that is not red keeps its level under the usual fill.
  receiveClearHold(PEDAL_BTN_TRACK1 + 1, 128, now += 20);
  assert(((ind.shown[pillPixelIndex(3, 3)] >> 8) & 255) == level[3]);
  assert((ind.shown[pillPixelIndex(3, 0)] >> 16) == PILL_FILL_LEVEL);
  receiveClearHold(0, 0, now += 20);
  // A fired hold on the red pill flashes like any other, then the frame (the
  // cleared track, here no longer recording) decides it.
  receiveClearHold(PEDAL_BTN_TRACK2 + 1, 128, now += 20);
  const uint32_t fired = now += 20;
  receiveClearHold(PEDAL_BTN_TRACK2 + 1, 255, fired);
  for (unsigned pixel = 0; pixel < 8; ++pixel) assert(red(pixel) == PILL_FILL_LEVEL);
  at(now = fired + PILL_CLEAR_FLASH_MS + 20);
  for (unsigned pixel = 0; pixel < 8; ++pixel) assert(ind.shown[pillPixelIndex(2, pixel)] == 0);
  state.pedal_colors[PEDAL_BTN_TRACK2] = {255,255,255};
  receive(state, now += 20);
  at(now = fired + PILL_CLEAR_FLASH_TOTAL_MS);
  for (unsigned pixel = 0; pixel < 8; ++pixel) {
    assert(ind.shown[pillPixelIndex(2, pixel)] == ((uint32_t)level[pixel] * 0x010101u));
  }
}

// Each pill flashes on its own: a second hold firing on another pill does
// not cut the first flash short or a live fill elsewhere, and a pill the app
// does not light when the hold fires does not flash (#1534).
static void clearFlashPerPill() {
  const uint8_t level[8] = {28,69,151,191,191,151,69,28};
  const unsigned ink = PILL_FILL_LEVEL;
  pedal_state state = {};
  state.mode = PEDAL_MODE_REC;
  state.master_gain = 255;
  for (auto &color : state.pedal_colors) color = {0,255,0};
  state.active_button_mask = (1u << PEDAL_BTN_TRACK1) | (1u << PEDAL_BTN_TRACK2) |
                             (1u << PEDAL_BTN_TRACK3);
  uint32_t now = 700000;
  receive(state, now += 20);
  // Track 2 is group 2, track 1 group 3, track 3 group 1.
  auto red = [](unsigned group, unsigned pixel) {
    return ind.shown[pillPixelIndex(group, pixel)] >> 16;
  };
  const uint32_t first = now += 20;
  receiveClearHold(PEDAL_BTN_TRACK2 + 1, 255, first);
  receiveClearHold(PEDAL_BTN_TRACK3 + 1, 128, now += 20);  // a live fill
  receiveClearHold(PEDAL_BTN_TRACK1 + 1, 255, now += 20);  // a second fires
  assert(g_clearFlashing[PEDAL_BTN_TRACK2] && g_clearFlashing[PEDAL_BTN_TRACK1]);
  assert(g_clearHold.button == PEDAL_BTN_TRACK3 + 1);  // not wiped
  assert(red(1, 0) == ink && red(1, 3) == 0);
  // Both flash on their own clocks to the end of the first one's 720 ms.
  at(now = first + PILL_CLEAR_FLASH_TOTAL_MS - 20);
  assert(g_clearFlashing[PEDAL_BTN_TRACK2]);
  at(now = first + PILL_CLEAR_FLASH_TOTAL_MS);
  assert(!g_clearFlashing[PEDAL_BTN_TRACK2] && g_clearFlashing[PEDAL_BTN_TRACK1]);
  for (unsigned pixel = 0; pixel < 8; ++pixel) {
    assert(red(2, pixel) == 0 && ((ind.shown[pillPixelIndex(2, pixel)] >> 8) & 255) == level[pixel]);
  }
  at(now += 60);
  assert(!g_clearFlashing[PEDAL_BTN_TRACK1]);
  receiveClearHold(0, 0, now += 20);
  // A pill the app does not light when the hold fires does not flash.
  state.active_button_mask = 1u << PEDAL_BTN_TRACK1;
  receive(state, now += 20);
  receiveClearHold(PEDAL_BTN_TRACK2 + 1, 255, now += 20);
  assert(!g_clearFlashing[PEDAL_BTN_TRACK2]);
  for (unsigned pixel = 0; pixel < 8; ++pixel) assert(ind.shown[pillPixelIndex(2, pixel)] == 0);
}

int main() {
  fake_arduino::analog[26] = fake_arduino::analog[27] = 4095;
  setup();
  expectAllDark();
  const uint8_t buttons[10] = {7,6,5,4,3,2,1,0,8,9};
  const uint8_t bright[8] = {28,69,151,191,191,151,69,28};
  pedal_state state = {};
  state.mode = PEDAL_MODE_CUSTOM;
  state.master_gain = 255;
  uint32_t now = 1000;
  for (uint8_t button = 0; button < 10; ++button) {
    state.pedal_colors[button] = {255,0,0};
  }
  // Contradictory old semantic fields cannot light any physical indicator.
  state.clear_fade = 1;
  state.global_color = PEDAL_GLOBAL_RED;
  for (auto &led : state.track_leds) led = PEDAL_LED_BLUE;
  receive(state, now);
  expectAllDark();
  for (uint8_t bank = 0; bank < 2; ++bank) {
    state.active_bank = bank;
    for (uint8_t button = 0; button < 10; ++button) {
      state.active_button_mask = 1u << button;
      receive(state, now += 20);
      for (unsigned group = 0; group < 10; ++group) {
        for (unsigned pixel = 0; pixel < 8; ++pixel) {
          assert(ind.shown[group * 8 + pixel] ==
              (buttons[group] == button ? (uint32_t)bright[pixel] << 16 : 0));
        }
      }
    }
  }
  // Distinct high-byte and embedded-sync hues, preserving calibrated gamma.
  for (unsigned button = 0; button < 10; ++button) {
    state.pedal_colors[button] = {(uint8_t)(128 + button * 7), 165, 255};
  }
  state.active_button_mask = 0x201; // RecPlay and Bank, different mask bytes.
  receive(state, now += 20);
  for (unsigned group = 0; group < 10; ++group) {
    for (unsigned pixel = 0; pixel < 8; ++pixel) {
      uint32_t expected = 0;
      const unsigned button = buttons[group];
      if (button == 0 || button == 9) {
        const unsigned level = bright[pixel];
        expected = ((Adafruit_NeoPixel::gamma8(128 + button * 7) * level +127)/255)<<16 |
                   ((Adafruit_NeoPixel::gamma8(165) * level +127)/255)<<8 | level;
      }
      assert(ind.shown[group * 8 + pixel] == expected);
    }
  }
  // Asymmetric tags prove entry direction, independently of symmetric optics.
  for (unsigned group = 0; group < 10; ++group) {
    for (unsigned pixel = 0; pixel < 8; ++pixel) {
      assert(pillPixelIndex(group,pixel) == group * 8 + (group < 8 ? 7-pixel : pixel));
    }
  }
  state.active_button_mask = 0;
  receive(state, now += 20);
  buttonEdge(PEDAL_BTN_STOP,3,true,now);
  expectAllDark(); // Local contact sends an event, never invents acceptance.
  buttonEdge(PEDAL_BTN_UNDO,4,true,now);
  expectAllDark();
  buttonEdge(PEDAL_BTN_STOP,3,false,now);
  buttonEdge(PEDAL_BTN_UNDO,4,false,now);
  state.active_button_mask = 0x3ff;
  for (auto &color : state.pedal_colors) color = {255,255,255};
  receive(state, now += 20);
  assert(channelTotal() <= 6000 && channelTotal() > 5500);
  const auto limited = ind.shown;
  for (unsigned repeat = 0; repeat < 8; ++repeat) {
    receive(state, now += 100);
    assert(ind.shown == limited);
  }
  state.active_button_mask = 1;
  state.pedal_colors[0] = {255,0,0};
  receive(state, now += 20);
  assert(ind.shown[59] == (191u << 16));
  const auto sparse = ind.shown;
  const auto pushes = ind.showCount;
  at(now += 260);
  assert(ind.shown == sparse && ind.showCount > pushes);
  // Idle (#1349): the pills and the ring dim to ~20 % with the screens, and
  // come back on the next undimmed frame.
  state.dimmed = 1;
  receive(state, now += 20);
  assert(ind.shown[59] == ((uint32_t)ring_link::dimChannel(191) << 16));
  assert(lastRingState().flags & ring_link::FLAG_DIMMED);
  state.dimmed = 0;
  receive(state, now += 20);
  assert(ind.shown == sparse && !(lastRingState().flags & ring_link::FLAG_DIMMED));
  state.active_button_mask = 0x3ff;
  state.goodbye = 1;
  receive(state, now += 20);
  expectAllDark(); expectRingDark();
  state.goodbye = 0;
  receive(state, now += 20);
  at(now += 5001);
  expectAllDark(); expectRingDark();
  receive(state, now += 20, true);
  expectAllDark();
  receive(state, now += 20);
  for (unsigned group = 0; group < 10; ++group) assert(ind.shown[group*8+3]);
  songQueueFill();
  clearHoldFill();
  clearFlashConstants();
  clearHoldUnderRed();
  clearFlashPerPill();
  ringStateForwarding();
  pdStatusFollowsHello();
  lateTrigger();
  ledLevel();
  ambientLight();
  puts("Console v3 ten pills, Song queue fill, clear-hold fill and flash, ring state, LED level and light sensor: all physical groups, host activity, limits, dimming, PD status and lifecycle pass");
}
