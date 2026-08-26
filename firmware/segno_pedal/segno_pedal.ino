/*
 * segno_pedal.ino - firmware for the segno bidirectional MIDI looper pedal.
 *
 * A PURE THIN CLIENT. It holds NO looper state: it renders LEDs only from the
 * last good state frame segno pushes, and sends raw footswitch / encoder events.
 * segno runs the behavior machine and is the single source of truth. This
 * eliminates the old firmware's State[] that drifted from the app.
 *
 * Transport: serial MIDI at 31250 baud through the ATmega16U2 reflashed with
 * dualMocoLUFA (see README). The 8-bit AVR cannot use the MIDIUSB library.
 *
 * The wire protocol lives in pedal_protocol.c/.h (the same unit segno's host
 * test checks against the golden fixtures), so this sketch never hand-rolls the
 * SysEx framing.
 *
 * FastLED note: FastLED.show() disables interrupts (~30 us/LED), long enough to
 * drop an inbound serial MIDI byte at 31250 baud. So we poll MIDI immediately
 * before AND after every show(), and frames are checksum-guarded + refreshed by
 * segno ~1 Hz so a dropped frame self-heals. The loop-top spin is a single
 * real-time byte (0xFA), which survives the interrupt gap far better than a
 * multi-byte SysEx.
 */
#include <FastLED.h>

#include "pedal_protocol.h"

// ---- hardware layout — matches the physical "aquiles LoopStation" wiring -----

// The WS2812B strip is 19 LEDs on pin D2: a 12-LED loop-position ring (indices
// 0..11) followed by 7 indicator LEDs (mode, the 4 active-bank tracks, clear,
// and the bank LED). This mirrors the original firmware's LED map.
static const uint8_t kLedPin = 2;
static const uint8_t kNumLeds = 19;
static const uint8_t kRingStart = 0;  // loop-position ring = LEDs 0..11
static const uint8_t kRingCount = 12;
static const uint8_t kModeLed = 12;   // tri-state mode indicator (A1)
static const uint8_t kTrackLed0 = 13; // active-bank tracks 1..4 = LEDs 13..16
static const uint8_t kClearLed = 17;  // lit during a clear fade
static const uint8_t kBankLed = 18;   // lit when bank B is active
static CRGB g_leds[kNumLeds];  // logical frame the renderer writes (nominal color)
static CRGB g_out[kNumLeds];   // gamma-corrected copy FastLED actually clocks out

// The 10 footswitches, indexed by PEDAL_BTN_* (recPlay, stop, undo, mode,
// track1..4, clear, bank); active-low with INPUT_PULLUP. Matches the original
// wiring D3..D12 (the original "Next" switch on A2 is dropped in this layout).
static const uint8_t kButtonPins[PEDAL_BTN_COUNT] = {
    3,  // recPlay
    4,  // stop
    5,  // undo
    6,  // mode
    7,  // track1
    8,  // track2
    9,  // track3
    10, // track4
    11, // clear
    12, // bank
};
// Rotary encoder: clock A0, data A1 (the push switch on A2 is unused in v1).
static const uint8_t kEncoderClk = A0;
static const uint8_t kEncoderDat = A1;

static const unsigned long kDebounceMs = 25; // foot-switch contact debounce
static const uint8_t kMidiChannel = 0; // channel 1 (0-based on the wire)

// ---- inbound state ----------------------------------------------------------

static pedal_frame g_frame;       // last good frame segno pushed
static bool g_haveFrame = false;  // false until the first valid frame
static uint8_t g_sysex[40];
static uint8_t g_sysexLen = 0;
static bool g_inSysex = false;

// Timestamp of the last loop-top pulse (0xFA) from segno. Currently unused:
// v1's ring (see renderRing()) breathes when idle and sweeps a playhead
// independent of loop length. Reserved for a possible future loop-synced
// rendering mode.
static unsigned long g_lastLoopTopMs = 0;

// ---- button / encoder debounce state ----------------------------------------

static bool g_btnStable[PEDAL_BTN_COUNT];  // last debounced (reported) state
static bool g_btnLastRaw[PEDAL_BTN_COUNT]; // previous raw sample
static unsigned long g_btnRawSinceMs[PEDAL_BTN_COUNT]; // when raw last changed
static uint8_t g_encClkPrev = 0;

// ---- MIDI out ---------------------------------------------------------------

