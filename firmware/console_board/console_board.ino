// Segno console board v3 (#1072) -- Pico 2 (RP2350) firmware.
//
// A PURE THIN CLIENT, like the pedal it replaces: it holds no looper state. It
// forwards ring state and renders the indicator pills from the last good STATE frame segno
// pushes, and sends raw footswitch / encoder events. segno runs the behavior
// machine and is the single source of truth.
//
// Link: Serial1 = UART0, GP16 TX / GP17 RX -> the Pi's uart3 (GPIO8/9,
// /dev/ttyAMA3), 115200 8N1. Wire format: pedal_link.h, shared byte for byte
// with packages/pedal_repository and pinned by firmware/test/run_tests.sh.
//
// Half of several circuits on this board is firmware (#752): the footswitches
// have no external pull-ups on the Pico side (INPUT_PULLUP is
// mandatory), a release edge is an RC of ~5-8 ms through the 100 nF debounce
// caps, and GP23 high puts the module's SMPS in PWM mode for a quieter ADC.
//
// Build: arduino-pico core + NeoPixelBus PIO/DMA; Adafruit supplies the original gamma.
//   arduino-cli compile --libraries firmware/libraries --fqbn rp2040:rp2040:rpipico2 firmware/console_board --output-dir firmware/console_board/build
// Flash from the Pi over SWD: README.md.

#include <Adafruit_NeoPixel.h>

#include <SegnoPanel.h>
#include <SerialPIO.h>
#include <panel_colors.h>
#include <panel_pixels.h>
#include "console_presence.h"
#include "console_pd.h"

static const uint8_t FW_MAJOR = 2;
static const uint8_t FW_MINOR = 1;

// ---- pin map (console_board.py GPIO table) ---------------------------------
static const uint8_t PIN_LINK_TX = 16, PIN_LINK_RX = 17;
static const uint8_t FSW_PIN[PEDAL_BTN_COUNT] = {2, 3, 4, 5, 6, 7, 8, 9, 10, 11};
static const uint8_t PIN_RING_TX = 13, PIN_RING_RX = 14;
SerialPIO ringLink(PIN_RING_TX, PIN_RING_RX, 256);
static const uint8_t PIN_IND = 18;
// The CTRL TRS jacks: tip on ADC0/ADC1 with a 10k pull-up to Pico 3V3, ring fed 3V3
// through 1k as the pot's top, sleeve to ground.
static const uint8_t CTRL_PIN[PEDAL_CTRL_COUNT] = {26, 27};
// The ring contacts return through R19/R20 (4.7k) for dual-switch pedals.
static const uint8_t CTRL_RING_PIN[PEDAL_CTRL_COUNT] = {20, 21};
// The switched tip-normal contact is HIGH only with an empty jack.
static const uint8_t CTRL_PRESENT_PIN[PEDAL_CTRL_COUNT] = {19, 22};
static const uint8_t PIN_SMPS_PWM = 23;

// ---- LEDs -----------------------------------------------------------------
// Owner-confirmed harness: eight pixels per pill, front row entered from the
// right, then CLEAR/BANK entered from the left. Button IDs retain their order.
static const uint16_t PILL_PIXELS = 8, IND_N = PEDAL_BTN_COUNT * PILL_PIXELS;
static const uint8_t PILL_BUTTON[PEDAL_BTN_COUNT] = {
  PEDAL_BTN_TRACK4, PEDAL_BTN_TRACK3, PEDAL_BTN_TRACK2, PEDAL_BTN_TRACK1,
  PEDAL_BTN_MODE, PEDAL_BTN_UNDO, PEDAL_BTN_STOP, PEDAL_BTN_REC_PLAY,
  PEDAL_BTN_CLEAR, PEDAL_BTN_BANK
};
static const uint8_t LED_BRIGHTNESS = 128;
PanelPixels ind(IND_N, PIN_IND);

// Local pixel coordinates run left to right when looking at the faceplate.
static uint16_t pillPixelIndex(uint8_t group, uint8_t pixel) {
  return group * PILL_PIXELS + (group < 8 ? PILL_PIXELS - 1 - pixel : pixel);
}

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
static ring_link::Parser g_ringParser;
static ring_link::InputTracker g_ringInput;
static uint32_t g_lastRingStateMs = 0, g_lastPdStatusMs = 0;
// Raw encoder-button state is available without assigning an unrequested
// looper action. Counters preserve even a press/release between UART snapshots.
static bool g_ringButtonPressed = false;
static uint32_t g_ringButtonPresses = 0, g_ringButtonReleases = 0;

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
      g_frameDirty = true;
      uint8_t buf[PEDAL_LINK_MAX_FRAME];
      sendFrame(buf, pedal_link_encode_button(i, raw ? 1 : 0, buf));
    }
  }
}

