// Segno ring carrier v3 -- XIAO RP2350 firmware: the encoder and the LED ring.
//
// The console board's Pico sends a five-byte ring state over the private ring
// link (SegnoRing's ring_link.h); this board renders it and reports cumulative
// encoder and button counters back. It holds no looper state and never sees the
// app's pedal-link frames, so a pedal-link protocol change does not touch it.
//
// Build:
//   arduino-cli compile --libraries firmware/libraries --fqbn rp2040:rp2040:seeed_xiao_rp2350 firmware/ring_board --output-dir firmware/ring_board/build
//   python3 -I firmware/ring_board/seal.py firmware/ring_board/build/ring_board.ino.elf firmware/ring_board/build
// Install once over USB (README.md): the partition table, then the sealed UF2.
// After that the Pi updates it over the ring link (ring_updater.h).

#include <Adafruit_NeoPixel.h>
#include <SerialPIO.h>
#include <SegnoRing.h>
#include "panel_pixels.h"
#include "ring_updater.h"

// A colour before gamma; the .ino auto-prototypes need the type declared first.
struct Rgb { uint8_t r, g, b; };

// The firmware's own version, reported in the update HELLO and sealed into the
// image (seal.py reads these two lines). Bump it with every change: the Pi
// updates the ring when the version differs from the image it ships.
static const uint8_t FW_MAJOR = 1;
static const uint8_t FW_MINOR = 1;  // 1.1: dims with the screens (#1349)

// Seeed variant pin aliases, matching ring_board.py's D-number pads.
static const uint8_t PIN_RING = D0, PIN_ENC_A = D1, PIN_ENC_B = D2, PIN_ENC_SW = D3;
// TX D10/GP3 -> console GP14; RX D9/GP4 <- GP13. The receive buffer holds two
// update chunks, so a slow loop pass cannot drop one.
SerialPIO ringLink(D10, D9, 2048);
RingUpdater<SerialPIO> g_updater(ringLink, FW_MAJOR, FW_MINOR);

// ---- LEDs ---------------------------------------------------------------------
// The console strip ring (#1090): 35 pixels of the 144/m strip, pixel 0 where
// the strip starts, indices running clockwise.
static const uint16_t RING_N = 35;
// PIO + DMA, so the link and encoder interrupts keep running during a push.
PanelPixels ring(RING_N, PIN_RING);
static uint32_t g_pixels[RING_N];
static const uint8_t RING_AMBIENT_BRIGHTNESS = 96;
static const uint32_t RING_CHANNEL_BUDGET = RING_N * 3UL * RING_AMBIENT_BRIGHTNESS;

// ---- link -----------------------------------------------------------------------
static ring_link::Parser g_parser;
static ring_link::RingState g_state;
static bool g_haveState = false;
static uint32_t g_lastStateMs = 0, g_lastSnapshotMs = 0, g_lastRenderMs = 0, g_lastRefreshMs = 0;
// How long the ring shows the master level after the encoder moves it. Armed
// with a flag rather than a deadline in the future: a bare `millis() + N`
// compared against `now` fires on its own initial value once millis() wraps.
static const uint32_t GAIN_SHOW_MS = 900;
static uint32_t g_gainShownAt = 0;
static bool g_gainArmed = false;

static void pollState() {
  while (ringLink.available() > 0) {
    const uint8_t byte = (uint8_t)ringLink.read();
    g_updater.push(byte, millis());
    uint8_t type;
    const uint8_t *payload;
    if (!g_parser.push(byte, type, payload) || type != ring_link::STATE) continue;
    const ring_link::RingState next = ring_link::decodeState(payload);
    // The encoder is the master volume and has no pill of its own, so the ring
    // becomes the readout for a moment whenever the level moves.
    const bool bothLive = g_haveState && (g_state.flags & ring_link::FLAG_LIVE) &&
                          (next.flags & ring_link::FLAG_LIVE);
    if (bothLive && next.gain != g_state.gain) {
      g_gainShownAt = millis();
      g_gainArmed = true;
    }
    if (!(next.flags & ring_link::FLAG_LIVE)) g_gainArmed = false;  // no stale arc on return
    g_state = next;
    g_haveState = true;
    g_lastStateMs = millis();
  }
  if (g_haveState && (uint32_t)(millis() - g_lastStateMs) >= ring_link::TIMEOUT_MS) g_haveState = false;
}

