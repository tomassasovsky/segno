// Segno console board v2 (#747) -- Pico 2 (RP2350) firmware.
//
// A PURE THIN CLIENT, like the pedal it replaces: it holds no looper state. It
// renders the ring and the indicator pills from the last good STATE frame segno
// pushes, and sends raw footswitch / encoder events. segno runs the behavior
// machine and is the single source of truth.
//
// Link: Serial1 = UART0, GP16 TX / GP17 RX -> the Pi's uart3 (GPIO8/9,
// /dev/ttyAMA3), 115200 8N1. Wire format: pedal_link.h, shared byte for byte
// with packages/pedal_repository and pinned by firmware/test/run_tests.sh.
//
// Half of several circuits on this board is firmware (#752): the footswitches
// and the encoder have no external pull-ups on the Pico side (INPUT_PULLUP is
// mandatory), a release edge is an RC of ~5-8 ms through the 100 nF debounce
// caps, and GP23 high puts the module's SMPS in PWM mode for a quieter ADC.
//
// Build: arduino-pico core (rp2040:rp2040:rpipico2) + Adafruit NeoPixel.
//   arduino-cli compile --fqbn rp2040:rp2040:rpipico2 firmware/console_board --output-dir firmware/console_board/build
// Flash from the Pi over SWD: README.md.

#include <Adafruit_NeoPixel.h>

#include "pedal_link.h"

// A colour before gamma; the .ino auto-prototypes need the type declared first.
struct Rgb { uint8_t r, g, b; };

static const uint8_t FW_MAJOR = 1;
static const uint8_t FW_MINOR = 1;

// ---- pin map (console_board.py GPIO table) ---------------------------------
static const uint8_t PIN_LINK_TX = 16, PIN_LINK_RX = 17;
static const uint8_t FSW_PIN[PEDAL_BTN_COUNT] = {2, 3, 4, 5, 6, 7, 8, 9, 10, 11};
static const uint8_t PIN_RING = 12, PIN_ENC_A = 13, PIN_ENC_B = 14, PIN_ENC_SW = 15;
static const uint8_t PIN_IND = 18;
// The CTRL TRS jacks: tip on ADC0/ADC1 with a 10k pull-up, ring feeding 3V3
// through 1k as the pot's top, sleeve to ground.
static const uint8_t CTRL_PIN[PEDAL_CTRL_COUNT] = {26, 27};
// The rings, sensed. On a two-switch pedal on one TRS plug (a BOSS FS-6's A&B
// jack) the second switch shorts the ring to sleeve, which the tip's ADC can
// never see. Board v2 has no trace for it: these are the expansion pads on J22
// (GP20 / GP21, otherwise unused), reached by one wire from each jack's ring
// pin. With the wire, the ring sits at ~3V (an expression pedal's pot top, or
// an open jack) and drops to 0 when that switch closes. WITHOUT the wire the
// internal pull-up holds the pin high and the ring simply never reports, so
// an unmodified board loses nothing.
static const uint8_t CTRL_RING_PIN[PEDAL_CTRL_COUNT] = {20, 21};
static const uint8_t PIN_SMPS_PWM = 23;

// ---- LEDs --------------------------------------------------------------------
// The encoder's NeoPixel Ring 24 on J6 (O65.5 / O52.3, the fitted part). Its
// WS2812 index order runs clockwise seen from the front of the panel, which is
// the direction the sweep travels, so pixel index IS ring position — no
// reversal (bench-verified 2026-09-03: reversing it ran the hump backwards).
static const uint16_t RING_N = 24;
// The indicator pills on J7, one WS2812 puck each, chained in this order along
// the faceplate. The first sits above footswitch 1 and is the mode indicator;
// then the four active-bank tracks, the clear pill and the bank pill. Same map
// the pedal this board replaces used (its LEDs 12..18).
enum {
  IND_MODE = 0,
  IND_TRACK1,
  IND_TRACK2,
  IND_TRACK3,
  IND_TRACK4,
  IND_CLEAR,
  IND_BANK,
  IND_N
};
Adafruit_NeoPixel ring(RING_N, PIN_RING, NEO_GRB + NEO_KHZ800);
Adafruit_NeoPixel ind(IND_N, PIN_IND, NEO_GRB + NEO_KHZ800);
static const uint8_t LED_BRIGHTNESS = 64;