static void ringButton(bool pressed) {
  if (pressed == g_ringButtonPressed) return;
  g_ringButtonPressed = pressed;
  if (pressed) ++g_ringButtonPresses;
  else ++g_ringButtonReleases;
}

static void pollRing() {
  while (ringLink.available() > 0) {
    uint8_t type;
    const uint8_t *payload;
    if (!g_ringParser.push((uint8_t)ringLink.read(), type, payload) ||
        type != ring_link::INPUT_STATE) continue;
    const ring_link::InputDelta change = g_ringInput.accept(payload, millis());
    if (change.reset) {
      ringButton(false);
      ringButton(change.pressed);
    } else {
      for (uint32_t edge = 0; edge < change.edges; ++edge)
        ringButton(!g_ringButtonPressed);
      int32_t remaining = change.detents;
      while (remaining) {
        const int8_t chunk = remaining > 127 ? 127 : remaining < -127 ? -127 : (int8_t)remaining;
        uint8_t bytes[PEDAL_LINK_MAX_FRAME];
        sendFrame(bytes, pedal_link_encode_encoder(chunk, bytes));
        remaining -= chunk;
      }
    }
  }
  if (g_ringInput.expire(millis())) ringButton(false);
}

static void sendRingState() {
  pedal_state state = g_frame;
  if (!g_haveFrame) { state = {}; state.goodbye = 1; }
  uint8_t stateFrame[PEDAL_LINK_MAX_FRAME], packet[ring_link::MAX_FRAME];
  pedal_link_encode_state(&state, stateFrame);
  ringLink.write(packet, ring_link::encode(ring_link::STATE, stateFrame + 3, packet));
}

// ---- CTRL jacks --------------------------------------------------------------
// One jack takes an expression pedal OR a footswitch, and nobody tells the
// board which. A switch only ever sits at the rails; a pot passes through the
// middle and stays there. So a jack is unknown until it is caught HOLDING an
// intermediate reading, and from then on it is an expression pedal. Measured
// on the bench (2026-09-03): a BOSS FS-6 reads 10 and 4095, an M-Audio EX-P
// sweeps 385..4095.
//
// The physical presence contact decides insertion/removal. A 200 ms settling
// period suppresses plug brushes; established footswitch edges use 8 ms debounce.
// There is no analogue full-toe/unplug heuristic on this v3 board.
static const uint16_t CTRL_MAX = 4095;
// Below: switch closed. A sixteenth of the way up, well over a footswitch's
// contact (10 raw on a BOSS FS-6) and under the lowest an expression pedal's
// heel reads (385 raw on an M-Audio EX-P) -- otherwise a pedal plugged in at
// its heel was one closed switch until it moved.
static const uint16_t CTRL_LOW = CTRL_MAX / 16;
static const uint16_t CTRL_HIGH = CTRL_MAX - CTRL_MAX / 8;  // above: open / empty
static const uint16_t CTRL_DEADBAND = 24;  // ~0.6%, above the noise floor
static const uint16_t CTRL_JUMP = CTRL_MAX * 2 / 5;   // 40% in one 10 ms sample
static const unsigned long CTRL_SWITCH_DEBOUNCE_MS = 8;
static const unsigned long CTRL_SAMPLE_MS = 10;
static const unsigned long CTRL_SETTLE_MS = 200;      // quiet before trusting
static const unsigned long CTRL_PRESENT_DEBOUNCE_MS = 50;

// An expression pedal never uses the whole scale: the tip's 10k pull-up and
// the 1k feeding the pot's top compress both ends, and every pedal's travel
// and range knob differ again (an M-Audio EX-P covers 385..4095 of 0..4095).
// Where the ends really are is NOT decided here. This board forgets everything
// at power-off, so it reports the raw position and segno learns the ends --
// deliberately, from a sweep the user makes -- and keeps them across reboots.
enum { CTRL_UNKNOWN = 0, CTRL_SWITCH, CTRL_EXPRESSION, CTRL_NONE };
static uint8_t g_ctrlKind[PEDAL_CTRL_COUNT];
static uint16_t g_ctrlRaw[PEDAL_CTRL_COUNT];
static uint8_t g_ctrlSent[PEDAL_CTRL_COUNT];
static bool g_ctrlHaveSent[PEDAL_CTRL_COUNT];
static unsigned long g_ctrlQuietUntilMs[PEDAL_CTRL_COUNT];   // settling after a jump
static unsigned long g_ctrlMidSinceMs[PEDAL_CTRL_COUNT];     // mid-scale held since
static bool g_ctrlPresentRaw[PEDAL_CTRL_COUNT];
static bool g_ctrlPresent[PEDAL_CTRL_COUNT];
static unsigned long g_ctrlPresentSinceMs[PEDAL_CTRL_COUNT];
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

