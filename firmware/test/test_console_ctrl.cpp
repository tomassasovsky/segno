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

// The encoder's push switch: one ENCODER_BUTTON frame per edge that holds for
// DEBOUNCE_MS, nothing for a bounce shorter than that.
static std::vector<uint8_t> encoderButtonEdges() {
  std::vector<uint8_t> result;
  pedal_link_parser parser;
  pedal_link_parser_init(&parser);
  for (const auto &frame : fake_arduino::sent) {
    for (const auto byte : frame) {
      uint8_t type, length;
      const uint8_t *payload;
      if (!pedal_link_parser_push(&parser, byte, &type, &payload, &length)) continue;
      if (type == PEDAL_LINK_TYPE_ENCODER_BUTTON) result.push_back(payload[0]);
    }
  }
  CHECK(parser.dropped == 0, "the sketch must send valid frames");
  return result;
}

static void holdEncoderSwitch(int level, unsigned long duration) {
  fake_arduino::digital[PIN_ENC_SW] = level;
  for (unsigned long elapsed = 0; elapsed < duration; elapsed++) {
    fake_arduino::now++;
    pollEncoderButton();
  }
}

static void testEncoderSwitchIsDebounced() {
  bootAt(CTRL_MAX);
  holdEncoderSwitch(HIGH, 20);
  CHECK(encoderButtonEdges().empty(), "an idle switch must stay quiet");
  holdEncoderSwitch(LOW, 3);  // a bounce
  holdEncoderSwitch(HIGH, 20);
  CHECK(encoderButtonEdges().empty(), "a bounce shorter than the debounce must not report");
  holdEncoderSwitch(LOW, DEBOUNCE_MS + 2);
  holdEncoderSwitch(LOW, 200);
  holdEncoderSwitch(HIGH, DEBOUNCE_MS + 2);
  const auto edges = encoderButtonEdges();
  CHECK(edges.size() == 2 && edges[0] == 1 && edges[1] == 0,
        "a press and a release must each report once");
}

int main() {
  testUnplugHoldsTheLastValue();
  testOrdinaryToeTravelStillReportsFullScale();
  testMovementCancelsPendingDetach();
  testKnownSwitchEdgesRemainPrompt();
  testPresenceDetachHasNoSyntheticRelease();
  testReclassificationHasNoSyntheticRelease(false);
  testReclassificationHasNoSyntheticRelease(true);
  testEncoderSwitchIsDebounced();
  std::puts("Console sketch CTRL tests: ALL PASSED");
}
