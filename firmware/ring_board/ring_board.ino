// Segno ring board v3: XIAO RP2350, local encoder + one 40-LED ring.
#include <Adafruit_NeoPixel.h>
#include <SerialPIO.h>
#include <SegnoPanel.h>
#include <panel_colors.h>
#include <panel_pixels.h>

// Seeed variant pin aliases, matching ring_board.py's D-number pads.
static const uint8_t PIN_RING = D0, PIN_ENC_A = D1, PIN_ENC_B = D2, PIN_ENC_SW = D3;
SerialPIO ringLink(D10, D9, 256);  // TX D10/GP3 -> console GP14; RX D9/GP4 <- GP13
static const uint16_t RING_N = 40;
static const uint8_t LED_BRIGHTNESS = 128;
PanelPixels ring(RING_N, PIN_RING);
static pedal_state g_frame;
static bool g_haveFrame = false;
static uint32_t g_lastFrameMs = 0, g_lastRenderMs = 0, g_lastSnapshotMs = 0, g_lastRefreshMs = 0;
static const uint32_t GAIN_SHOW_MS = 900;
static uint32_t g_gainShownAt = 0;
static bool g_gainArmed = false;
static ring_link::Parser g_parser;
static uint32_t g_session = 0, g_buttonEdges = 0, g_buttonSinceMs = 0;
static bool g_buttonRaw = false, g_buttonStable = false;

static const uint8_t ENC_DETENT = 3;      // both lines high, between clicks
static volatile uint8_t g_encLast = ENC_DETENT;
static volatile uint8_t g_encMark = 0;    // last intermediate state, 0 = none
static volatile uint32_t g_encDetents = 0;  // whole clicks the link still owes

static void encoderSample() {
  const uint8_t cur = (uint8_t)((digitalRead(PIN_ENC_A) << 1) | digitalRead(PIN_ENC_B));
  if (cur == g_encLast) return;
  g_encLast = cur;
  if (cur == ENC_DETENT) {
    if (g_encMark == 1) g_encDetents++;
    if (g_encMark == 2) g_encDetents--;
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


#include <panel_ring.h>

static void pollState() {
  while (ringLink.available() > 0) {
    uint8_t type;
    const uint8_t *payload;
    if (!g_parser.push((uint8_t)ringLink.read(), type, payload) || type != ring_link::STATE) continue;
    pedal_state next;
    if (!pedal_link_decode_state(payload, PEDAL_LINK_STATE_LEN, &next)) continue;
    if (g_haveFrame && next.master_gain != g_frame.master_gain) {
      g_gainShownAt = millis();
      g_gainArmed = true;
    }
    g_frame = next;
    g_haveFrame = true;
    g_lastFrameMs = millis();
  }
  if (g_haveFrame && (uint32_t)(millis() - g_lastFrameMs) >= ring_link::TIMEOUT_MS)
    g_haveFrame = false;
}
static void pollButton() {
  const bool pressed = digitalRead(PIN_ENC_SW) == LOW;
  if (pressed != g_buttonRaw) {
    g_buttonRaw = pressed;
    g_buttonSinceMs = millis();
  } else if (pressed != g_buttonStable && (uint32_t)(millis() - g_buttonSinceMs) >= 8) {
    g_buttonStable = pressed;
    ++g_buttonEdges;
  }
}
static void sendInput() {
  uint8_t payload[12], packet[ring_link::MAX_FRAME];
  noInterrupts();
  const uint32_t count = g_encDetents;
  interrupts();
  ring_link::put32(payload, g_session);
  ring_link::put32(payload + 4, count);
  ring_link::put32(payload + 8, g_buttonEdges);
  ringLink.write(packet, ring_link::encode(ring_link::INPUT_STATE, payload, packet));
}
void setup() {
  pinMode(PIN_ENC_A, INPUT_PULLUP);
  pinMode(PIN_ENC_B, INPUT_PULLUP);
  pinMode(PIN_ENC_SW, INPUT_PULLUP);
  g_encLast = (digitalRead(PIN_ENC_A) << 1) | digitalRead(PIN_ENC_B);
  attachInterrupt(digitalPinToInterrupt(PIN_ENC_A), encoderSample, CHANGE);
  attachInterrupt(digitalPinToInterrupt(PIN_ENC_B), encoderSample, CHANGE);
  g_session = rp2040.hwrand32();
  ringLink.begin(115200);
  ring.begin();
  ring.setBrightness(LED_BRIGHTNESS);
  ring.clear();
  ring.show();
  sendInput();
}
void loop() {
  pollState();
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
    if (changed || refresh) ring.show();
  }
}