// ---- encoder and button -----------------------------------------------------------
static uint32_t g_session = 0, g_buttonEdges = 0, g_buttonSinceMs = 0;
static bool g_buttonRaw = false, g_buttonStable = false;
static const uint8_t ENC_DETENT = 3;        // both lines high, between clicks
static volatile uint8_t g_encLast = ENC_DETENT;
static volatile int8_t g_encSteps = 0;      // signed quarter-steps since the last detent
static volatile uint32_t g_encDetents = 0;  // cumulative clicks, wrapping

static void encoderSample() {
  const uint8_t cur = (uint8_t)((digitalRead(PIN_ENC_A) << 1) | digitalRead(PIN_ENC_B));
  if (cur == g_encLast) return;
  const uint8_t previous = g_encLast;
  g_encLast = cur;
  // ACZ11BR1E-20FD1-20C: clockwise closes A before B, giving
  // 11 -> 01 -> 00 -> 10 -> 11. Count only a complete cycle;
  // reverse transitions from contact bounce cancel their forward steps.
  static const int8_t steps[16] = {
     0, -1,  1,  0,  1,  0,  0, -1,
    -1,  0,  0,  1,  0,  1, -1,  0,
  };
  if ((previous ^ cur) == 3) g_encSteps = 0;  // missed/invalid two-bit jump
  else g_encSteps += steps[(previous << 2) | cur];
  if (cur == ENC_DETENT) {
    if (g_encSteps == 4) g_encDetents++;
    if (g_encSteps == -4) g_encDetents--;
    g_encSteps = 0;
  }
}

// The ISR can preempt any instruction of encoderSample(), and the two share
// every variable it touches: mask for the handful of instructions it takes.
static void encoderSampleFromLoop() {
  noInterrupts();
  encoderSample();
  interrupts();
}

static void pollButton() {
  const bool pressed = digitalRead(PIN_ENC_SW) == LOW;
  if (pressed != g_buttonRaw) {
    g_buttonRaw = pressed;
    g_buttonSinceMs = millis();
  } else if (pressed != g_buttonStable && (uint32_t)(millis() - g_buttonSinceMs) >= 8) {
    g_buttonStable = pressed;
    ++g_buttonEdges;  // odd = pressed
  }
}

static void sendInput() {
  uint8_t payload[ring_link::INPUT_LEN], packet[ring_link::MAX_FRAME];
  noInterrupts();
  const uint32_t count = g_encDetents;
  interrupts();
  ring_link::put32(payload, g_session);
  ring_link::put32(payload + 4, count);
  ring_link::put32(payload + 8, g_buttonEdges);
  ringLink.write(packet, ring_link::encode(ring_link::INPUT_STATE, payload, packet));
}

// ---- rendering ----------------------------------------------------------------------
// Perceptual gamma is applied HERE, once, as a colour is set: a WS2812's duty
// cycle is linear but the eye's response is not. It must not be applied to the
// stored buffer on every push, or the frozen comet would decay to black.
static uint32_t rgb(uint8_t r, uint8_t g, uint8_t b) {
  return Adafruit_NeoPixel::gamma32(Adafruit_NeoPixel::Color(r, g, b));
}
// `level` dims a colour. Gamma goes on the colour and on the level separately,
// and the two multiply, rounded, so a fading mixed colour keeps its hue.
static uint32_t scaled(uint8_t r, uint8_t g, uint8_t b, uint8_t level) {
  const uint16_t k = Adafruit_NeoPixel::gamma8(level);
  const uint32_t c = rgb(r, g, b);
  return Adafruit_NeoPixel::Color((uint8_t)((((c >> 16) & 0xFF) * k + 127) / 255),
                                  (uint8_t)((((c >> 8) & 0xFF) * k + 127) / 255),
                                  (uint8_t)(((c & 0xFF) * k + 127) / 255));
}
// The breathe and the gain arc run at the ambient brightness; the comet uses
// its own physical duties for a brighter, localized head.
static uint32_t ambientRingColor(uint32_t c) {
  const uint16_t k = RING_AMBIENT_BRIGHTNESS + 1;
  return Adafruit_NeoPixel::Color(((c >> 16) & 255) * k >> 8,
                                  ((c >> 8) & 255) * k >> 8,
                                  (c & 255) * k >> 8);
}