// ---- link ----------------------------------------------------------------------
#define LINK Serial1
static const unsigned long LINK_BAUD = 115200;
// segno answers every HELLO with its current frame; if nothing arrives for
// FRAME_TIMEOUT_MS the app is gone and the panel goes dark rather than
// freezing on a stale frame. Both cadences are the protocol's (pedal_link.h).
static const unsigned long HELLO_MS = PEDAL_LINK_HELLO_MS;
static const unsigned long FRAME_TIMEOUT_MS = PEDAL_LINK_FRAME_TIMEOUT_MS;

static pedal_link_parser g_parser;
static pedal_state g_frame;
static bool g_haveFrame = false;
static bool g_frameDirty = false;  // a STATE (or timeout/goodbye) changed what to render
static unsigned long g_lastFrameMs = 0;
static unsigned long g_lastHelloMs = 0;
// How long the ring shows the master level after the encoder moves it, before
// it goes back to saying what the transport is doing. Armed with a flag rather
// than a deadline in the future: a bare `millis() + N` compared against `now`
// fires on its own initial value once millis() passes the halfway mark.
static const unsigned long GAIN_SHOW_MS = 900;
static unsigned long g_gainShownAt = 0;
static bool g_gainArmed = false;

static void sendFrame(const uint8_t *buf, size_t len) {
  LINK.write(buf, len);
}

static void sendHello() {
  uint8_t buf[PEDAL_LINK_MAX_FRAME];
  sendFrame(buf, pedal_link_encode_hello(FW_MAJOR, FW_MINOR, buf));
}

static void handleMessage(uint8_t type, const uint8_t *payload, uint8_t len) {
  switch (type) {
    case PEDAL_LINK_TYPE_STATE: {
      pedal_state decoded;
      if (pedal_link_decode_state(payload, len, &decoded)) {
        // The encoder is the master volume and has no pill of its own, so the
        // ring becomes the readout for a moment whenever the level moves.
        if (g_haveFrame && decoded.master_gain != g_frame.master_gain) {
          g_gainShownAt = millis();
          g_gainArmed = true;
        }
        g_frame = decoded;
        g_haveFrame = true;
        g_frameDirty = true;
        g_lastFrameMs = millis();
      }
      break;  // a malformed frame is dropped; the last good one is kept
    }
    default:
      break;
  }
}

static void pollLink() {
  while (LINK.available() > 0) {
    uint8_t type, len;
    const uint8_t *payload;
    if (pedal_link_parser_push(&g_parser, (uint8_t)LINK.read(), &type, &payload, &len)) {
      handleMessage(type, payload, len);
    }
  }
}

// ---- inputs -----------------------------------------------------------------------
static const unsigned long DEBOUNCE_MS = 8;
static bool g_btnStable[PEDAL_BTN_COUNT];
static bool g_btnLastRaw[PEDAL_BTN_COUNT];
static unsigned long g_btnRawSinceMs[PEDAL_BTN_COUNT];

static void pollButtons() {
  const unsigned long now = millis();
  for (uint8_t i = 0; i < PEDAL_BTN_COUNT; i++) {
    const bool raw = digitalRead(FSW_PIN[i]) == LOW;  // bare contact to GND
    // Restart the stability timer whenever the raw reading flips, so a change is
    // reported once the line has been steady for DEBOUNCE_MS on either edge.
    if (raw != g_btnLastRaw[i]) {
      g_btnLastRaw[i] = raw;
      g_btnRawSinceMs[i] = now;
      continue;
    }
    if (raw != g_btnStable[i] && now - g_btnRawSinceMs[i] >= DEBOUNCE_MS) {
      g_btnStable[i] = raw;
      uint8_t buf[PEDAL_LINK_MAX_FRAME];
      sendFrame(buf, pedal_link_encode_button(i, raw ? 1 : 0, buf));
    }
  }
}