static void sendBytes(const uint8_t* data, int len) {
  Serial.write(data, len);
}

// The pedal's identity reply: a fixed family signature segno recognizes. Sent in
// response to the Universal Identity Request. (segno does not parse it in v1 —
// its 3-byte input capture cannot receive SysEx — but the firmware answers per
// the spec for a future inbound path.)
static void sendIdentityReply() {
  static const uint8_t kReply[] = {
      0xF0, 0x7E, 0x7F, 0x06, 0x02, PEDAL_MANUFACTURER_ID,
      0x4C, 0x50, // family "LP"
      0x01, 0x00, // member
      // Revision byte 0 reports the wire protocol version this firmware
      // speaks — the value #331's version discovery will read (R6).
      PEDAL_PROTOCOL_VERSION, 0x00, 0x00, 0x00,
      0xF7};
  sendBytes(kReply, sizeof(kReply));
}

// ---- inbound MIDI -----------------------------------------------------------

static void handleSysex(const uint8_t* msg, int len) {
  if (pedal_is_identity_request(msg, len)) {
    sendIdentityReply();
    return;
  }
  pedal_frame decoded;
  if (pedal_decode_frame(msg, len, &decoded)) {
    g_frame = decoded;
    g_haveFrame = true;
  }
  // A malformed frame is silently dropped; the last good frame is retained.
}

static void onLoopTop() {
  g_lastLoopTopMs = millis();
}

// Drains all available serial bytes, assembling SysEx and handling interleaved
// real-time messages (the loop-top pulse) without corrupting the SysEx buffer.
static void pollMidiIn() {
  while (Serial.available() > 0) {
    const uint8_t b = (uint8_t)Serial.read();
    if (b == PEDAL_LOOP_TOP) {
      onLoopTop();
      continue; // real-time: may interleave inside a SysEx
    }
    if (b >= 0xF8) {
      continue; // other real-time: ignore, do not disturb a SysEx in progress
    }
    if (b == PEDAL_SYSEX_START) {
      g_sysexLen = 0;
      g_inSysex = true;
      g_sysex[g_sysexLen++] = b;
      continue;
    }
    if (!g_inSysex) {
      continue; // segno sends only SysEx + real-time; ignore stray bytes
    }
    if (g_sysexLen >= sizeof(g_sysex)) {
      g_inSysex = false; // overflow: drop this (partial) frame
      continue;
    }
    g_sysex[g_sysexLen++] = b;
    if (b == PEDAL_SYSEX_END) {
      g_inSysex = false;
      handleSysex(g_sysex, g_sysexLen);
    }
  }
}

// ---- rendering --------------------------------------------------------------

static CRGB ledColor(uint8_t led) {
  switch (led) {
    case PEDAL_LED_GREEN:
      return CRGB::Green;
    case PEDAL_LED_RED:
      return CRGB::Red;
    case PEDAL_LED_BLUE: // FX-mode chain-enabled (part 5b's projection)
      return CRGB::Blue;
    default:
      return CRGB::Black;
  }
}

static CRGB globalColor(uint8_t color) {
  switch (color) {
    case PEDAL_GLOBAL_GREEN:
      return CRGB::Green;
    case PEDAL_GLOBAL_RED:
      return CRGB::Red;
    case PEDAL_GLOBAL_AMBER:
      return CRGB(255, 150, 0);
    case PEDAL_GLOBAL_BLUE:
      return CRGB::Blue;
    default:
      return CRGB::Black;
  }
}

// The tri-state mode indicator's color per decoded interaction mode (A1):
// Rec red, Play/mute green, FX blue — matching the chain-enabled track-LED
// blue. Rendered verbatim from the frame's 2-bit mode; segno remains the
// single source of truth.
//
// Rec was green and Play/mute amber until #693. The owner's call is that mute
// reads green on every surface, and green was already spoken for by rec — so
// rec moves to red, which is what every screen has always drawn it as. Keep
// this in lockstep with the app's `_modeColor` in `pedal_plate.dart`.
// No wire byte changes: the frame carries the 2-bit mode, never a colour.
//
// Two call sites, one meaning: the MODE LED, and the ring playhead once a
// loop is running. The idle ring breathes in green with no distinguished
// playhead — a red idle tick would read as a live take from stage distance.
static CRGB modeColor(uint8_t mode) {
  switch (mode) {
    case PEDAL_MODE_PLAY:
      return globalColor(PEDAL_GLOBAL_GREEN); // one definition of green
    case PEDAL_MODE_FX:
      return CRGB::Blue;
    default: // PEDAL_MODE_REC
      return globalColor(PEDAL_GLOBAL_RED); // one definition of red
  }
}

