#include <cassert>
#include <cstdio>

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

// The Song queue (#1077): the queued switch's pill fills left to right by
// the app's progress, in the colour and activity the app gave it. No local
// clock moves it, and a queue never lights the whole pill.
static void songQueueFill() {
  const uint8_t level[8] = {28,69,151,191,191,151,69,28};
  pedal_state state = {};
  state.mode = PEDAL_MODE_PLAY;
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
      assert(green(2, pixel) == (level[pixel] * fill + 127) / 255);
      assert(green(3, pixel) == level[pixel]);  // the playing section: steady
    }
    // Time alone never advances the fill.
    const auto held = ind.shown;
    at(now += 400);
    assert(ind.shown == held);
  }
  // Half way, exactly the left half is lit.
  state.queued_progress = 127;
  receive(state, now += 20);
  for (unsigned pixel = 0; pixel < 8; ++pixel) assert((green(2, pixel) > 0) == (pixel < 4));
  // 254 leaves the rightmost pixel short of full.
  state.queued_progress = 254;
  receive(state, now += 20);
  assert(green(2, 7) < level[7] && green(2, 6) == level[6]);
  // The handoff: the engine's next frame has no queue and lights the section.
  state.queued_button = 0;
  state.queued_progress = 0;
  receive(state, now += 20);
  for (unsigned pixel = 0; pixel < 8; ++pixel) assert(green(2, pixel) == level[pixel]);
  // A queued switch the app does not light stays dark, whatever the progress.
  state.active_button_mask = 1u << PEDAL_BTN_TRACK1;
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
  ringStateForwarding();
  pdStatusFollowsHello();
  lateTrigger();
  puts("Console v3 ten pills, Song queue fill and ring state: all physical groups, host activity, limits, dimming, PD status and lifecycle pass");
}