// The EC11's detent is at BOTH-HIGH (11). One click walks 11 -> 10 -> 00 -> 01
// -> 11 one way and 11 -> 01 -> 00 -> 10 -> 11 the other, so the intermediate
// state seen LAST before returning to the detent names the direction.
//
// Counting all four transitions instead does not survive this board: pushing
// the two LED strips masks interrupts for about a millisecond every 20 ms, and
// a detent turned during that window arrives as a two-step jump, which a
// four-transition counter reads as no movement at all. It stalls forever
// rather than merely lagging — the encoder worked with the panel dark and died
// the moment segno started sending frames (bench, 2026-09-03). Remembering the
// last intermediate state needs to see only ONE of the three, so a masked
// window costs precision, never a whole click. Footswitches were never
// affected: their 8 ms debounce outlives any push.
//
// Sampled from a pin-change interrupt AND from the loop, including either side
// of the LED pushes: whichever sees the edge first records it, and the other
// finds nothing to do.
static const uint8_t ENC_DETENT = 3;      // both lines high, between clicks
static volatile uint8_t g_encLast = ENC_DETENT;
static volatile uint8_t g_encMark = 0;    // last intermediate state, 0 = none
static volatile int8_t g_encDetents = 0;  // whole clicks the link still owes

static void encoderSample() {
  const uint8_t cur = (uint8_t)((digitalRead(PIN_ENC_A) << 1) | digitalRead(PIN_ENC_B));
  if (cur == g_encLast) return;
  g_encLast = cur;
  if (cur == ENC_DETENT) {
    // Saturate rather than wrap: a spin faster than the link drains is worth
    // a lost click, never a reversed one.
    if (g_encMark == 1 && g_encDetents < 127) g_encDetents++;
    if (g_encMark == 2 && g_encDetents > -128) g_encDetents--;
    g_encMark = 0;
    return;
  }
  // 01 and 10 name a direction; 00 is the midpoint and names none, so it
  // leaves the mark alone.
  if (cur == 1 || cur == 2) g_encMark = cur;
}

// Samples from the main loop. The ISR can preempt any instruction of
// encoderSample(), and the two share every variable it touches, so a
// half-applied sample would race an ISR's: one click could be credited twice,
// or the wrong way. Mask for the handful of instructions it takes.
static void encoderSampleFromLoop() {
  noInterrupts();
  encoderSample();
  interrupts();
}

// Drains whole clicks the sampler counted, one ENCODER message each.
static void pollEncoder() {
  encoderSampleFromLoop();
  for (;;) {
    // The common case by far is nothing owed; read it before masking.
    if (!g_encDetents) return;
    noInterrupts();
    const int8_t owed = g_encDetents;
    if (owed > 0) {
      g_encDetents--;
    } else if (owed < 0) {
      g_encDetents++;
    }
    interrupts();
    if (!owed) return;
    uint8_t buf[PEDAL_LINK_MAX_FRAME];
    sendFrame(buf, pedal_link_encode_encoder(owed > 0 ? 1 : -1, buf));
  }
}

// ---- CTRL jacks --------------------------------------------------------------
// One jack takes an expression pedal OR a footswitch, and nobody tells the
// board which. A switch only ever sits at the rails; a pot passes through the
// middle and stays there. So a jack is a switch until it is caught holding an
// intermediate reading, and from then on it is an expression pedal. Measured
// on the bench (2026-09-03): a BOSS FS-6 reads 10 and 4095, an M-Audio EX-P
// sweeps 385..4095.
//
// The classification only ever moves one way per session. Reverting on a pot
// parked at an end would make a pedal held at heel or toe flicker between
// meanings, and the app binds the two to different things.
static const uint16_t CTRL_MAX = 4095;
static const uint16_t CTRL_LOW = CTRL_MAX / 8;        // below: switch closed
static const uint16_t CTRL_HIGH = CTRL_MAX - CTRL_MAX / 8;  // above: open
static const uint16_t CTRL_DEADBAND = 24;  // ~0.6%, above the noise floor
static const unsigned long CTRL_SWITCH_DEBOUNCE_MS = 8;
static const unsigned long CTRL_SAMPLE_MS = 10;

// An expression pedal never uses the whole scale: the tip's 10k pull-up and
// the 1k feeding the pot's top compress both ends, and every pedal's travel
// and range knob differ again (an M-Audio EX-P covers 385..4095 of 0..4095).
// Where the ends really are is NOT decided here. This board forgets everything
// at power-off and cannot tell a plug sliding in from a pedal at its stop, so
// it reports the raw position and segno learns the ends — deliberately, from
// a sweep the user makes, and keeps them across reboots.
static uint8_t g_ctrlKind[PEDAL_CTRL_COUNT];
static uint16_t g_ctrlRaw[PEDAL_CTRL_COUNT];
static uint8_t g_ctrlSent[PEDAL_CTRL_COUNT];
static bool g_ctrlHaveSent[PEDAL_CTRL_COUNT];
// One debounced switch per contact: [jack][contact].
static bool g_ctrlSwitchClosed[PEDAL_CTRL_COUNT][PEDAL_CTRL_CONTACT_COUNT];
static bool g_ctrlSwitchRaw[PEDAL_CTRL_COUNT][PEDAL_CTRL_CONTACT_COUNT];
static unsigned long g_ctrlSwitchSinceMs[PEDAL_CTRL_COUNT][PEDAL_CTRL_CONTACT_COUNT];
static unsigned long g_ctrlLastSampleMs = 0;

