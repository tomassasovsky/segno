#include <cassert>
#include <cstdio>

#include "../console_board/console_board.ino"

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

static uint32_t ringChannelTotal() {
  uint32_t total = 0;
  for (const uint32_t pixel : ring.shown) {
    total += (pixel >> 16) + ((pixel >> 8) & 255) + (pixel & 255);
  }
  return total;
}

static void expectRingDark() {
  for (const uint32_t pixel : ring.shown) assert(pixel == 0);
}

// The approved sustained profile, on the 40-pixel ring it was judged on.
static const unsigned APPROVED_40[40] = {
  192, 192, 180, 174, 168, 162, 156, 150, 144, 138,
  132, 126, 120, 114, 108, 102, 96, 89, 82, 74,
  66, 58, 50, 41, 33, 25, 18, 11, 6, 2,
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0
};

static void sustainedComet() {
  // The 34-pixel table is the approved 40-pixel profile at the same angles:
  // linear resampling, with the two-pixel lead kept at the peak.
  for (unsigned i = 0; i < RING_N; ++i) {
    const double x = i * 40.0 / RING_N;
    const unsigned k = (unsigned)x;
    const double f = x - k;
    unsigned expected = (unsigned)(APPROVED_40[k] * (1 - f) +
                                   APPROVED_40[(k + 1) % 40] * f + 0.5);
    if (i < 2) expected = 192;
    assert(COMET_DUTY[i] == expected);
  }

  // Inspect transmitted duty, not the profile constants: a second gamma pass
  // or a driver brightness reduction would visibly shorten the approved tail.
  g_ringPhase = 0;
  paintComet({0, 255, 0});
  showRing();
  const auto origin = ring.shown;
  assert(origin[0] == (192U << 8) && origin[33] == (192U << 8));
  unsigned lit = 0;
  unsigned previous = 192;
  for (unsigned behind = 0; behind < 34; ++behind) {
    const uint32_t pixel = origin[(34 - behind) % 34];
    const unsigned duty = (pixel >> 8) & 255;
    assert((pixel & 0xff00ff) == 0 && duty <= previous);
    // Half the peak or more over the first ~42% of the turn, as approved.
    if (behind <= 13) assert(duty >= 96);
    // The last quarter of the ring stays dark.
    if (behind >= 26) assert(duty == 0);
    if (duty) ++lit;
    previous = duty;
  }
  assert(lit == 26);  // 30 of 40 at the same angles
  assert(origin[9] == (1U << 8));  // The last lit tail pixel eases into black.

  // Increasing phase moves the bright leading edge toward increasing pixel
  // indices. Fractional positions blend the two neighboring complete frames,
  // including the wire-notch boundary between pixels 33 and 0.
  for (const unsigned base : {0U, 33U}) {
    g_ringPhase = (float)base;
    paintComet({0, 255, 0});
    showRing();
    const auto before = ring.shown;
    g_ringPhase = (float)((base + 1) % 34);
    paintComet({0, 255, 0});
    showRing();
    const auto after = ring.shown;
    assert(after[(base + 1) % 34] == (192U << 8));
    assert(before[(base + 1) % 34] == 0);
    for (unsigned quarter = 1; quarter < 4; ++quarter) {
      g_ringPhase = base + quarter / 4.0f;
      paintComet({0, 255, 0});
      showRing();
      for (unsigned pixel = 0; pixel < 34; ++pixel) {
        const unsigned a = (before[pixel] >> 8) & 255;
        const unsigned b = (after[pixel] >> 8) & 255;
        const unsigned expected = (a * (4 - quarter) + b * quarter + 2) / 4;
        assert(ring.shown[pixel] == (expected << 8));
      }
      assert(ring.shown[(base + 1) % 34] == ((48U * quarter) << 8));
    }
  }

  // The weaker yellow channel must survive all the way to the tail; dimming
  // changes duty without adding a second gamma pass or changing the hue.
  g_ringPhase = 0;
  paintComet(globalColor(PEDAL_GLOBAL_AMBER));
  showRing();
  const unsigned yellowGreen = Adafruit_NeoPixel::gamma8(235);
  for (unsigned behind = 0; behind < 26; ++behind) {
    const uint32_t pixel = ring.shown[(34 - behind) % 34];
    const unsigned red = pixel >> 16;
    const unsigned green = (pixel >> 8) & 255;
    assert(red > 0 && green <= red && (pixel & 255) == 0);
    assert(green == (red * yellowGreen + 127) / 255);
  }

  // Even a white comet stays below the ring's full-white ceiling at every
  // quarter-pixel phase; ordinary animations need no limiter dimming.
  assert(RING_CHANNEL_BUDGET == 34 * 3 * 96);
  for (unsigned quarter = 0; quarter < 136; ++quarter) {
    g_ringPhase = quarter / 4.0f;
    paintComet({255, 255, 255});
    const auto requested = ring.pixels;
    showRing();
    assert(ring.shown == requested);
    assert(ringChannelTotal() <= RING_CHANNEL_BUDGET);
  }

  // Deliberately over-budget frames exercise the actual transfer limiter.
  for (unsigned i = 0; i < 34; ++i) ring.setPixelColor(i, 0xffffff);
  showRing();
  for (const uint32_t pixel : ring.shown) assert(pixel == 0x606060);
  assert(ringChannelTotal() == RING_CHANNEL_BUDGET);
  const auto limited = ring.shown;
  showRing();
  assert(ring.shown == limited);  // Refreshing cannot repeatedly dim a frame.
  for (unsigned i = 0; i < 34; ++i) ring.setPixelColor(i, 0xff8040);
  showRing();
  assert(ringChannelTotal() <= RING_CHANNEL_BUDGET);
  for (const uint32_t pixel : ring.shown) {
    const unsigned red = pixel >> 16;
    const unsigned green = (pixel >> 8) & 255;
    const unsigned blue = pixel & 255;
    assert(red > 0 && red < 255 && green * 2 == red && blue * 4 == red);
  }
  // 114 pixels idle at 1 mA, 140 mA of logic.
  const double modeledMilliamps =
      (RING_CHANNEL_BUDGET + PILL_CHANNEL_BUDGET) * 20.0 / 255 + 114 + 140;
  assert(modeledMilliamps < 1650);
}

