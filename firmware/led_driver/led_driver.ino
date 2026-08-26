// Segno floor-console WS2812 LED driver — RP2040 firmware.
//
// Offloads the hard-real-time WS2812 timing from the Raspberry Pi. Receives
// compact transport-state frames from the Pi over UART (115200 8N1 on Serial1),
// drives a 12-LED loop-position ring plus per-track indicator LEDs, and answers
// a boot-time health ping so a missing/unflashed driver is a visible fault on
// the Pi rather than silent dark LEDs.
//
// Wire format and protocol: see README.md (the Pi side is packages/led_client).
// UNVERIFIED on hardware — written from the spec; flash + bring up on a real
// RP2040 + ring before relying on it.
//
// Build: Arduino with the "Raspberry Pi Pico/RP2040" core + Adafruit NeoPixel.

#include <Adafruit_NeoPixel.h>

// --- Wiring -----------------------------------------------------------------
static const uint8_t LED_PIN = 2;       // WS2812 data (GP2) via a level shifter.
static const uint16_t RING_LEDS = 24;   // Loop-position ring (NeoPixel Ring 24:
                                        // O65.5 / O52.3 / 3.2, the fitted part).
                                        // This was 12 while the hardware was 24:
                                        // the head then swept pixels 0..11 and
                                        // half the ring stayed dark, one loop
                                        // reading as half a turn (#793).
// Comet tail length in pixels, head included. 16 of 24 lights two thirds of the
// ring: with gamma correction the far end is nearly dark, so a long tail reads as
// a smooth wake rather than as "most of the ring is on".
static const uint16_t RING_TRAIL = 16;

// Direction the head travels, seen from the FRONT of the panel. WS2812 index
// order runs whichever way the ring board's chain happens to be laid out and then
// gets mirrored again by which face you view it from, so this is not something
// the code can infer -- it is a property of the fitted part. Clockwise is the
// owner's call (2026-08-22); flip this if bring-up shows it running backwards.
// UNVERIFIED on hardware, like the rest of this file.
static const bool RING_CLOCKWISE = true;

// Map a logical head-relative step onto a physical pixel index.
static inline uint16_t ringIndex(uint16_t head, uint16_t back) {
  const uint16_t fwd = (uint16_t)((head + RING_LEDS - back) % RING_LEDS);
  return RING_CLOCKWISE ? (uint16_t)((RING_LEDS - 1) - fwd) : fwd;
}
static const uint16_t TRACK_LEDS = 8;   // Per-track indicators.
static const uint16_t NUM_LEDS = RING_LEDS + TRACK_LEDS;

// Serial1 = the Pi link: GP1 (RX) <- Pi TX, GP0 (TX) -> Pi RX.
#define LINK Serial1
static const unsigned long LINK_BAUD = 115200;

// --- Protocol (see README.md) ----------------------------------------------
static const uint8_t SYNC = 0xA5;
static const uint8_t TYPE_STATE = 0x01;
static const uint8_t TYPE_PING = 0x02;
static const uint8_t TYPE_ACK = 0x82;
static const uint8_t MAX_PAYLOAD = 64;

Adafruit_NeoPixel strip(NUM_LEDS, LED_PIN, NEO_GRB + NEO_KHZ800);

// --- Last good state (the ring animates locally between frames) -------------
static bool g_running = false;
static uint8_t g_global = 0;      // 0 off,1 green,2 red,3 amber
static uint32_t g_loopUs = 0;     // master loop length in microseconds
static uint8_t g_trackCount = 0;
static uint8_t g_tracks[TRACK_LEDS];
static unsigned long g_frameMs = 0;  // millis() when the last frame arrived

// Colors are gamma-corrected (strip.gamma32) so brightness reads perceptually
// even: a WS2812's duty cycle is linear but the eye's response is not, so without
// it the ring's dim head and the amber mix look top-heavy. gamma32(0) == 0, so
// "off" stays off.
//
// DEFAULT FLIPPED TO ON (2026-08-22, with the comet tail). It mattered little for
// a single lit pixel -- there was nothing to compare it against -- but the tail is
// exactly the case this was written for. A linear PWM ramp of 8 steps is perceived
// as roughly 1.00, .94, .87, .79, .70, .60, .47, .30: the first five look the SAME
// brightness and the whole fade happens in the last two pixels. Corrected, the
// emitted ramp is 1.00, .71, .47, .29, .16, .08, .03, .004, which is what the eye
// reads as an even fade. Define LED_GAMMA_CORRECTION=0 to go back to raw values.
#ifndef LED_GAMMA_CORRECTION
#define LED_GAMMA_CORRECTION 1
#endif

static uint32_t rawColorOf(uint8_t code) {
  switch (code) {
    case 1: return strip.Color(0, 160, 0);   // green
    case 2: return strip.Color(180, 0, 0);   // red
    case 3: return strip.Color(180, 90, 0);  // amber
    default: return 0;                       // off
  }
}

static uint32_t finish(uint32_t c) {
#if LED_GAMMA_CORRECTION
  return strip.gamma32(c);
#else
  return c;
#endif
}

static uint32_t colorOf(uint8_t code) { return finish(rawColorOf(code)); }