static uint16_t ctrlSample(uint8_t pin) {
  uint32_t total = 0;
  for (uint8_t i = 0; i < 8; i++) total += analogRead(pin);
  return (uint16_t)(total / 8);
}

static void sendCtrl(uint8_t jack, uint8_t contact, uint8_t kind, uint8_t value) {
  uint8_t buf[PEDAL_LINK_MAX_FRAME];
  sendFrame(buf, pedal_link_encode_ctrl(jack, contact, kind, value, buf));
  if (contact == PEDAL_CTRL_TIP && kind == PEDAL_CTRL_KIND_EXPRESSION) {
    g_ctrlSent[jack] = value;
    g_ctrlHaveSent[jack] = true;
  }
}

// Debounced on both edges like the footswitches. `closed` is the contact at
// ground; reports the edge once it has held for CTRL_SWITCH_DEBOUNCE_MS.
static void pollCtrlSwitch(uint8_t jack, uint8_t contact, bool closed, unsigned long now) {
  if (closed != g_ctrlSwitchRaw[jack][contact]) {
    g_ctrlSwitchRaw[jack][contact] = closed;
    g_ctrlSwitchSinceMs[jack][contact] = now;
    return;
  }
  if (closed != g_ctrlSwitchClosed[jack][contact] &&
      now - g_ctrlSwitchSinceMs[jack][contact] >= CTRL_SWITCH_DEBOUNCE_MS) {
    g_ctrlSwitchClosed[jack][contact] = closed;
    sendCtrl(jack, contact, PEDAL_CTRL_KIND_SWITCH, closed ? 255 : 0);
  }
}

static void pollCtrl() {
  const unsigned long now = millis();
  if (now - g_ctrlLastSampleMs < CTRL_SAMPLE_MS) return;
  g_ctrlLastSampleMs = now;

  for (uint8_t j = 0; j < PEDAL_CTRL_COUNT; j++) {
    // The ring is a switch or nothing, whatever the tip is doing.
    pollCtrlSwitch(j, PEDAL_CTRL_RING, digitalRead(CTRL_RING_PIN[j]) == LOW, now);

    const uint16_t raw = ctrlSample(CTRL_PIN[j]);
    g_ctrlRaw[j] = raw;
    if (raw > CTRL_LOW && raw < CTRL_HIGH) {
      g_ctrlKind[j] = PEDAL_CTRL_KIND_EXPRESSION;
    }

    if (g_ctrlKind[j] == PEDAL_CTRL_KIND_EXPRESSION) {
      // The 12-bit reading's top byte: 256 steps over the whole scale, of
      // which a pedal uses ~230 — twice what a MIDI CC resolves.
      const uint8_t value = (uint8_t)(raw >> 4);
      const int diff = (int)value - (int)g_ctrlSent[j];
      const int deadband = (int)(CTRL_DEADBAND * 255u / CTRL_MAX);
      // Always report the rails exactly: a deadband that swallows the last
      // step leaves a pedal pushed to its stop reporting "nearly there".
      const bool atEnd = value == 0 || value == 255;
      if (!g_ctrlHaveSent[j] || (atEnd && value != g_ctrlSent[j]) ||
          diff > deadband || diff < -deadband) {
        sendCtrl(j, PEDAL_CTRL_TIP, PEDAL_CTRL_KIND_EXPRESSION, value);
      }
      continue;
    }

    // Closed is the tip pulled to ground; open is the 10k holding it at the
    // rail.
    pollCtrlSwitch(j, PEDAL_CTRL_TIP, raw < CTRL_LOW, now);
  }
}

