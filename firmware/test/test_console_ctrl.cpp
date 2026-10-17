#include <cstdio>
#include <cstdlib>

#include "../console_board/console_board.ino"

#define CHECK(condition, message) do { \
  if (!(condition)) { \
    std::fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, message); \
    std::exit(1); \
  } \
} while (0)

struct CtrlReading {
  uint8_t contact;
  uint8_t kind;
  uint8_t value;
};

static std::vector<CtrlReading> readings() {
  std::vector<CtrlReading> result;
  pedal_link_parser parser;
  pedal_link_parser_init(&parser);
  for (const auto &frame : fake_arduino::sent) {
    for (const auto byte : frame) {
      uint8_t type, length;
      const uint8_t *payload;
      if (!pedal_link_parser_push(&parser, byte, &type, &payload, &length)) continue;
      if (type == PEDAL_LINK_TYPE_CTRL && payload[0] == PEDAL_CTRL1) {
        CHECK(length == 4, "CTRL must carry four bytes");
        result.push_back({payload[1], payload[2], payload[3]});
      }
    }
  }
  CHECK(parser.dropped == 0, "the sketch must send valid frames");
  return result;
}

static void advance(unsigned long duration) {
  for (unsigned long elapsed = 0; elapsed < duration; elapsed += CTRL_SAMPLE_MS) {
    fake_arduino::now += CTRL_SAMPLE_MS;
    pollCtrl();
  }
}

static void bootAt(uint16_t raw) {
  fake_arduino::now = 0;
  fake_arduino::sent.clear();
  fake_arduino::analog[CTRL_PIN[0]] = raw;
  fake_arduino::analog[CTRL_PIN[1]] = CTRL_MAX;
  // Both jacks plugged: the ring-normal contact is open, the pull-down wins.
  fake_arduino::digital[CTRL_PRESENT_PIN[0]] = LOW;
  fake_arduino::digital[CTRL_PRESENT_PIN[1]] = LOW;
  g_ctrlLastSampleMs = 0;
  setup();
  advance(1000);
  fake_arduino::sent.clear();
}

static void testUnplugHoldsTheLastValue() {
  bootAt(2048);
  CHECK(g_ctrlKind[0] == CTRL_EXPRESSION, "mid-scale must identify an expression pedal");
  fake_arduino::analog[CTRL_PIN[0]] = CTRL_MAX;
  advance(300);  // Past the quiet period, still waiting to confirm detachment.
  CHECK(readings().empty(), "an unplug must not send full toe while detach is pending");
  advance(1200);
  const auto events = readings();
  CHECK(events.size() == 1, "an unplug must report NONE once, with no expression jump");
  CHECK(events[0].kind == PEDAL_CTRL_KIND_NONE, "the unplug must resolve to NONE");
  advance(2000);
  CHECK(readings().size() == 1, "an empty jack must stay quiet");
}

static void testOrdinaryToeTravelStillReportsFullScale() {
  bootAt(2048);
  for (uint16_t raw = 2304; raw < CTRL_MAX; raw += 256) {
    fake_arduino::analog[CTRL_PIN[0]] = raw;
    advance(20);
  }
  fake_arduino::analog[CTRL_PIN[0]] = CTRL_MAX;
  advance(2000);
  const auto events = readings();
  CHECK(!events.empty(), "a toe sweep must report movement");
  for (const auto &event : events) {
    CHECK(event.kind == PEDAL_CTRL_KIND_EXPRESSION, "normal toe travel must not detach");
  }
  CHECK(events.back().value == 255, "normal toe travel must reach full scale");
}

static void testMovementCancelsPendingDetach() {
  bootAt(2048);
  fake_arduino::analog[CTRL_PIN[0]] = CTRL_MAX;
  advance(600);
  CHECK(readings().empty(), "the candidate detach must hold its previous value");
  fake_arduino::analog[CTRL_PIN[0]] = 1400;
  advance(2000);
  const auto events = readings();
  CHECK(events.size() == 1, "movement must cancel detach and resume reporting");
  CHECK(events[0].kind == PEDAL_CTRL_KIND_EXPRESSION, "a moving pedal is still attached");
  CHECK(events[0].value == (1400 >> 4), "report the current raw position after settling");
}