// Scale a RAW colour to num/den, then gamma-correct. The order matters: gamma is
// the eye's curve, so scaling an already-corrected value applies the curve twice
// and the trail collapses to almost nothing after two or three pixels. Always
// dim first, correct last -- which is why rawColorOf and finish are separate.
static uint32_t dimmed(uint32_t c, uint16_t num, uint16_t den) {
  const uint8_t r = (uint8_t)((((c >> 16) & 0xFF) * num) / den);
  const uint8_t g = (uint8_t)((((c >> 8) & 0xFF) * num) / den);
  const uint8_t b = (uint8_t)(((c & 0xFF) * num) / den);
  return finish(strip.Color(r, g, b));
}

// Parse one STATE frame from a buffer that starts at the byte after the length
// byte (layout: flags, global, loopUs LE x4, trackCount, tracks...).
static void applyState(const uint8_t* p, uint8_t len) {
  if (len < 7) return;
  g_running = (p[0] & 0x1) != 0;
  g_global = p[1];
  g_loopUs = (uint32_t)p[2] | ((uint32_t)p[3] << 8) | ((uint32_t)p[4] << 16) |
             ((uint32_t)p[5] << 24);
  g_trackCount = p[6] < TRACK_LEDS ? p[6] : TRACK_LEDS;
  for (uint8_t i = 0; i < g_trackCount && (7 + i) < len; i++) {
    g_tracks[i] = p[7 + i];
  }
  g_frameMs = millis();
}

static void sendAck() {
  const uint8_t ack[4] = {SYNC, TYPE_ACK, 0x00, TYPE_ACK};
  LINK.write(ack, sizeof(ack));
}

// Minimal framing state machine: SYNC, type, len, payload, checksum (XOR of
// type..last payload byte). A bad checksum drops the frame (the Pi re-sends).
static void pumpLink() {
  static uint8_t buf[MAX_PAYLOAD];
  static uint8_t type = 0, len = 0, idx = 0, checksum = 0;
  static uint8_t stage = 0;  // 0 sync,1 type,2 len,3 payload,4 checksum
  while (LINK.available() > 0) {
    const uint8_t b = (uint8_t)LINK.read();
    switch (stage) {
      case 0:
        if (b == SYNC) stage = 1;
        break;
      case 1:
        type = b;
        checksum = b;
        stage = 2;
        break;
      case 2:
        len = b <= MAX_PAYLOAD ? b : 0;
        checksum ^= b;
        idx = 0;
        stage = (len == 0) ? 4 : 3;
        break;
      case 3:
        buf[idx++] = b;
        checksum ^= b;
        if (idx >= len) stage = 4;
        break;
      case 4:
        if (b == checksum) {
          if (type == TYPE_STATE) applyState(buf, len);
          else if (type == TYPE_PING) sendAck();
        }
        stage = 0;
        break;
    }
  }
}

static void render() {
  strip.clear();
  // Ring: a comet at the loop position when running, in the global colour;
  // otherwise a dim idle dot at pixel 0.
  if (g_running && g_loopUs > 0) {
    const uint32_t loopMs = g_loopUs / 1000;
    const uint32_t pos = loopMs > 0 ? ((millis() - g_frameMs) % loopMs) : 0;
    const uint16_t head = loopMs > 0 ? (pos * RING_LEDS) / loopMs : 0;
    // While running, a global of 'off' still shows a moving green head so the
    // ring is never dark mid-loop.
    const uint32_t base = rawColorOf(g_global == 0 ? 1 : g_global);
    // A COMET, not a single dot: the head at full brightness with a tail of
    // RING_TRAIL pixels fading behind it. The WEIGHTS are linear; the light is
    // not, because dimmed() gamma-corrects -- that is the point, see the
    // LED_GAMMA_CORRECTION note. A lone lit pixel on a 24-LED
    // ring reads as a blink rather than motion -- there is nothing to see the
    // direction or the speed against. The tail is what makes the loop position
    // legible at a glance (owner call 2026-08-22).
    //
    // i = 0 IS the head, so the weights run RING_TRAIL/RING_TRAIL down to
    // 1/RING_TRAIL and never reach zero: the dimmest pixel still shows.
    for (uint16_t i = 0; i < RING_TRAIL && i < RING_LEDS; i++) {
      strip.setPixelColor(ringIndex(head, i),
                          dimmed(base, (uint16_t)(RING_TRAIL - i), RING_TRAIL));
    }
  } else {
    // Through ringIndex too, so the idle dot sits where pixel 0 actually is
    // rather than wherever the chain happens to start.
    strip.setPixelColor(ringIndex(0, 0), finish(strip.Color(10, 10, 10)));
  }
  // Per-track indicators.
  for (uint8_t i = 0; i < TRACK_LEDS; i++) {
    strip.setPixelColor(RING_LEDS + i, colorOf(i < g_trackCount ? g_tracks[i] : 0));
  }
  strip.show();
}

void setup() {
  LINK.begin(LINK_BAUD);
  strip.begin();
  strip.setBrightness(120);
  strip.show();
}

void loop() {
  pumpLink();
  render();
  delay(16);  // ~60 fps ring animation; well below WS2812 refresh limits.
}