// Every push shares one full-white current ceiling. Normal patterns fit
// without dimming; a larger frame is scaled uniformly, keeping its hue. While
// the console is idle and the screens are dimmed, the output drops to about
// 20 % (#1349), at once even on a still frame.
static bool g_shownDim = false;
static bool dimmedNow() { return g_haveState && (g_state.flags & ring_link::FLAG_DIMMED); }
static void showRing() {
  const bool dim = dimmedNow();
  g_shownDim = dim;
  uint32_t total = 0;
  for (uint16_t i = 0; i < RING_N; ++i) {
    const uint32_t c = g_pixels[i];
    total += ((c >> 16) & 255) + ((c >> 8) & 255) + (c & 255);
  }
  for (uint16_t i = 0; i < RING_N; ++i) {
    uint32_t c = g_pixels[i];
    if (total > RING_CHANNEL_BUDGET) {
      c = Adafruit_NeoPixel::Color(((c >> 16) & 255) * RING_CHANNEL_BUDGET / total,
                                   ((c >> 8) & 255) * RING_CHANNEL_BUDGET / total,
                                   (c & 255) * RING_CHANNEL_BUDGET / total);
    }
    if (dim)
      c = Adafruit_NeoPixel::Color(ring_link::dimChannel((c >> 16) & 255),
                                   ring_link::dimChannel((c >> 8) & 255),
                                   ring_link::dimChannel(c & 255));
    ring.setPixelColor(i, c);
  }
  ring.show();
}

// A comet travels the ring at a FIXED cadence -- it says "something is
// happening", in the activity colour, and deliberately does not track the loop
// (owner's call, 2026-09-03). A Stop that leaves a loop loaded freezes it where
// it was; with nothing loaded and nothing playing the ring breathes green and
// never reaches black, so an idle panel still shows the board is up.
static const uint32_t RING_MS_PER_REV = 1100;
static const uint32_t BREATHE_MS = 1200;
static const float BREATHE_FLOOR = 0.35f;
// The owner-approved sustained-fade profile on the 40-pixel preview: physical
// channel duties, head first, the last quarter dark. It already describes LED
// output, so only the hue receives gamma.
static const uint16_t APPROVED_N = 40;
static const uint8_t APPROVED_DUTY[APPROVED_N] = {
  192, 192, 180, 174, 168, 162, 156, 150, 144, 138,
  132, 126, 120, 114, 108, 102, 96, 89, 82, 74,
  66, 58, 50, 41, 33, 25, 18, 11, 6, 2,
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0
};
// The same profile at the same angles on RING_N pixels, linearly resampled,
// with the two-pixel lead held at the approved 192.
static uint8_t g_cometDuty[RING_N];
static void buildCometDuty() {
  for (uint16_t i = 0; i < RING_N; ++i) {
    const float at = (float)i * APPROVED_N / RING_N;
    const uint16_t lo = (uint16_t)at;
    const float t = at - lo;
    const uint8_t a = APPROVED_DUTY[lo], b = APPROVED_DUTY[(lo + 1) % APPROVED_N];
    g_cometDuty[i] = i < 2 ? APPROVED_DUTY[0] : (uint8_t)(a * (1.0f - t) + b * t + 0.5f);
  }
}

static float g_ringPhase = 0.0f;  // comet head, 0..RING_N
static uint32_t g_ringLastMs = 0;
// What the buffer holds: every branch of renderRing() states which view it
// painted, and the caller pushes only when that key changed.
enum RingView : uint8_t { RING_NONE = 0, RING_DARK, RING_ARC, RING_COMET, RING_BREATHE };
static uint8_t g_ringView = RING_NONE;
static uint8_t g_ringKeyA = 0;  // arc: lit pixels; comet: phase in whole pixels
static uint32_t g_ringKeyB = 0;  // the colour that view was painted in
// A Stop freezes the comet but the state no longer carries its colour.
static Rgb g_cometColour = {0, 255, 0};

static void paintComet(Rgb c) {
  const uint32_t colour = rgb(c.r, c.g, c.b);
  const uint16_t head = (uint16_t)g_ringPhase;
  const float fraction = g_ringPhase - head;
  for (uint16_t i = 0; i < RING_N; i++) {
    const uint16_t behind = (head + RING_N - i) % RING_N;
    const uint8_t a = g_cometDuty[behind];
    const uint8_t b = g_cometDuty[(behind + 1) % RING_N];
    // Blend neighbouring circular positions, including across the strip's seam.
    const uint16_t duty = (uint16_t)(a * (1.0f - fraction) + b * fraction + 0.5f);
    g_pixels[i] = Adafruit_NeoPixel::Color((((colour >> 16) & 255) * duty + 127) / 255,
                                           (((colour >> 8) & 255) * duty + 127) / 255,
                                           ((colour & 255) * duty + 127) / 255);
  }
}

