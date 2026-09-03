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
// the faceplate (#792: the four transport pedals carry no pill).
enum { IND_TRACK1 = 0, IND_TRACK2, IND_TRACK3, IND_TRACK4, IND_CLEAR, IND_BANK, IND_N };
Adafruit_NeoPixel ring(RING_N, PIN_RING, NEO_GRB + NEO_KHZ800);
Adafruit_NeoPixel ind(IND_N, PIN_IND, NEO_GRB + NEO_KHZ800);
static const uint8_t LED_BRIGHTNESS = 64;

// Direction the ring's sweep travels, seen from the front of the panel. WS2812
// index order is a property of the fitted ring and of which face you view it
// from, so it cannot be inferred; clockwise is the owner's call. Flip if the
// bench shows it running backwards.
static const bool RING_CLOCKWISE = true;

// ---- link ----------------------------------------------------------------------
#define LINK Serial1
static const unsigned long LINK_BAUD = 115200;
static const unsigned long HELLO_MS = 1000;
// segno re-pushes the frame at least every second (its keep-alive); if nothing
// arrives for this long the app is gone and the panel goes dark rather than
// freezing on a stale frame.
static const unsigned long FRAME_TIMEOUT_MS = 5000;

static pedal_link_parser g_parser;
static pedal_state g_frame;
static bool g_haveFrame = false;
static unsigned long g_lastFrameMs = 0;
static unsigned long g_lastHelloMs = 0;
static unsigned long g_lastLoopTopMs = 0;  // recorded, not yet used (loop-synced ring is future work)

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
        g_frame = decoded;
        g_haveFrame = true;
        g_lastFrameMs = millis();
      }
      break;  // a malformed frame is dropped; the last good one is kept
    }
    case PEDAL_LINK_TYPE_LOOP_TOP:
      g_lastLoopTopMs = millis();
      break;
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

// Gray-code transition table, signed so CLOCKWISE counts up on the fitted EC11
// (bench-verified 2026-09-03). One detent is four transitions; one ENCODER
// message per detent.
static const int8_t ENC_T[16] = {0, 1, -1, 0, -1, 0, 0, 1, 1, 0, 0, -1, 0, -1, 1, 0};
static uint8_t g_encPrev = 0;
static int8_t g_encAccum = 0;

static void pollEncoder() {
  const uint8_t cur = (uint8_t)((digitalRead(PIN_ENC_A) << 1) | digitalRead(PIN_ENC_B));
  const int8_t d = ENC_T[(g_encPrev << 2) | cur];
  g_encPrev = cur;
  if (!d) return;
  g_encAccum = (int8_t)(g_encAccum + d);
  if (g_encAccum >= 4 || g_encAccum <= -4) {
    uint8_t buf[PEDAL_LINK_MAX_FRAME];
    sendFrame(buf, pedal_link_encode_encoder(g_encAccum > 0 ? 1 : -1, buf));
    g_encAccum = 0;
  }
}

// ---- rendering -----------------------------------------------------------------------
static uint32_t rgb(uint8_t r, uint8_t g, uint8_t b) { return Adafruit_NeoPixel::Color(r, g, b); }
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
static Rgb globalColor(uint8_t color) {
  switch (color) {
    case PEDAL_GLOBAL_GREEN: return {0, 255, 0};
    case PEDAL_GLOBAL_RED: return {255, 0, 0};
    case PEDAL_GLOBAL_AMBER: return {255, 150, 0};
    case PEDAL_GLOBAL_BLUE: return {0, 0, 255};
    default: return {0, 0, 0};
  }
}

static inline uint16_t ringIndex(float logical) {
  uint16_t i = (uint16_t)logical % RING_N;
  return RING_CLOCKWISE ? (uint16_t)((RING_N - 1) - i) : i;
}

// A smooth brightness hump rotates around the ring, colored by the activity
// color segno sends (red recording / amber overdubbing / green playing), a dim
// neutral glow when there is no activity, frozen in place on a Stop that leaves
// a loop loaded, and a slow green breathe at rest with nothing loaded. Ported
// from the pedal's renderRing(); widths scaled from 12 to 24 pixels.
static const unsigned long RING_MS_PER_REV = 700;
static const unsigned long BREATHE_MS = 2400;
static const float RING_WIDTH = 11.0f;
static const float RING_SHAPE = 1.5f;
static const Rgb RING_IDLE_GLOW = {0x3A, 0x3A, 0x3D};
static float g_ringPhase = 0.0f;
static unsigned long g_ringLastMs = 0;