// ---- rendering -----------------------------------------------------------------------
// Perceptual gamma is applied HERE, once, as a colour is set: a WS2812's duty
// cycle is linear but the eye's response is not, so without it the sweep's dim
// steps crowd together. It must not be applied to the stored buffer on every
// show(): the frozen-ring branch below keeps its pixels as they are, and a
// per-frame in-place gamma would decay them to black within a few ticks.
static uint32_t rgb(uint8_t r, uint8_t g, uint8_t b) {
  return Adafruit_NeoPixel::gamma32(Adafruit_NeoPixel::Color(r, g, b));
}
static uint32_t scaled(uint8_t r, uint8_t g, uint8_t b, uint8_t level) {
  return rgb((uint8_t)((r * (uint16_t)level) / 255), (uint8_t)((g * (uint16_t)level) / 255),
             (uint8_t)((b * (uint16_t)level) / 255));
}

static Rgb ledColor(uint8_t led) {
  switch (led) {
    case PEDAL_LED_GREEN: return {0, 255, 0};
    case PEDAL_LED_RED: return {255, 0, 0};
    case PEDAL_LED_BLUE: return {0, 0, 255};
    default: return {0, 0, 0};
  }
}
// The mode pill's colour: rec red, play green, FX blue. Solid, always — this
// pill means the interaction mode and nothing else.
static Rgb modeColor(uint8_t mode) {
  switch (mode) {
    case PEDAL_MODE_PLAY: return {0, 255, 0};
    case PEDAL_MODE_FX: return {0, 0, 255};
    default: return {255, 0, 0};  // PEDAL_MODE_REC
  }
}
static Rgb globalColor(uint8_t color) {
  switch (color) {
    case PEDAL_GLOBAL_GREEN: return {0, 255, 0};
    case PEDAL_GLOBAL_RED: return {255, 0, 0};
    case PEDAL_GLOBAL_AMBER: return {255, 255, 0};  // yellow, on the owner's call
    case PEDAL_GLOBAL_BLUE: return {0, 0, 255};
    default: return {0, 0, 0};
  }
}

// A smooth brightness hump travels the ring at a FIXED cadence — it says
// "something is happening", in the activity colour, and deliberately does not
// track the loop: one revolution per loop is unreadably slow at any musical
// length, and the playhead is already on the screens (owner's call,
// 2026-09-03).
//
// A Stop that leaves a loop loaded freezes the hump where it was. With nothing
// loaded and nothing playing the ring breathes green so it reads as alive; the
// breathe never reaches black, so an idle panel still shows the board is up.
static const unsigned long RING_MS_PER_REV = 700;
static const unsigned long BREATHE_MS = 1200;
// The dimmest the breathe goes, as a fraction of full: never off.
static const float BREATHE_FLOOR = 0.35f;
static const float RING_WIDTH = 11.0f;
static float g_ringPhase = 0.0f;  // hump centre, 0..RING_N
static unsigned long g_ringLastMs = 0;
// What the ring buffer currently holds. One question, asked once: every branch
// of renderRing() states which view it just painted, and the caller pushes the
// strip only when that key changed. Per-branch latches were tried and each one
// grew its own reset rule — the arc forgot to restore what it painted over,
// and the dark branch forgot to repaint at all.
enum RingView : uint8_t { RING_NONE = 0, RING_DARK, RING_ARC, RING_HUMP, RING_BREATHE };
static uint8_t g_ringView = RING_NONE;
static uint8_t g_ringKeyA = 0;  // arc: lit pixels; hump: phase in whole pixels
static uint8_t g_ringKeyB = 0;  // the colour that view was painted in
// The colour the hump was last drawn in. A Stop freezes the hump but sends
// GLOBAL_OFF, so the frame no longer says what colour to freeze it at; without
// remembering it, restoring the hump paints it black.
static Rgb g_humpColour = {0, 255, 0};

// Draws the hump at the current phase, in `c`.
static void paintHump(Rgb c) {
  for (uint16_t i = 0; i < RING_N; i++) {
    float d = fabsf((float)i - g_ringPhase);
    if (d > RING_N / 2.0f) d = RING_N - d;
    const float dn = d / RING_WIDTH;
    uint8_t level = 0;
    if (dn < 1.0f) {
      const float b = 1.0f - dn * sqrtf(dn);  // dn^1.5, without powf
      level = (uint8_t)(b * 255.0f + 0.5f);
    }
    ring.setPixelColor(i, scaled(c.r, c.g, c.b, level));
  }
}

