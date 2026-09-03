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
static const uint8_t FW_MINOR = 0;

// ---- pin map (console_board.py GPIO table) ---------------------------------
static const uint8_t PIN_LINK_TX = 16, PIN_LINK_RX = 17;
static const uint8_t FSW_PIN[PEDAL_BTN_COUNT] = {2, 3, 4, 5, 6, 7, 8, 9, 10, 11};
static const uint8_t PIN_RING = 12, PIN_ENC_A = 13, PIN_ENC_B = 14, PIN_ENC_SW = 15;
static const uint8_t PIN_IND = 18;
static const uint8_t PIN_SMPS_PWM = 23;

// ---- LEDs --------------------------------------------------------------------
// The encoder's NeoPixel Ring 24 on J6 (O65.5 / O52.3, the fitted part).
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

// The sweep travels clockwise seen from the front of the panel. WS2812 index
// order is a property of the fitted ring and of which face you view it from,
// so it cannot be inferred: on the Ring 24 fitted here, index order already
// runs clockwise from the front, so the sweep must NOT be reversed
// (bench-verified 2026-09-03: reversing it ran the hump backwards).
static const bool RING_REVERSE = false;

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
// it goes back to saying what the transport is doing.
static const unsigned long GAIN_SHOW_MS = 900;
static unsigned long g_gainShownUntil = 0;

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
          g_gainShownUntil = millis() + GAIN_SHOW_MS;
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

// Drains whole clicks the sampler counted, one ENCODER message each.
static void pollEncoder() {
  encoderSample();
  for (;;) {
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

static inline uint16_t ringIndex(uint16_t i) {
  return RING_REVERSE ? (uint16_t)((RING_N - 1) - i) : i;
}

// A smooth brightness hump travels around the ring, coloured by the activity
// colour segno sends (red recording / amber overdubbing / green playing).
//
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
static bool g_ringDark = false;  // the ring buffer is already all-black

// Returns whether the ring buffer changed and needs pushing.
static bool renderRing() {
  const unsigned long now = millis();
  const unsigned long dt = now - g_ringLastMs;
  g_ringLastMs = now;
  if (!g_haveFrame || g_frame.goodbye) {
    // Clear once, then say nothing changed: without the latch this pushes an
    // unchanged black buffer at every tick, exactly while the board is
    // waiting on the UART. REFRESH_MS still heals a glitched pixel.
    if (g_ringDark) return false;
    ring.clear();
    g_ringDark = true;
    return true;
  }
  g_ringDark = false;
  const Rgb activity = globalColor(g_frame.global_color);

  // The master level, as a filled arc, for a moment after it changes. In the
  // ring's own colours: the activity colour it is already showing, or the
  // standby green it breathes when there is no activity to report.
  if (now < g_gainShownUntil) {
    const bool lit_colour = activity.r || activity.g || activity.b;
    const Rgb c = lit_colour ? activity : (Rgb){0, 255, 0};
    const uint16_t lit = (uint16_t)((g_frame.master_gain * RING_N + 254) / 255);
    for (uint16_t i = 0; i < RING_N; i++) {
      ring.setPixelColor(ringIndex(i), i < lit ? rgb(c.r, c.g, c.b) : 0);
    }
    return true;
  }

  const bool active = (activity.r || activity.g || activity.b) && g_frame.global_color != PEDAL_GLOBAL_BLUE;
  // A Stop with a loop still loaded freezes the ring where it was.
  if (!active && g_frame.loop_length_micros > 0) return false;
  if (!active) {  // standby: breathe green
    const unsigned long p = now % BREATHE_MS;
    const unsigned long half = BREATHE_MS / 2;
    float t = (p < half) ? (p / (float)half) : (1.0f - (p - half) / (float)half);
    t = t * t * (3.0f - 2.0f * t);
    const uint8_t level =
        (uint8_t)((BREATHE_FLOOR + (1.0f - BREATHE_FLOOR) * t) * 255.0f + 0.5f);
    const uint32_t green = scaled(0, 255, 0, level);  // same for every pixel
    for (uint16_t i = 0; i < RING_N; i++) ring.setPixelColor(i, green);
    return true;
  }
  g_ringPhase =
      fmodf(g_ringPhase + (float)dt / (float)RING_MS_PER_REV * (float)RING_N, (float)RING_N);
  for (uint16_t i = 0; i < RING_N; i++) {
    float d = fabsf((float)i - g_ringPhase);
    if (d > RING_N / 2.0f) d = RING_N - d;
    const float dn = d / RING_WIDTH;
    uint8_t level = 0;
    if (dn < 1.0f) {
      const float b = 1.0f - dn * sqrtf(dn);  // dn^1.5, without powf
      level = (uint8_t)(b * 255.0f + 0.5f);
    }
    ring.setPixelColor(ringIndex(i), scaled(activity.r, activity.g, activity.b, level));
  }
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
    ring.setPixelColor(ringIndex(i), rgb(0, 24, 0));
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
    encoderSample();
    if (ringChanged || refresh) ring.show();
    encoderSample();
    if (frameChanged || refresh) ind.show();
    encoderSample();
    pollLink();
  }
}