static CRGB scaled(CRGB c, uint8_t level) {
  c.nscale8_video(level);
  return c;
}

// The looping ring is a green fill with a brightness hump around the playhead.
// The playhead LED ("first in line") takes the interaction-mode colour: rec
// red, mute green, FX blue. Tune: kRingMsPerRev (lower = faster), kRingWidth
// (LEDs lit each side), kRingShape (parabola-ish), kBreatheMs (idle pulse).
// Independent of loop length. A Stop that leaves a loop loaded FREEZES the
// playhead. With no loop, every LED breathes together in green — no red tick,
// so idle rec mode cannot read as a live take (#693).
static const unsigned long kRingMsPerRev = 700;
static const unsigned long kBreatheMs = 2400;
static const float kRingWidth = 5.5f;
static const float kRingShape = 1.5f;
static const uint8_t kRingBaseLevel = 77; // ~30%, matches the app's _baseGlow
static float g_ringPhase = 0.0f;       // current center, 0..kRingCount
static unsigned long g_ringLastMs = 0; // for dt-based phase advance

static void renderRing() {
  const unsigned long now = millis();
  const unsigned long dt = now - g_ringLastMs;
  g_ringLastMs = now;
  if (!g_haveFrame || g_frame.goodbye) {
    for (uint8_t i = 0; i < kRingCount; i++) g_leds[kRingStart + i] = CRGB::Black;
    return;
  }
  const CRGB activity = globalColor(g_frame.global_color);
  const bool looping = g_frame.loop_length_micros > 0;
  const bool active = (activity.r || activity.g || activity.b) &&
                      g_frame.global_color != PEDAL_GLOBAL_BLUE;
  // A Stop with a loop still loaded freezes the playhead where it was.
  if (looping && !active) return;

  const CRGB base = CRGB::Green;
  const CRGB head = modeColor(g_frame.play_mode);

  if (!looping) {
    unsigned long p = now % kBreatheMs;
    const unsigned long half = kBreatheMs / 2;
    float t = (p < half) ? (p / (float)half)
                         : (1.0f - (p - half) / (float)half); // 0..1..0
    t = t * t * (3.0f - 2.0f * t); // smoothstep
    const uint8_t level = (uint8_t)((0.15f + 0.85f * t) * 255.0f + 0.5f);
    const CRGB c = scaled(base, level);
    for (uint8_t i = 0; i < kRingCount; i++) g_leds[kRingStart + i] = c;
    return;
  }

  g_ringPhase += (float)dt / (float)kRingMsPerRev * (float)kRingCount;
  while (g_ringPhase >= (float)kRingCount) g_ringPhase -= (float)kRingCount;
  uint8_t headIdx = (uint8_t)(g_ringPhase + 0.5f);
  if (headIdx >= kRingCount) headIdx = 0;
  for (uint8_t i = 0; i < kRingCount; i++) {
    float d = fabsf((float)i - g_ringPhase);
    if (d > kRingCount / 2.0f) d = kRingCount - d; // wrap the short way round
    const float dn = d / kRingWidth;
    uint8_t level = kRingBaseLevel;
    if (dn < 1.0f) {
      float b = 1.0f - powf(dn, kRingShape);
      if (b < 0.0f) b = 0.0f;
      level = (uint8_t)(kRingBaseLevel + (255 - kRingBaseLevel) * b + 0.5f);
    }
    g_leds[kRingStart + i] = scaled((i == headIdx) ? head : base, level);
  }
}

// ---- perceptual gamma correction --------------------------------------------

