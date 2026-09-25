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

static const size_t REC_PLAY_GROUP = 7;

static void expectGroup(size_t group, const uint8_t (&levels)[8], unsigned shift) {
  assert(ind.shown.size() == 80);
  for (size_t i = 0; i < 8; ++i) {
    assert(ind.shown[group * 8 + i] == (uint32_t)levels[i] << shift);
  }
}

static void expect(const uint8_t (&levels)[8], unsigned shift) {
  expectGroup(REC_PLAY_GROUP, levels, shift);
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

static void queuedSongPill() {
  for (uint8_t button = 0; button < PEDAL_BTN_COUNT; ++button) {
    fake_arduino::digital[FSW_PIN[button]] = HIGH;
    g_btnStable[button] = g_btnLastRaw[button] = false;
  }
  pedal_state state = {};
  state.mode = PEDAL_MODE_PLAY;
  state.looper_mode = PEDAL_LOOPER_SONG;
  state.loop_length_micros = 1000000;
  state.queued_track = 2;
  state.track_leds[0] = PEDAL_LED_RED;
  state.track_leds[1] = PEDAL_LED_BLUE;
  uint32_t now = 30000;
  receive(state, now);
  const uint8_t dark[8] = {};
  const uint8_t bright[8] = {28, 69, 151, 191, 191, 151, 69, 28};
  expectGroup(2, dark, 0);
  expectGroup(3, bright, 16);
  state.queued_progress = 16;
  receive(state, now += 20);
  assert(ind.shown[23] == (14U << 8));
  for (unsigned i = 16; i < 23; ++i) assert(ind.shown[i] == 0);
  state.queued_progress = 128;
  receive(state, now += 20);
  const uint8_t half[8] = {0, 0, 0, 3, 191, 151, 69, 28};
  expectGroup(2, half, 8);  // Physical left half, reversed data input.
  const auto frozen = ind.shown;
  at(now += 1000);
  assert(ind.shown == frozen);  // Device time cannot complete the queue.
  state.queued_progress = 254;
  receive(state, now += 20);
  assert(ind.shown[16] == (27U << 8) && ind.shown[23] == (28U << 8));

  state.active_bank = 1;
  state.track_leds[5] = PEDAL_LED_RED;
  receive(state, now += 20);
  expectGroup(2, bright, 16);  // Hidden bank A queue cannot move onto bank B.
  state.queued_track = 6;
  state.queued_progress = 128;
  receive(state, now += 20);
  expectGroup(2, half, 8);
  state.mode = PEDAL_MODE_REC;
  receive(state, now += 20);
  expectGroup(2, bright, 16);
  state.mode = PEDAL_MODE_FX;
  receive(state, now += 20);
  expectGroup(2, bright, 16);
  state.mode = PEDAL_MODE_PLAY;
  state.looper_mode = PEDAL_LOOPER_MULTI;
  receive(state, now += 20);
  expectGroup(2, bright, 16);
  state.looper_mode = PEDAL_LOOPER_SONG;
  state.queued_track = PEDAL_NO_QUEUED_TRACK;
  state.queued_progress = 0;
  receive(state, now += 20);
  expectGroup(2, bright, 16);  // Cancel returns to actual app state.

  state.queued_track = 6;
  state.queued_progress = 254;
  receive(state, now += 20);
  state.queued_track = PEDAL_NO_QUEUED_TRACK;
  state.queued_progress = 0;
  state.track_leds[5] = PEDAL_LED_GREEN;
  receive(state, now += 20);
  expectGroup(2, bright, 8);  // Completion comes only from the app.
  state.queued_track = 6;
  state.queued_progress = 128;
  state.goodbye = 1;
  receive(state, now += 20);
  expectAllDark();
  state.goodbye = 0;
  receive(state, now += 20);
  at(now += 5001);
  expectAllDark();
  receive(state, now += 20, true);
  expectAllDark();
  state.queued_track = PEDAL_NO_QUEUED_TRACK;
  state.queued_progress = 0;
  receive(state, now += 20);
  expectGroup(2, bright, 8);
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

static void sustainedComet() {
  // Inspect transmitted duty, not the profile constants: a second gamma pass
  // or a driver brightness reduction would visibly shorten the approved tail.
  g_ringPhase = 0;
  paintComet({0, 255, 0});
  showRing();
  const auto origin = ring.shown;
  assert(origin[0] == (192U << 8) && origin[39] == (192U << 8));
  unsigned lit = 0;
  unsigned previous = 192;
  for (unsigned behind = 0; behind < 40; ++behind) {
    const uint32_t pixel = origin[(40 - behind) % 40];
    const unsigned duty = (pixel >> 8) & 255;
    assert((pixel & 0xff00ff) == 0 && duty <= previous);
    if (behind <= 16) assert(duty >= 96);
    if (behind >= 30) assert(duty == 0);
    if (duty) ++lit;
    previous = duty;
  }
  assert(lit == 30);
  assert(origin[11] == (2U << 8));  // The last lit tail pixel eases into black.

  // Increasing phase moves the bright leading edge toward increasing pixel
  // indices. Fractional positions blend the two neighboring complete frames,
  // including the wire-notch boundary between pixels 39 and 0.
  for (const unsigned base : {0U, 39U}) {
    g_ringPhase = (float)base;
    paintComet({0, 255, 0});
    showRing();
    const auto before = ring.shown;
    g_ringPhase = (float)((base + 1) % 40);
    paintComet({0, 255, 0});
    showRing();
    const auto after = ring.shown;
    assert(after[(base + 1) % 40] == (192U << 8));
    assert(before[(base + 1) % 40] == 0);
    for (unsigned quarter = 1; quarter < 4; ++quarter) {
      g_ringPhase = base + quarter / 4.0f;
      paintComet({0, 255, 0});
      showRing();
      for (unsigned pixel = 0; pixel < 40; ++pixel) {
        const unsigned a = (before[pixel] >> 8) & 255;
        const unsigned b = (after[pixel] >> 8) & 255;
        const unsigned expected = (a * (4 - quarter) + b * quarter + 2) / 4;
        assert(ring.shown[pixel] == (expected << 8));
      }
      assert(ring.shown[(base + 1) % 40] == ((48U * quarter) << 8));
    }
  }

  // The weaker yellow channel must survive all the way to the tail; dimming
  // changes duty without adding a second gamma pass or changing the hue.
  g_ringPhase = 0;
  paintComet(globalColor(PEDAL_GLOBAL_AMBER));
  showRing();
  const unsigned yellowGreen = Adafruit_NeoPixel::gamma8(235);
  for (unsigned behind = 0; behind < 30; ++behind) {
    const uint32_t pixel = ring.shown[(40 - behind) % 40];
    const unsigned red = pixel >> 16;
    const unsigned green = (pixel >> 8) & 255;
    assert(red > 0 && green > 0 && green <= red && (pixel & 255) == 0);
    assert(green == (red * yellowGreen + 127) / 255);
  }

  // Even a white comet stays below the previous full-white ring ceiling at
  // every quarter-pixel phase; ordinary animations need no limiter dimming.
  for (unsigned quarter = 0; quarter < 160; ++quarter) {
    g_ringPhase = quarter / 4.0f;
    paintComet({255, 255, 255});
    const auto requested = ring.pixels;
    showRing();
    assert(ring.shown == requested);
    assert(ringChannelTotal() <= 11520);
  }

  // Deliberately over-budget frames exercise the actual transfer limiter.
  for (unsigned i = 0; i < 40; ++i) ring.setPixelColor(i, 0xffffff);
  showRing();
  for (const uint32_t pixel : ring.shown) assert(pixel == 0x606060);
  assert(ringChannelTotal() == 11520);
  const auto limited = ring.shown;
  showRing();
  assert(ring.shown == limited);  // Refreshing cannot repeatedly dim a frame.
  for (unsigned i = 0; i < 40; ++i) ring.setPixelColor(i, 0xff8040);
  showRing();
  assert(ringChannelTotal() <= 11520);
  for (const uint32_t pixel : ring.shown) {
    const unsigned red = pixel >> 16;
    const unsigned green = (pixel >> 8) & 255;
    const unsigned blue = pixel & 255;
    assert(red > 0 && red < 255 && green * 2 == red && blue * 4 == red);
  }
  const double modeledMilliamps = (11520 + PILL_CHANNEL_BUDGET) * 20.0 / 255 + 120 + 140;
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

static void fortyPixelRing() {
  assert(PIN_RING == 12 && PIN_ENC_A == 13 && PIN_ENC_B == 14 && PIN_ENC_SW == 15);
  assert(PIN_IND == 18 && ring.shown.size() == 40 && ring.brightness == 255);
  pedal_state state = {};
  state.global_color = PEDAL_GLOBAL_AMBER;
  state.loop_length_micros = 1000000;
  uint32_t now = 50000;
  receive(state, now);
  g_gainArmed = false;
  g_ringPhase = 0;
  g_ringLastMs = now;
  at(now += 275);
  assert(g_ringView == RING_COMET && std::fabs(g_ringPhase - 10.0f) < 0.001f);
  at(now += 825);
  assert(std::fabs(g_ringPhase) < 0.001f);  // One continuous loop every 1100 ms.
  at(now += 20);
  assert(g_ringPhase > 0.7f && g_ringPhase < 0.8f);
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
  for (unsigned i = 0; i < 40; ++i)
    assert(ring.shown[i] == (i < 21 ? (96U << 8) : 0));
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

int main() {
  fake_arduino::analog[26] = fake_arduino::analog[27] = 4095;
  setup();
  const uint8_t dark[8] = {};
  const uint8_t dim[8] = {4, 10, 23, 29, 29, 23, 10, 4};
  const uint8_t bright[8] = {28, 69, 151, 191, 191, 151, 69, 28};
  assert(ind.pin == 18);
  assert(ring.brightness == 255 && ring.shown.size() == 40);
  expectAllDark();

  pedal_state state = {};
  state.master_gain = 255;
  receive(state, 1000);
  expect(dim, 8);
  at(1125);
  assert(ind.shown[59] == (54U << 8));  // Smoothstep rather than a linear ramp.
  at(1500);
  expect(bright, 8);
  receive(state, 1750);  // App heartbeats must not restart the breath.
  assert(ind.shown[59] == (110U << 8));
  at(2000);
  expect(dim, 8);

  // Engine activity wins over interaction mode and performance-file arming.
  state.mode = PEDAL_MODE_FX;
  state.performance_armed = 1;
  state.global_color = PEDAL_GLOBAL_RED;
  receive(state, 2020);
  expect(bright, 16);
  const unsigned recordingPushes = ind.showCount;
  at(2040);
  expect(bright, 16);
  assert(ind.showCount == recordingPushes);  // Stable state needs no extra push.

  state.global_color = PEDAL_GLOBAL_GREEN;
  state.loop_length_micros = 1000000;
  receive(state, 2100);
  expect(bright, 8);
  state.global_color = PEDAL_GLOBAL_AMBER;
  receive(state, 2120);
  for (size_t i = 0; i < 8; ++i) {
    const uint32_t pixel = ind.shown[56 + i];
    assert((pixel >> 16) == bright[i]);
    assert(((pixel >> 8) & 255) > 0 && ((pixel >> 8) & 255) < bright[i]);
    assert((pixel & 255) == 0);
    assert(pixel == ind.shown[63 - i]);
  }

  // Stop with a loaded loop goes dark, rather than breathing ready.
  state.global_color = PEDAL_GLOBAL_OFF;
  receive(state, 2160);
  expect(dark, 0);
  at(2500);
  expect(dark, 0);
  state.global_color = PEDAL_GLOBAL_RED;
  receive(state, 2600);
  expect(bright, 16);
  at(7601);  // Lost link must never leave a stale recording indication.
  expectAllDark();
  receive(state, 7630, true);
  expectAllDark();
  receive(state, 7650);
  expect(bright, 16);
  state.goodbye = 1;
  receive(state, 7670);
  expectAllDark();

  state = {};
  state.master_gain = 255;
  receive(state, 8000);
  expect(dim, 8);

  // The real REC/PLAY switch still sends a normal pedal-link event. It does
  // not select a local test mode or invent a recording state before the app.
  fake_arduino::sent.clear();
  fake_arduino::digital[2] = LOW;
  at(8100);
  at(8120);
  const auto buttonColor = ind.shown[59];
  assert((buttonColor & 0xFF00FF) == 0);
  expectButtonEvent(PEDAL_BTN_REC_PLAY, true);

  uint32_t now = 8140;
  buttonEdge(PEDAL_BTN_REC_PLAY, 2, false, now);
  // A loaded but silent session does not prove STOP: all-muted playback has
  // exactly these activity/length bytes too. Only the STOP press may light it.
  state = {};
  state.master_gain = 255;
  state.loop_length_micros = 1000000;
  state.track_leds[0] = PEDAL_LED_RED;
  state.track_leds[1] = PEDAL_LED_GREEN;
  state.track_leds[2] = PEDAL_LED_BLUE;
  state.track_leds[3] = PEDAL_LED_OFF;
  state.track_leds[4] = PEDAL_LED_BLUE;
  state.track_leds[5] = PEDAL_LED_RED;
  state.track_leds[6] = PEDAL_LED_OFF;
  state.track_leds[7] = PEDAL_LED_GREEN;
  receive(state, now += 20);
  expectGroup(0, dark, 0);     // TRACK4
  expectGroup(1, bright, 0);   // TRACK3
  expectGroup(2, bright, 8);   // TRACK2
  expectGroup(3, bright, 16);  // TRACK1
  expectGroup(4, bright, 16);  // MODE: Record
  expectGroup(5, dark, 0);     // UNDO
  expectGroup(6, dark, 0);     // STOP
  expectGroup(7, dark, 0);     // REC/PLAY
  expectGroup(8, dark, 0);     // CLEAR
  expectGroup(9, dark, 0);     // BANK A

  state.mode = PEDAL_MODE_PLAY;
  receive(state, now += 20);
  expectGroup(4, bright, 8);
  state.mode = PEDAL_MODE_FX;
  receive(state, now += 20);
  expectGroup(4, bright, 0);
  state.active_bank = 1;
  receive(state, now += 20);
  expectGroup(0, bright, 8);   // TRACK8 at the same physical TRACK4 pill
  expectGroup(1, dark, 0);     // TRACK7
  expectGroup(2, bright, 16);  // TRACK6
  expectGroup(3, bright, 0);   // TRACK5
  // BANK B has the same visible blue brightness and curve as MODE in FX.
  expectGroup(9, bright, 0);
  assert(ind.shown[75] == ind.shown[35]);
  state.clear_fade = 1;
  receive(state, now += 20);
  expectGroup(8, bright, 16);
  state.clear_fade = 0;
  receive(state, now += 20);
  expectGroup(8, dark, 0);

  // Exercise every channel individually in both banks. The inactive bank is
  // deliberately lit, so an accidental bank/track-index mix cannot pass dark.
  const uint8_t trackColors[4] = {
    PEDAL_LED_RED, PEDAL_LED_GREEN, PEDAL_LED_BLUE, PEDAL_LED_RED
  };
  const unsigned trackShifts[4] = {16, 8, 0, 16};
  for (uint8_t bank = 0; bank < 2; ++bank) {
    state.active_bank = bank;
    for (uint8_t track = 0; track < 4; ++track) {
      for (uint8_t channel = 0; channel < 8; ++channel) {
        state.track_leds[channel] = channel / 4 == bank ? PEDAL_LED_OFF : PEDAL_LED_BLUE;
      }
      state.track_leds[bank * 4 + track] = trackColors[track];
      receive(state, now += 20);
      for (size_t group = 0; group < 4; ++group) {
        if (group == (size_t)(3 - track)) {
          expectGroup(group, bright, trackShifts[track]);
        } else {
          expectGroup(group, dark, 0);
        }
      }
    }
  }

  // Physical button feedback keeps the normal app-facing protocol intact.
  buttonEdge(PEDAL_BTN_STOP, 3, true, now);
  expectGroup(6, bright, 16);
  buttonEdge(PEDAL_BTN_STOP, 3, false, now);
  expectGroup(6, dark, 0);
  buttonEdge(PEDAL_BTN_UNDO, 4, true, now);
  expectGroup(5, bright, 0);
  buttonEdge(PEDAL_BTN_UNDO, 4, false, now);
  expectGroup(5, dark, 0);

  // The spatial curve is symmetric, so use asymmetric pixel tags to check
  // physical left-to-right addressing separately: front enters from right.
  uint8_t positions[80] = {};
  for (uint8_t group = 0; group < 10; ++group) {
    for (uint8_t pixel = 0; pixel < 8; ++pixel) {
      positions[pillPixelIndex(group, pixel)] = pixel + 1;
    }
  }
  const uint8_t front[8] = {8, 7, 6, 5, 4, 3, 2, 1};
  const uint8_t back[8] = {1, 2, 3, 4, 5, 6, 7, 8};
  for (uint8_t group = 0; group < 10; ++group) {
    for (uint8_t pixel = 0; pixel < 8; ++pixel) {
      assert(positions[group * 8 + pixel] == (group < 8 ? front[pixel] : back[pixel]));
    }
  }

  // Crowded valid frames trigger the current budget. Repeated rendering must
  // use the original desired colors, not keep dimming the previous buffer.
  for (uint8_t track = 0; track < 8; ++track) state.track_leds[track] = PEDAL_LED_RED;
  state.global_color = PEDAL_GLOBAL_AMBER;
  state.clear_fade = 1;
  state.mode = PEDAL_MODE_REC;
  receive(state, now += 20);
  buttonEdge(PEDAL_BTN_STOP, 3, true, now);
  buttonEdge(PEDAL_BTN_UNDO, 4, true, now);
  assert(channelTotal() > 5500 && channelTotal() <= 6000);
  assert((ind.shown[3] >> 16) > 0 && (ind.shown[3] >> 16) < 191);
  assert(ind.shown[3] == ind.shown[35]);  // Equal red pills scale equally.
  assert(ind.shown[59] == ind.shown[60]); // Mixed-color spatial symmetry.
  assert((ind.shown[59] >> 16) > ((ind.shown[59] >> 8) & 255));
  assert(((ind.shown[59] >> 8) & 255) > 0 && (ind.shown[59] & 255) == 0);
  const auto limited = ind.shown;
  const unsigned limitedPushes = ind.showCount;
  at(now += 20);
  assert(ind.shown == limited);
  // A refresh may resend an unchanged frame, but must never alter brightness.
  assert(ind.showCount <= limitedPushes + 1);
  for (unsigned repeat = 0; repeat < 6; ++repeat) {
    receive(state, now += 100);
    assert(ind.shown == limited && channelTotal() <= 6000);
  }

  for (uint8_t track = 0; track < 8; ++track) state.track_leds[track] = PEDAL_LED_OFF;
  state.global_color = PEDAL_GLOBAL_OFF;
  state.clear_fade = 0;
  state.active_bank = 0;
  receive(state, now += 20);
  expectGroup(4, bright, 16);  // Uncrowded frame recovers the calibrated peak.
  expectGroup(5, bright, 0);
  expectGroup(6, bright, 16);

  // Every group must go dark on goodbye/lost link, even with switches held.
  state.goodbye = 1;
  receive(state, now += 20);
  expectAllDark();
  state.goodbye = 0;
  for (uint8_t track = 0; track < 8; ++track) state.track_leds[track] = PEDAL_LED_GREEN;
  state.global_color = PEDAL_GLOBAL_RED;
  state.clear_fade = 1;
  state.active_bank = 1;
  receive(state, now += 20);
  for (size_t group = 0; group < 10; ++group) assert(ind.shown[group * 8 + 3] != 0);
  at(now += 5001);
  expectAllDark();
  receive(state, now += 20, true);
  expectAllDark();
  receive(state, now += 20);
  for (size_t group = 0; group < 10; ++group) assert(ind.shown[group * 8 + 3] != 0);
  queuedSongPill();
  sustainedComet();
  ambientRingOutput();
  fortyPixelRing();
  puts("Console ten pills and sustained ring: real frames, queued fills, fractional motion, current limits and retained state pass");
}