static void testKnownSwitchEdgesRemainPrompt() {
  bootAt(CTRL_MAX);
  fake_arduino::analog[CTRL_PIN[0]] = 0;
  advance(20);
  auto events = readings();
  CHECK(events.size() == 1 && events[0].kind == PEDAL_CTRL_KIND_SWITCH &&
        events[0].value == 255, "an established switch must press within two samples");
  fake_arduino::analog[CTRL_PIN[0]] = CTRL_MAX;
  advance(20);
  events = readings();
  CHECK(events.size() == 2 && events[1].kind == PEDAL_CTRL_KIND_SWITCH &&
        events[1].value == 0, "an established switch must release within two samples");
}


static void testPresenceDetachHasNoSyntheticRelease() {
  bootAt(CTRL_MAX);
  fake_arduino::analog[CTRL_PIN[0]] = 0;
  fake_arduino::digital[CTRL_RING_PIN[0]] = LOW;
  advance(20);
  CHECK(g_ctrlSwitchClosed[0][PEDAL_CTRL_TIP] && g_ctrlSwitchClosed[0][PEDAL_CTRL_RING],
        "both contacts must be held before detach");
  fake_arduino::sent.clear();
  fake_arduino::analog[CTRL_PIN[0]] = CTRL_MAX;
  fake_arduino::digital[CTRL_RING_PIN[0]] = HIGH;
  fake_arduino::digital[CTRL_PRESENT_PIN[0]] = HIGH;
  advance(40);
  CHECK(readings().empty(), "raw absence must suppress open edges during presence debounce");
  advance(30);
  const auto events = readings();
  CHECK(events.size() == 1 && events[0].kind == PEDAL_CTRL_KIND_NONE,
        "detach sends one lifetime boundary, never SWITCH0");
  CHECK(!g_ctrlSwitchClosed[0][PEDAL_CTRL_TIP] && !g_ctrlSwitchClosed[0][PEDAL_CTRL_RING],
        "detach resets both contacts internally");
}

static void testReclassificationHasNoSyntheticRelease(bool ringOnly) {
  bootAt(CTRL_MAX);
  if (!ringOnly) fake_arduino::analog[CTRL_PIN[0]] = 0;
  fake_arduino::digital[CTRL_RING_PIN[0]] = LOW;
  advance(20);
  fake_arduino::sent.clear();
  fake_arduino::analog[CTRL_PIN[0]] = 2048;
  fake_arduino::digital[CTRL_RING_PIN[0]] = HIGH;
  advance(100);
  CHECK(readings().empty(), "midscale candidate cannot open a known switch");
  advance(500);
  const auto events = readings();
  CHECK(events.size() == 2, "reclassification sends lifetime boundary and expression only");
  CHECK(events[0].kind == PEDAL_CTRL_KIND_NONE && events[1].kind == PEDAL_CTRL_KIND_EXPRESSION,
        "NONE must precede expression even for ring-only prior switch");
}

// RP2350-E9: the presence pad's input buffer stays off between samples, which
// clears the leakage latch, so a plug is still seen after the empty jack held
// the pin high.
static void testPresenceReadKeepsTheInputBufferOff() {
  bootAt(CTRL_MAX);
  const uint8_t pin = CTRL_PRESENT_PIN[0];
  CHECK(fake_gpio::pulldown[pin] && !fake_gpio::enabled[pin],
        "presence must start pulled down with its input buffer off");
  const unsigned before = fake_gpio::reads;
  fake_arduino::digital[pin] = HIGH;  // jack emptied
  advance(100);
  CHECK(fake_gpio::reads > before && !fake_gpio::enabled[pin],
        "every sample must switch the input buffer back off");
  CHECK(!g_ctrlPresent[0], "a high presence pin is an empty jack");
  fake_arduino::digital[pin] = LOW;  // plug in: the contact opens
  advance(100);
  CHECK(g_ctrlPresent[0], "the latch must not hold an empty reading after a plug");
}