// The jack has nothing on it: say so once, forget what it was, and start
// again from unknown on the next plug.
// The ring: a switch on a two-switch pedal, a supply on an expression pedal,
// and a contact the plug's tip brushes on its way past either way. Only
// reached once the tip is out of its quiet period. On a jack already known
// as a switch an edge is a press, debounced like the tip; anywhere else a
// closure has to hold for CTRL_SETTLE_MS before it counts, and counting makes
// the jack a switch. An expression jack's ring is never a switch.
static void pollCtrlRing(uint8_t jack, unsigned long now) {
  const bool closed = digitalRead(CTRL_RING_PIN[jack]) == LOW;
  if (g_ctrlKind[jack] == CTRL_EXPRESSION) {
    g_ctrlSwitchRaw[jack][PEDAL_CTRL_RING] = closed;
    return;
  }
  if (g_ctrlKind[jack] == CTRL_SWITCH) {
    pollCtrlSwitch(jack, PEDAL_CTRL_RING, closed, now);
    return;
  }
  if (closed != g_ctrlSwitchRaw[jack][PEDAL_CTRL_RING]) {
    g_ctrlSwitchRaw[jack][PEDAL_CTRL_RING] = closed;
    g_ctrlSwitchSinceMs[jack][PEDAL_CTRL_RING] = now;
    return;
  }
  if (closed && !g_ctrlSwitchClosed[jack][PEDAL_CTRL_RING] &&
      now - g_ctrlSwitchSinceMs[jack][PEDAL_CTRL_RING] >= CTRL_SETTLE_MS) {
    g_ctrlKind[jack] = CTRL_SWITCH;
    g_ctrlSwitchClosed[jack][PEDAL_CTRL_RING] = true;
    sendCtrl(jack, PEDAL_CTRL_RING, PEDAL_CTRL_KIND_SWITCH, 255);
  }
}

// A switch reported closed cannot stay closed with nothing on the contact:
// let go of it, so whatever it held down is released before the row goes.
static void ctrlReleaseSwitch(uint8_t jack, uint8_t contact) {
  g_ctrlSwitchRaw[jack][contact] = false;
  if (!g_ctrlSwitchClosed[jack][contact]) return;
  g_ctrlSwitchClosed[jack][contact] = false;
  sendCtrl(jack, contact, PEDAL_CTRL_KIND_SWITCH, 0);
}

static void ctrlDetach(uint8_t jack) {
  for (uint8_t c = 0; c < PEDAL_CTRL_CONTACT_COUNT; c++) ctrlReleaseSwitch(jack, c);
  if (g_ctrlKind[jack] != CTRL_NONE) {
    sendCtrl(jack, PEDAL_CTRL_TIP, PEDAL_CTRL_KIND_NONE, 0);
  }
  g_ctrlKind[jack] = CTRL_NONE;
  g_ctrlHaveSent[jack] = false;
  g_ctrlSent[jack] = 0;
  g_ctrlMidSinceMs[jack] = 0;
}