static void renderRing() {
  const unsigned long now = millis();
  const unsigned long dt = now - g_ringLastMs;
  g_ringLastMs = now;
  if (!g_haveFrame || g_frame.goodbye) {
    ring.clear();
    return;
  }
  const Rgb activity = globalColor(g_frame.global_color);
  const bool active = (activity.r || activity.g || activity.b) && g_frame.global_color != PEDAL_GLOBAL_BLUE;
  // A Stop with a loop still loaded freezes the ring where it was.
  if (!active && g_frame.loop_length_micros > 0) return;
  if (!active) {  // standby: breathe green
    const unsigned long p = now % BREATHE_MS;
    const unsigned long half = BREATHE_MS / 2;
    float t = (p < half) ? (p / (float)half) : (1.0f - (p - half) / (float)half);
    t = t * t * (3.0f - 2.0f * t);
    const uint8_t level = (uint8_t)((0.15f + 0.85f * t) * 255.0f + 0.5f);
    for (uint16_t i = 0; i < RING_N; i++) ring.setPixelColor(i, scaled(0, 255, 0, level));
    return;
  }
  const Rgb sweep = g_frame.global_color == PEDAL_GLOBAL_OFF ? RING_IDLE_GLOW : activity;
  g_ringPhase += (float)dt / (float)RING_MS_PER_REV * (float)RING_N;
  while (g_ringPhase >= (float)RING_N) g_ringPhase -= (float)RING_N;
  for (uint16_t i = 0; i < RING_N; i++) {
    float d = fabsf((float)i - g_ringPhase);
    if (d > RING_N / 2.0f) d = RING_N - d;
    const float dn = d / RING_WIDTH;
    uint8_t level = 0;
    if (dn < 1.0f) {
      float b = 1.0f - powf(dn, RING_SHAPE);
      if (b < 0.0f) b = 0.0f;
      level = (uint8_t)(b * 255.0f + 0.5f);
    }
    ring.setPixelColor(ringIndex((float)i), scaled(sweep.r, sweep.g, sweep.b, level));
  }
}

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
  ind.setPixelColor(IND_CLEAR, g_frame.clear_fade ? rgb(255, 0, 0) : 0);
  ind.setPixelColor(IND_BANK, g_frame.active_bank == 1 ? rgb(0, 0, 80) : 0);
}

static void show() {
  // Perceptual gamma so the sweep's dim steps read evenly; gamma32(0) is 0.
  for (uint16_t i = 0; i < RING_N; i++) ring.setPixelColor(i, ring.gamma32(ring.getPixelColor(i)));
  for (uint16_t i = 0; i < IND_N; i++) ind.setPixelColor(i, ind.gamma32(ind.getPixelColor(i)));
  ring.show();
  ind.show();
}

static const unsigned long RENDER_MS = 20;
static unsigned long g_lastRenderMs = 0;

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
  g_encPrev = (uint8_t)((digitalRead(PIN_ENC_A) << 1) | digitalRead(PIN_ENC_B));

  LINK.setTX(PIN_LINK_TX);
  LINK.setRX(PIN_LINK_RX);
  LINK.begin(LINK_BAUD);
  pedal_link_parser_init(&g_parser);

  ring.begin();
  ring.setBrightness(LED_BRIGHTNESS);
  ind.begin();
  ind.setBrightness(LED_BRIGHTNESS);

  // A brief green sweep so the panel visibly comes alive before segno binds.
  for (uint16_t i = 0; i < RING_N; i++) {
    ring.setPixelColor(ringIndex((float)i), rgb(0, 24, 0));
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
  if (g_haveFrame && now - g_lastFrameMs > FRAME_TIMEOUT_MS) g_haveFrame = false;
  if (now - g_lastRenderMs >= RENDER_MS) {
    g_lastRenderMs = now;
    renderRing();
    renderIndicators();
    pollLink();  // show() blocks interrupts briefly; drain before and after
    show();
    pollLink();
  }
}