// Returns whether the ring buffer changed and needs pushing.
static bool renderRing() {
  const unsigned long now = millis();
  const unsigned long dt = now - g_ringLastMs;
  g_ringLastMs = now;

  // Records which view is now in the buffer; returns whether that is new.
  auto settle = [](uint8_t view, uint8_t keyA, uint8_t keyB) -> bool {
    const bool changed =
        g_ringView != view || g_ringKeyA != keyA || g_ringKeyB != keyB;
    g_ringView = view;
    g_ringKeyA = keyA;
    g_ringKeyB = keyB;
    return changed;
  };

  if (!g_haveFrame || g_frame.goodbye) {
    if (g_ringView == RING_DARK) return false;
    ring.clear();
    return settle(RING_DARK, 0, 0);
  }
  const Rgb activity = globalColor(g_frame.global_color);

  // The master level, as a filled arc, for a moment after it changes. In the
  // ring's own colours: the activity colour it is already showing, or the
  // standby green it breathes when there is no activity to report. Elapsed
  // form, so it is wrap-safe AND cannot fire on a stale deadline.
  if (g_gainArmed && now - g_gainShownAt < GAIN_SHOW_MS) {
    const bool coloured = activity.r || activity.g || activity.b;
    const Rgb c = coloured ? activity : Rgb{0, 255, 0};
    const uint8_t lit = (uint8_t)((g_frame.master_gain * RING_N + 254) / 255);
    if (!settle(RING_ARC, lit, g_frame.global_color)) return false;
    for (uint16_t i = 0; i < RING_N; i++) {
      ring.setPixelColor(i, i < lit ? rgb(c.r, c.g, c.b) : 0);
    }
    return true;
  }
  g_gainArmed = false;

  const bool active = (activity.r || activity.g || activity.b) && g_frame.global_color != PEDAL_GLOBAL_BLUE;
  // A Stop with a loop still loaded freezes the hump where it was — in the
  // colour it was playing in, which the frame no longer carries.
  if (!active && g_frame.loop_length_micros > 0) {
    if (!settle(RING_HUMP, (uint8_t)g_ringPhase, PEDAL_GLOBAL_COUNT)) {
      return false;
    }
    paintHump(g_humpColour);
    return true;
  }
  if (!active) {  // standby: breathe green
    const unsigned long p = now % BREATHE_MS;
    const unsigned long half = BREATHE_MS / 2;
    float t = (p < half) ? (p / (float)half) : (1.0f - (p - half) / (float)half);
    t = t * t * (3.0f - 2.0f * t);
    const uint8_t level =
        (uint8_t)((BREATHE_FLOOR + (1.0f - BREATHE_FLOOR) * t) * 255.0f + 0.5f);
    const uint32_t green = scaled(0, 255, 0, level);  // same for every pixel
    for (uint16_t i = 0; i < RING_N; i++) ring.setPixelColor(i, green);
    settle(RING_BREATHE, level, 0);
    return true;  // it animates every tick
  }
  g_ringPhase =
      fmodf(g_ringPhase + (float)dt / (float)RING_MS_PER_REV * (float)RING_N, (float)RING_N);
  g_humpColour = activity;
  settle(RING_HUMP, (uint8_t)g_ringPhase, g_frame.global_color);
  paintHump(activity);
  return true;
}

// The pills only change with the frame; the caller pushes them when it did.
static void renderIndicators() {
  if (!g_haveFrame || g_frame.goodbye) {
    ind.clear();
    return;
  }
  // The active bank's four tracks, solid, from each track's LED state. Selection
  // is not highlighted here; it lives on the screens.
  const uint8_t base = g_frame.active_bank * 4;
  for (uint8_t t = 0; t < 4; t++) {
    const Rgb c = ledColor(g_frame.track_leds[base + t]);
    ind.setPixelColor(IND_TRACK1 + t, rgb(c.r, c.g, c.b));
  }
  const Rgb m = modeColor(g_frame.mode);
  ind.setPixelColor(IND_MODE, rgb(m.r, m.g, m.b));
  ind.setPixelColor(IND_CLEAR, g_frame.clear_fade ? rgb(255, 0, 0) : 0);
  ind.setPixelColor(IND_BANK, g_frame.active_bank == 1 ? rgb(0, 0, 80) : 0);
}

// show() is a blocking PIO push with interrupts masked (~30 us per pixel), so
// a strip is pushed only when its buffer changed — plus once every REFRESH_MS
// regardless, so a pixel that glitched still heals.
static const unsigned long RENDER_MS = 20;
static const unsigned long REFRESH_MS = 250;
static unsigned long g_lastRenderMs = 0;
static unsigned long g_lastRefreshMs = 0;