// A WS2812's duty cycle is linear but the eye's brightness response is not, so a
// linear ramp looks top-heavy: the dim steps of the ring's rotating brightness
// hump crowd together while the bright end barely changes. We map every channel
// through a gamma 2.8 curve at OUTPUT time (g_leds -> g_out) so the ramp reads
// evenly. Doing it into a SEPARATE display buffer — not in place — matters: the
// frozen-playhead ring holds its last logical frame without redrawing, so an
// in-place correction would darken it a little more every show() until it decays
// to black. Copying from the untouched logical frame each time is idempotent.
//
// The table is mirrored in hardware/firmware/segno_pedal_32u4 — keep them in sync.
//
// Compile-time toggle, OFF by default: define LED_GAMMA_CORRECTION=1 (an Arduino
// build flag / -D, or edit the line below) to enable the perceptual ramp. When
// off, showGamma() copies the logical frame straight through with no correction.
#ifndef LED_GAMMA_CORRECTION
#define LED_GAMMA_CORRECTION 0
#endif

#if LED_GAMMA_CORRECTION
static const uint8_t kGamma8[256] PROGMEM = {
    0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,
    0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   1,   1,   1,   1,
    1,   1,   1,   1,   1,   1,   1,   1,   1,   2,   2,   2,   2,   2,   2,   2,
    2,   3,   3,   3,   3,   3,   3,   3,   4,   4,   4,   4,   4,   5,   5,   5,
    5,   6,   6,   6,   6,   7,   7,   7,   7,   8,   8,   8,   9,   9,   9,  10,
   10,  10,  11,  11,  11,  12,  12,  13,  13,  13,  14,  14,  15,  15,  16,  16,
   17,  17,  18,  18,  19,  19,  20,  20,  21,  21,  22,  22,  23,  24,  24,  25,
   25,  26,  27,  27,  28,  29,  29,  30,  31,  32,  32,  33,  34,  35,  35,  36,
   37,  38,  39,  39,  40,  41,  42,  43,  44,  45,  46,  47,  48,  49,  50,  50,
   51,  52,  54,  55,  56,  57,  58,  59,  60,  61,  62,  63,  64,  66,  67,  68,
   69,  70,  72,  73,  74,  75,  77,  78,  79,  81,  82,  83,  85,  86,  87,  89,
   90,  92,  93,  95,  96,  98,  99, 101, 102, 104, 105, 107, 109, 110, 112, 114,
  115, 117, 119, 120, 122, 124, 126, 127, 129, 131, 133, 135, 137, 138, 140, 142,
  144, 146, 148, 150, 152, 154, 156, 158, 160, 162, 164, 167, 169, 171, 173, 175,
  177, 180, 182, 184, 186, 189, 191, 193, 196, 198, 200, 203, 205, 208, 210, 213,
  215, 218, 220, 223, 225, 228, 231, 233, 236, 239, 241, 244, 247, 249, 252, 255,
};
static inline uint8_t gamma8(uint8_t x) { return pgm_read_byte(&kGamma8[x]); }
#endif  // LED_GAMMA_CORRECTION

// Copy the logical frame into the display buffer, then latch it. Drop-in
// replacement for FastLED.show() — global brightness is still applied by show().
// With LED_GAMMA_CORRECTION on, each channel is mapped through the gamma curve;
// with it off (the default) the frame is copied through unmodified. Either way we
// copy g_leds -> g_out, since g_out is the buffer FastLED actually clocks out.
static void showGamma() {
#if LED_GAMMA_CORRECTION
  for (uint8_t i = 0; i < kNumLeds; i++) {
    g_out[i].r = gamma8(g_leds[i].r);
    g_out[i].g = gamma8(g_leds[i].g);
    g_out[i].b = gamma8(g_leds[i].b);
  }
#else
  for (uint8_t i = 0; i < kNumLeds; i++) g_out[i] = g_leds[i];
#endif
  FastLED.show();
}

