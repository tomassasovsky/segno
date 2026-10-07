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
  fortyPixelRing();
  puts("Console v8 ten pills and sustained ring: all physical groups, host activity, limits and lifecycle pass");
}