// ---- lifecycle ------------------------------------------------------------------------
void setup() {
  pinMode(PIN_SMPS_PWM, OUTPUT);
  digitalWrite(PIN_SMPS_PWM, HIGH);
  pinMode(LED_BUILTIN, OUTPUT);
  for (uint8_t i = 0; i < PEDAL_BTN_COUNT; i++) {
    pinMode(FSW_PIN[i], INPUT_PULLUP);
    g_btnStable[i] = false;
    g_btnLastRaw[i] = false;
    g_btnRawSinceMs[i] = 0;
  }
  for (uint8_t j = 0; j < PEDAL_CTRL_COUNT; j++) {
    pinMode(CTRL_PIN[j], INPUT);  // the board's own 10k biases the tip
    // Pulled up INTERNALLY: unwired (an unmodified v2) it reads open forever
    // and never reports; wired, ~3V from the jack overrides nothing.
    pinMode(CTRL_RING_PIN[j], INPUT_PULLUP);
    g_ctrlKind[j] = PEDAL_CTRL_KIND_SWITCH;
    g_ctrlRaw[j] = CTRL_MAX;
    g_ctrlSent[j] = 0;
    g_ctrlHaveSent[j] = false;
    for (uint8_t c = 0; c < PEDAL_CTRL_CONTACT_COUNT; c++) {
      g_ctrlSwitchClosed[j][c] = false;
      g_ctrlSwitchRaw[j][c] = false;
      g_ctrlSwitchSinceMs[j][c] = 0;
    }
  }
  analogReadResolution(12);
  pinMode(PIN_ENC_A, INPUT_PULLUP);
  pinMode(PIN_ENC_B, INPUT_PULLUP);
  pinMode(PIN_ENC_SW, INPUT_PULLUP);
  g_encLast = (uint8_t)((digitalRead(PIN_ENC_A) << 1) | digitalRead(PIN_ENC_B));
  attachInterrupt(digitalPinToInterrupt(PIN_ENC_A), encoderSample, CHANGE);
  attachInterrupt(digitalPinToInterrupt(PIN_ENC_B), encoderSample, CHANGE);

  LINK.setTX(PIN_LINK_TX);
  LINK.setRX(PIN_LINK_RX);
  LINK.begin(LINK_BAUD);
  pedal_link_parser_init(&g_parser);

  ring.begin();
  ring.setBrightness(LED_BRIGHTNESS);
  ind.begin();
  ind.setBrightness(LED_BRIGHTNESS);

  // A brief green sweep so the panel visibly comes alive before segno's first frame.
  for (uint16_t i = 0; i < RING_N; i++) {
    ring.setPixelColor(i, rgb(0, 24, 0));
    ring.show();
    delay(12);
  }
  ring.clear();
  ring.show();
  ind.clear();
  ind.show();

  sendHello();
  g_lastHelloMs = millis();
}

void loop() {
  pollLink();
  pollButtons();
  pollEncoder();
  pollCtrl();

  const unsigned long now = millis();
  if (now - g_lastHelloMs >= HELLO_MS) {
    g_lastHelloMs = now;
    sendHello();
    digitalWrite(LED_BUILTIN, !digitalRead(LED_BUILTIN));  // 0.5 Hz heartbeat
  }
  if (g_haveFrame && now - g_lastFrameMs > FRAME_TIMEOUT_MS) {
    g_haveFrame = false;
    g_frameDirty = true;
  }
  if (now - g_lastRenderMs >= RENDER_MS) {
    g_lastRenderMs = now;
    const bool refresh = now - g_lastRefreshMs >= REFRESH_MS;
    if (refresh) g_lastRefreshMs = now;
    const bool ringChanged = renderRing();
    const bool frameChanged = g_frameDirty;
    g_frameDirty = false;
    if (frameChanged) renderIndicators();
    // show() masks interrupts briefly: drain the link and sample the encoder
    // either side of each push so a click turned across one cannot be lost.
    pollLink();
    encoderSampleFromLoop();
    if (ringChanged || refresh) ring.show();
    encoderSampleFromLoop();
    if (frameChanged || refresh) ind.show();
    encoderSampleFromLoop();
    pollLink();
  }
}