static void ambientRingOutput() {
  // Compare with the original brightness-96 driver, covering the startup
  // green and all possible ambient channel levels without constraining gamma.
  Adafruit_NeoPixel original(1, PIN_RING, NEO_GRB + NEO_KHZ800);
  original.setBrightness(96);
  for (unsigned level = 0; level < 256; ++level) {
    const uint32_t colour = rgb(level, 255 - level, level / 2);
    original.setPixelColor(0, colour);
    original.show();
    assert(ambientRingColor(colour) == original.shown[0]);
  }
  original.setPixelColor(0, rgb(0, 24, 0));
  original.show();
  assert(ambientRingColor(rgb(0, 24, 0)) == original.shown[0]);

  pedal_state state = {};
  uint32_t now = 48000;  // An exact breathe-cycle boundary.
  receive(state, now);
  g_gainArmed = false;
  unsigned lowest = 255, highest = 0;
  for (unsigned tick = 0; tick <= 60; ++tick) {
    at(now += 20);
    assert(g_ringView == RING_BREATHE);
    const unsigned green = (ring.shown[0] >> 8) & 255;
    assert(green > 0 && green <= 96);
    if (green < lowest) lowest = green;
    if (green > highest) highest = green;
    for (const uint32_t pixel : ring.shown) assert(pixel == (green << 8));
  }
  assert(highest == 96 && lowest < 16);
}

static void thirtyFourPixelRing() {
  assert(PIN_RING == 12 && PIN_ENC_A == 13 && PIN_ENC_B == 14 && PIN_ENC_SW == 15);
  assert(PIN_IND == 18 && ring.shown.size() == 34 && ring.brightness == 255);
  pedal_state state = {};
  state.global_color = PEDAL_GLOBAL_AMBER;
  state.loop_length_micros = 1000000;
  uint32_t now = 50000;
  receive(state, now);
  g_gainArmed = false;
  g_ringPhase = 0;
  g_ringLastMs = now;
  at(now += 275);
  assert(g_ringView == RING_COMET && std::fabs(g_ringPhase - 8.5f) < 0.001f);
  at(now += 825);
  assert(std::fabs(g_ringPhase) < 0.001f);  // One continuous loop every 1100 ms.
  at(now += 20);
  assert(g_ringPhase > 0.6f && g_ringPhase < 0.65f);
  const auto playing = ring.shown;
  const float phase = g_ringPhase;
  state.global_color = PEDAL_GLOBAL_OFF;
  receive(state, now += 20);
  assert(g_ringPhase == phase && ring.shown == playing);
  at(now += 200);
  assert(g_ringPhase == phase && ring.shown == playing);

  // A level overlay on a stopped, loaded loop must restore the same frozen
  // comet, including its fractional position and last activity colour.
  state.master_gain = 255;
  receive(state, now += 20);
  assert(g_ringView == RING_ARC);
  for (const uint32_t pixel : ring.shown) assert(pixel == (96U << 8));
  at(now += 880);
  assert(g_ringView == RING_ARC && g_ringPhase == phase);
  at(now += 20);
  assert(g_ringView == RING_COMET && g_ringPhase == phase && ring.shown == playing);
  at(now += 20);
  assert(ring.shown == playing);
  state.master_gain = 128;
  receive(state, now += 20);
  for (unsigned i = 0; i < 34; ++i)
    assert(ring.shown[i] == (i < 18 ? (96U << 8) : 0));
  state.master_gain = 0;
  receive(state, now += 20);
  expectRingDark();
  state.master_gain = 255;
  receive(state, now += 20);
  assert(ringChannelTotal() > 0);
  state.goodbye = 1;
  receive(state, now += 20);
  expectRingDark();
  state.goodbye = 0;
  state.global_color = PEDAL_GLOBAL_GREEN;
  state.master_gain = 255;
  receive(state, now += 20);
  assert(ringChannelTotal() > 0);
  at(now += 5001);
  expectRingDark();
  receive(state, now += 20, true);
  expectRingDark();
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
  sustainedComet();
  ambientRingOutput();
  thirtyFourPixelRing();
  songQueueFill();
  puts("Console v10 ten pills, Song queue fill and 34-pixel sustained ring: all physical groups, host activity, limits and lifecycle pass");
}