// The encoder lives on the ring carrier. Its cumulative snapshots become one
// ENCODER frame per click and one ENCODER_BUTTON frame per edge, as the v2
// board's own pins produced; a new session or a lapse replays nothing.
static void snapshot(uint32_t session, uint32_t clicks, uint32_t edges) {
  uint8_t payload[ring_link::INPUT_LEN], packet[ring_link::MAX_FRAME];
  ring_link::put32(payload, session);
  ring_link::put32(payload + 4, clicks);
  ring_link::put32(payload + 8, edges);
  const size_t size = ring_link::encode(ring_link::INPUT_STATE, payload, packet);
  for (size_t i = 0; i < size; ++i) ringLink.received.push_back(packet[i]);
  pollRing();
}

struct EncoderEvents {
  std::vector<int8_t> clicks;
  std::vector<uint8_t> button;
};

static EncoderEvents encoderEvents() {
  EncoderEvents result;
  pedal_link_parser parser;
  pedal_link_parser_init(&parser);
  for (const auto &frame : fake_arduino::sent) {
    for (const auto byte : frame) {
      uint8_t type, length;
      const uint8_t *payload;
      if (!pedal_link_parser_push(&parser, byte, &type, &payload, &length)) continue;
      if (type == PEDAL_LINK_TYPE_ENCODER) result.clicks.push_back((int8_t)payload[0]);
      if (type == PEDAL_LINK_TYPE_ENCODER_BUTTON) result.button.push_back(payload[0]);
    }
  }
  CHECK(parser.dropped == 0, "the sketch must send valid frames");
  return result;
}

static void testRingSnapshotsBecomeEncoderEvents() {
  bootAt(CTRL_MAX);
  snapshot(7, 1000, 0);  // the first snapshot only sets the baseline
  CHECK(encoderEvents().clicks.empty() && encoderEvents().button.empty(),
        "a baseline must not replay the counters");
  fake_arduino::now += 20;
  snapshot(7, 1003, 0);
  auto events = encoderEvents();
  CHECK(events.clicks.size() == 3 && events.clicks[0] == 1 && events.clicks[2] == 1,
        "three clockwise clicks must send three +1 frames");
  fake_arduino::sent.clear();
  fake_arduino::now += 20;
  snapshot(7, 1001, 2);  // two back, and a press and release between snapshots
  events = encoderEvents();
  CHECK(events.clicks.size() == 2 && events.clicks[0] == -1 && events.clicks[1] == -1,
        "counter-clockwise clicks must send -1 frames");
  CHECK(events.button.size() == 2 && events.button[0] == 1 && events.button[1] == 0,
        "a short press between snapshots must still report press and release");
  fake_arduino::sent.clear();
  fake_arduino::now += 20;
  snapshot(7, 1001, 3);  // held
  fake_arduino::now += 20;
  snapshot(9, 50, 0);  // the XIAO rebooted while the button was held
  events = encoderEvents();
  CHECK(events.clicks.empty(), "a new session must not replay clicks");
  CHECK(events.button.size() == 2 && events.button[0] == 1 && events.button[1] == 0,
        "a reboot must release a held button, once");
  fake_arduino::sent.clear();
  fake_arduino::now += 20;
  snapshot(9, 51, 1);
  fake_arduino::now += ring_link::TIMEOUT_MS + 1;
  pollRing();
  events = encoderEvents();
  CHECK(events.clicks.size() == 1 && events.button.size() == 2 && events.button[1] == 0,
        "a silent ring must release a held button");
}

int main() {
  testUnplugHoldsTheLastValue();
  testOrdinaryToeTravelStillReportsFullScale();
  testMovementCancelsPendingDetach();
  testKnownSwitchEdgesRemainPrompt();
  testPresenceDetachHasNoSyntheticRelease();
  testReclassificationHasNoSyntheticRelease(false);
  testReclassificationHasNoSyntheticRelease(true);
  testPresenceReadKeepsTheInputBufferOff();
  testRingSnapshotsBecomeEncoderEvents();
  std::puts("Console sketch CTRL tests: ALL PASSED");
}