static bool settle(uint8_t view, uint8_t keyA, uint32_t keyB) {
  const bool changed = g_ringView != view || g_ringKeyA != keyA || g_ringKeyB != keyB;
  g_ringView = view;
  g_ringKeyA = keyA;
  g_ringKeyB = keyB;
  return changed;
}

// Returns whether the buffer changed and needs pushing.
static bool renderRing() {
  const uint32_t now = millis();
  const uint32_t dt = now - g_ringLastMs;
  g_ringLastMs = now;

  if (!g_haveState || !(g_state.flags & ring_link::FLAG_LIVE)) {
    if (g_ringView == RING_DARK) return false;
    for (uint16_t i = 0; i < RING_N; i++) g_pixels[i] = 0;
    return settle(RING_DARK, 0, 0);
  }
  const Rgb activity = {g_state.r, g_state.g, g_state.b};
  const uint32_t activityKey = (uint32_t)activity.r << 16 | activity.g << 8 | activity.b;

  // The master level, as a filled arc, for a moment after it changes: in the
  // activity colour, or the standby green when there is no activity.
  if (g_gainArmed && now - g_gainShownAt < GAIN_SHOW_MS) {
    const bool coloured = activity.r || activity.g || activity.b;
    const Rgb c = coloured ? activity : Rgb{0, 255, 0};
    const uint8_t lit = (uint8_t)((g_state.gain * RING_N + 254) / 255);
    if (!settle(RING_ARC, lit, activityKey)) return false;
    for (uint16_t i = 0; i < RING_N; i++)
      g_pixels[i] = i < lit ? ambientRingColor(rgb(c.r, c.g, c.b)) : 0;
    return true;
  }
  g_gainArmed = false;

  const bool active = g_state.flags & ring_link::FLAG_ACTIVE;
  if (!active && (g_state.flags & ring_link::FLAG_LOADED)) {
    if (!settle(RING_COMET, (uint8_t)g_ringPhase, 0xFFFFFFFFu)) return false;
    paintComet(g_cometColour);
    return true;
  }
  if (!active) {  // standby: breathe green
    const uint32_t p = now % BREATHE_MS;
    const uint32_t half = BREATHE_MS / 2;
    float t = (p < half) ? (p / (float)half) : (1.0f - (p - half) / (float)half);
    t = t * t * (3.0f - 2.0f * t);
    const uint8_t level = (uint8_t)((BREATHE_FLOOR + (1.0f - BREATHE_FLOOR) * t) * 255.0f + 0.5f);
    const uint32_t green = ambientRingColor(scaled(0, 255, 0, level));
    for (uint16_t i = 0; i < RING_N; i++) g_pixels[i] = green;
    settle(RING_BREATHE, level, 0);
    return true;  // it animates every tick
  }
  g_ringPhase = fmodf(g_ringPhase + (float)dt / (float)RING_MS_PER_REV * (float)RING_N, (float)RING_N);
  g_cometColour = activity;
  settle(RING_COMET, (uint8_t)g_ringPhase, activityKey);
  paintComet(activity);
  return true;
}

// ---- lifecycle ---------------------------------------------------------------------
void setup() {
  pinMode(PIN_ENC_A, INPUT_PULLUP);
  pinMode(PIN_ENC_B, INPUT_PULLUP);
  pinMode(PIN_ENC_SW, INPUT_PULLUP);
  g_encLast = (uint8_t)((digitalRead(PIN_ENC_A) << 1) | digitalRead(PIN_ENC_B));
  attachInterrupt(digitalPinToInterrupt(PIN_ENC_A), encoderSample, CHANGE);
  attachInterrupt(digitalPinToInterrupt(PIN_ENC_B), encoderSample, CHANGE);
  g_session = rp2040.hwrand32();
  buildCometDuty();
  ringLink.begin(115200);
  g_updater.begin();
  ring.begin();
  for (uint16_t i = 0; i < RING_N; i++) g_pixels[i] = 0;
  showRing();
  sendInput();
}

void loop() {
  pollState();
  g_updater.poll(millis());
  encoderSampleFromLoop();
  pollButton();
  const uint32_t now = millis();
  if ((uint32_t)(now - g_lastSnapshotMs) >= ring_link::SNAPSHOT_MS) {
    g_lastSnapshotMs = now;
    sendInput();
  }
  if ((uint32_t)(now - g_lastRenderMs) >= 20) {
    g_lastRenderMs = now;
    const bool changed = renderRing();
    const bool refresh = (uint32_t)(now - g_lastRefreshMs) >= 250;
    if (refresh) g_lastRefreshMs = now;
    if (changed || refresh || dimmedNow() != g_shownDim) showRing();
  }
}