static void render() {
  renderRing(); // the loop-position ring, LEDs 0..11
  if (g_haveFrame) {
    // Active bank's 4 tracks on the physical Tr1..Tr4 LEDs — solid color from
    // each track's LED state. The selected/armed track is NOT highlighted here
    // (no breathing, no blue dot); selection is shown on segno's screen.
    const uint8_t base = g_frame.active_bank * 4; // bank A: 0..3, bank B: 4..7
    for (uint8_t i = 0; i < 4; i++) {
      g_leds[kTrackLed0 + i] = ledColor(g_frame.track_leds[base + i]);
    }
    // LED 12 is the tri-state mode indicator (A1): rec red / play green / fx
    // blue from the decoded 2-bit mode (#693). SOLID, always — this LED means
    // the interaction mode and nothing else. The goodbye frame darkens
    // everything, this LED included.
    //
    // It used to BLINK red while performance-recording was armed (D-PEDAL).
    // That reading is gone (#693): armed state already lives on the screens —
    // the 7" readout carries a REC block with running elapsed, permanently in
    // view, and the stage status bar shows it too — so the pedal was
    // duplicating it and paying for the duplicate with an ambiguous MODE LED.
    // Once rec mode went solid red, "blinking red" vs "solid red" was the only
    // thing separating armed from rec mode on one 5mm dot at stage distance.
    // One signal, one meaning: the plate shows mode here and the playhead
    // colour on the ring, and neither has to be read against the other.
    g_leds[kModeLed] = g_frame.goodbye ? CRGB::Black
                                       : modeColor(g_frame.play_mode);
    g_leds[kClearLed] = g_frame.clear_fade ? CRGB::Red : CRGB::Black;
    g_leds[kBankLed] = (g_frame.active_bank == 1) ? CRGB(0, 0, 80) : CRGB::Black;
  } else {
    g_leds[kModeLed] = CRGB::Black;
    g_leds[kClearLed] = CRGB::Black;
    g_leds[kBankLed] = CRGB::Black;
    for (uint8_t i = 0; i < 4; i++) g_leds[kTrackLed0 + i] = CRGB::Black;
  }

  // Poll MIDI immediately before and after the interrupt-blocking show().
  pollMidiIn();
  showGamma();
  pollMidiIn();
}

// ---- inputs -----------------------------------------------------------------

static void pollButtons() {
  const unsigned long now = millis();
  for (uint8_t i = 0; i < PEDAL_BTN_COUNT; i++) {
    const bool raw = (digitalRead(kButtonPins[i]) == LOW); // active-low
    // Restart the stability timer whenever the raw reading flips. Contact
    // chatter keeps resetting it, so a change is only reported once the line has
    // been steady for kDebounceMs — a proper stable-for-N-ms debounce on both
    // the press and the release edges (no single-stomp double-triggers).
    if (raw != g_btnLastRaw[i]) {
      g_btnLastRaw[i] = raw;
      g_btnRawSinceMs[i] = now;
      continue;
    }
    if (raw != g_btnStable[i] && (now - g_btnRawSinceMs[i]) >= kDebounceMs) {
      g_btnStable[i] = raw;
      uint8_t msg[3];
      const int len = pedal_encode_button(i, raw ? 1 : 0, kMidiChannel, msg);
      sendBytes(msg, len);
    }
  }
}

// Encoder decode, matching the original firmware: on each clock edge, the data
// line's level vs. the clock gives the direction. Emits one relative ±1 CC per
// edge.
static void pollEncoder() {
  const uint8_t clk = (digitalRead(kEncoderClk) == HIGH) ? 1 : 0;
  if (clk == g_encClkPrev) return;
  g_encClkPrev = clk;
  const uint8_t dat = (digitalRead(kEncoderDat) == HIGH) ? 1 : 0;
  const int delta = (dat != clk) ? 1 : -1;
  uint8_t msg[3];
  const int len = pedal_encode_encoder(delta, kMidiChannel, msg);
  sendBytes(msg, len);
}

// ---- lifecycle --------------------------------------------------------------

void setup() {
  Serial.begin(31250); // serial MIDI (dualMocoLUFA on the 16U2)
  FastLED.addLeds<WS2812B, kLedPin, GRB>(g_out, kNumLeds);
  FastLED.setBrightness(64);

  for (uint8_t i = 0; i < PEDAL_BTN_COUNT; i++) {
    pinMode(kButtonPins[i], INPUT_PULLUP);
    g_btnStable[i] = false;  // released at boot
    g_btnLastRaw[i] = false;
    g_btnRawSinceMs[i] = 0;
  }
  pinMode(kEncoderClk, INPUT_PULLUP);
  pinMode(kEncoderDat, INPUT_PULLUP);
  g_encClkPrev = (digitalRead(kEncoderClk) == HIGH) ? 1 : 0;

  // Brief startup sweep so the user sees the pedal is alive before segno binds.
  for (uint8_t i = 0; i < kNumLeds; i++) {
    g_leds[i] = CRGB(0, 24, 0);
    showGamma();
    delay(15);
    g_leds[i] = CRGB::Black;
  }
  showGamma();
}

void loop() {
  pollMidiIn();
  pollButtons();
  pollEncoder();
  render(); // polls MIDI around show()
}