static void pollCtrl() {
  const unsigned long now = millis();
  if (now - g_ctrlLastSampleMs < CTRL_SAMPLE_MS) return;
  g_ctrlLastSampleMs = now;

  for (uint8_t j = 0; j < PEDAL_CTRL_COUNT; j++) {
    // Physical switched-jack presence, sampled with the RP2350 E9 workaround.
    const bool presentRaw = !console_presence_read(CTRL_PRESENT_PIN[j]);
    if (presentRaw != g_ctrlPresentRaw[j]) {
      g_ctrlPresentRaw[j] = presentRaw;
      g_ctrlPresentSinceMs[j] = now;
    } else if (presentRaw != g_ctrlPresent[j] &&
               now - g_ctrlPresentSinceMs[j] >= CTRL_PRESENT_DEBOUNCE_MS) {
      g_ctrlPresent[j] = presentRaw;
      if (!presentRaw) {
        ctrlDetach(j);
      } else {
        // Freshly plugged: unknown, and give the plug time to seat.
        g_ctrlKind[j] = CTRL_UNKNOWN;
        g_ctrlQuietUntilMs[j] = now + CTRL_SETTLE_MS;
      }
    }
    if (!g_ctrlPresent[j]) continue;

    const uint16_t raw = ctrlSample(CTRL_PIN[j]);
    const uint16_t prev = g_ctrlRaw[j];
    g_ctrlRaw[j] = raw;
    const uint16_t delta = raw > prev ? raw - prev : prev - raw;
    const bool mid = raw > CTRL_LOW && raw < CTRL_HIGH;

    // Give an abrupt analogue change time to settle while a plug seats.
    if (delta >= CTRL_JUMP) {
      g_ctrlQuietUntilMs[j] = now + CTRL_SETTLE_MS;
      g_ctrlMidSinceMs[j] = 0;
    }

    // A jack the board already knows holds a footswitch is not waiting for a
    // plug, and pressing that footswitch is itself a jump: report its edges
    // at once instead of making every press and release wait out the settle
    // time. The reclassification checks below still run once it is settled,
    // so swapping a pedal into this jack is still noticed.
    const bool known = g_ctrlKind[j] == CTRL_SWITCH;
    if (known) {
      pollCtrlSwitch(j, PEDAL_CTRL_TIP, raw < CTRL_LOW, now);
      pollCtrlRing(j, now);
    }
    if ((long)(now - g_ctrlQuietUntilMs[j]) < 0) continue;

    if (!known) pollCtrlRing(j, now);

    // Mid-scale that HOLDS is a pot. A single mid-scale sample is a plug
    // passing through, and on a switch jack that used to be enough to
    // reclassify it for the rest of the boot.
    if (mid) {
      if (g_ctrlMidSinceMs[j] == 0) g_ctrlMidSinceMs[j] = now;
      if (g_ctrlKind[j] != CTRL_EXPRESSION &&
          now - g_ctrlMidSinceMs[j] >= CTRL_SETTLE_MS) {
        g_ctrlKind[j] = CTRL_EXPRESSION;
        g_ctrlHaveSent[j] = false;
        // A pot has no switch on either contact -- its ring is the supply and
        // its tip is the wiper -- so let go of anything the plug's brush past
        // those contacts was read as, rather than leave it held down.
        for (uint8_t c = 0; c < PEDAL_CTRL_CONTACT_COUNT; c++) {
          ctrlReleaseSwitch(j, c);
        }
      }
    } else {
      g_ctrlMidSinceMs[j] = 0;
    }

    if (g_ctrlKind[j] == CTRL_EXPRESSION) {
      // The 12-bit reading's top byte: 256 steps over the whole scale, of
      // which a pedal uses ~230 -- twice what a MIDI CC resolves.
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

    // Unknown or a switch. Closed is the tip pulled to ground; open is the
    // 10k holding it at the rail. A jack that was NONE becomes a switch on
    // its first press, not on the plug's arrival: an open jack and an open
    // switch read the same, so there is nothing to say until it moves.
    if (known) continue;  // polled above, before the settle gate
    if (g_ctrlKind[j] == CTRL_NONE && raw >= CTRL_LOW) continue;
    if (g_ctrlKind[j] != CTRL_SWITCH && raw < CTRL_LOW) g_ctrlKind[j] = CTRL_SWITCH;
    if (g_ctrlKind[j] == CTRL_UNKNOWN) g_ctrlKind[j] = CTRL_SWITCH;
    pollCtrlSwitch(j, PEDAL_CTRL_TIP, raw < CTRL_LOW, now);
  }
}

// ---- indicator rendering -------------------------------------------------
// Colors are addressed by logical button; PILL_BUTTON maps the actual harness.
// STOP and UNDO acknowledge physical presses; the frame cannot prove either
// a stopped transport (all-muted playback also has no activity) or undo availability.
static Rgb pillColor(uint8_t pill) {
  switch (pill) {
    case PEDAL_BTN_REC_PLAY: return globalColor(g_frame.global_color);
    case PEDAL_BTN_STOP: return g_btnStable[pill] ? Rgb{255, 0, 0} : Rgb{0, 0, 0};
    case PEDAL_BTN_UNDO: return g_btnStable[pill] ? Rgb{0, 0, 255} : Rgb{0, 0, 0};
    case PEDAL_BTN_MODE: return modeColor(g_frame.mode);
    case PEDAL_BTN_CLEAR: return g_frame.clear_fade ? Rgb{255, 0, 0} : Rgb{0, 0, 0};
    case PEDAL_BTN_BANK: return g_frame.active_bank == 1 ? Rgb{0, 0, 255} : Rgb{0, 0, 0};
    default:
      if (pill >= PEDAL_BTN_TRACK1 && pill <= PEDAL_BTN_TRACK4)
        return ledColor(g_frame.track_leds[g_frame.active_bank * 4 + pill - PEDAL_BTN_TRACK1]);
      return {0, 0, 0};
  }
}
static void renderIndicators() {
  if (!g_haveFrame || g_frame.goodbye) { ind.clear(); return; }
  // The approved eight-pixel diffuser curve averages 57.45% before the cap.
  static const uint8_t gradient[PILL_PIXELS] = {38, 92, 201, 255, 255, 201, 92, 38};
  for (uint8_t group = 0; group < PEDAL_BTN_COUNT; ++group) {
    const uint8_t button = PILL_BUTTON[group];
    const bool queued = g_frame.looper_mode == PEDAL_LOOPER_SONG &&
        g_frame.mode == PEDAL_MODE_PLAY && button >= PEDAL_BTN_TRACK1 &&
        button <= PEDAL_BTN_TRACK4 && g_frame.queued_track ==
            g_frame.active_bank * 4 + button - PEDAL_BTN_TRACK1 + 1;
    const Rgb color = queued ? Rgb{0, 255, 0} : pillColor(button);
    const uint32_t gamma = rgb(color.r, color.g, color.b);
    for (uint8_t pixel = 0; pixel < PILL_PIXELS; ++pixel) {
      uint16_t weight = gradient[pixel];
      if (queued) {
        // Progress is the app's remaining-loop completion, not a local timer.
        // A partial leading pixel fills left to right. Wire progress stops at
        // 254: only the app's completed state may display the full pill.
        const int16_t coverage = g_frame.queued_progress * PILL_PIXELS - pixel * 255;
        const uint16_t level = coverage <= 0 ? 0 : coverage >= 255 ? 255 : coverage;
        weight = (weight * level + 127) / 255;
      }
      const uint32_t value = Adafruit_NeoPixel::Color(
          (((gamma >> 16) & 255) * weight + 127) / 255,
          (((gamma >> 8) & 255) * weight + 127) / 255,
          ((gamma & 255) * weight + 127) / 255);
      ind.setPixelColor(pillPixelIndex(group, pixel), value);
    }
  }
}
static const unsigned long RENDER_MS = 20, REFRESH_MS = 250;
static unsigned long g_lastRenderMs = 0, g_lastRefreshMs = 0;

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
    pinMode(CTRL_RING_PIN[j], INPUT_PULLUP);
    console_presence_begin(CTRL_PRESENT_PIN[j]);
    g_ctrlKind[j] = CTRL_UNKNOWN;
    g_ctrlRaw[j] = CTRL_MAX;
    g_ctrlSent[j] = 0;
    g_ctrlHaveSent[j] = false;
    g_ctrlQuietUntilMs[j] = 0;
    g_ctrlMidSinceMs[j] = 0;
    g_ctrlPresentRaw[j] = true;
    g_ctrlPresent[j] = true;
    g_ctrlPresentSinceMs[j] = 0;
    for (uint8_t c = 0; c < PEDAL_CTRL_CONTACT_COUNT; c++) {
      g_ctrlSwitchClosed[j][c] = false;
      g_ctrlSwitchRaw[j][c] = false;
      g_ctrlSwitchSinceMs[j][c] = 0;
    }
  }
  analogReadResolution(12);
  LINK.setTX(PIN_LINK_TX);
  LINK.setRX(PIN_LINK_RX);
  LINK.begin(LINK_BAUD);
  pedal_link_parser_init(&g_parser);

  ringLink.begin(LINK_BAUD);
  console_pd_begin();
  ind.begin();
  ind.setBrightness(LED_BRIGHTNESS);
  ind.clear();
  ind.show();
  sendRingState();

  sendHello();
  g_lastHelloMs = millis();
}

void loop() {
  pollLink();
  pollButtons();
  pollRing();
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
    const bool frameChanged = g_frameDirty;
    g_frameDirty = false;
    if (frameChanged) renderIndicators();
    if (frameChanged || refresh) ind.show();
  }
  console_pd_poll(now);
  if (now - g_lastPdStatusMs >= 1000) {
    g_lastPdStatusMs = now;
    const pedal_pd_status status = console_pd_status(now);
    uint8_t bytes[PEDAL_LINK_MAX_FRAME];
    sendFrame(bytes, pedal_link_encode_pd_status(&status, bytes));
  }
  if (now - g_lastRingStateMs >= ring_link::STATE_MS) {
    g_lastRingStateMs = now;
    sendRingState();
  }
}
