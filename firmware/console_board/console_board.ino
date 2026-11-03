// Segno console board v3 (#1072) -- Pico 2 (RP2350) firmware.
//
// A PURE THIN CLIENT, like the pedal it replaces: it holds no looper state. It
// renders the indicator pills from the last good STATE frame segno pushes,
// forwards what the ring needs to the ring carrier's XIAO, and sends raw
// footswitch / encoder / encoder-switch events. segno runs the behavior machine
// and is the single source of truth.
//
// Ring: the encoder and its LED ring live on the ring carrier, run by its own
// XIAO RP2350 (firmware/ring_board). The two talk over a private UART on
// GP13 TX / GP14 RX (SegnoRing's ring_link.h): the Pico sends a five-byte ring
// state, the XIAO sends cumulative encoder and button counters, and the Pico
// turns those into the same ENCODER / ENCODER_BUTTON events the v2 board sent.
// On the Pi's RING_BRIDGE message it bridges the two UARTs instead, so the Pi
// can update the XIAO's firmware (SegnoRing's ring_update.h, #1342).
//
// Link: Serial1 = UART0, GP16 TX / GP17 RX -> the Pi's uart3 (GPIO8/9,
// /dev/ttyAMA3), 115200 8N1. Wire format: pedal_link.h, shared byte for byte
// with packages/pedal_repository and pinned by firmware/test/run_tests.sh.
//
// PD trigger: the STUSB4500 on the SparkFun board, over J23 (I2C0, GP0 SDA /
// GP1 SCL, its own pull-ups). At boot the board makes the trigger's NVM hold
// the console profile (pd_trigger.h) and from then on reports the contract in
// a PD_STATUS after every HELLO (#1352).
//
// Light sensor: an optional TEPT5600 on J22 (GP28, ADC2), read through
// ambient_light.h and reported in an AMBIENT after every HELLO (#1564). With
// nothing on J22 the board says so, and nothing else changes. The app answers
// with LED_LEVEL, which scales the pills and the ring.
//
// Half of several circuits on this board is firmware (#752): the footswitches
// have no external pull-ups on the Pico side (INPUT_PULLUP is mandatory), a
// release edge is an RC of ~5-8 ms through the 100 nF debounce caps, and GP23
// high puts the module's SMPS in PWM mode for a quieter ADC.
//
// Build: arduino-pico core + NeoPixelBus (PIO/DMA pills); Adafruit NeoPixel
// supplies the gamma tables only.
//   arduino-cli compile --libraries firmware/libraries --fqbn rp2040:rp2040:rpipico2 firmware/console_board --output-dir firmware/console_board/build
// Flash from the Pi over SWD: README.md.

#include <Adafruit_NeoPixel.h>
#include <NeoPixelBus.h>
#include <SerialPIO.h>
#include <Wire.h>
#include <hardware/gpio.h>

#include "pedal_link.h"
#include "console_presence.h"
#include "pd_trigger.h"
#include "ambient_light.h"
#include <SegnoRing.h>

// A colour before gamma; the .ino auto-prototypes need the type declared first.
struct Rgb { uint8_t r, g, b; };

// Major 2: the v3 board (ring on its own XIAO). Same pedal-link protocol.
// 2.1: the ring-update bridge. 2.2: pills and ring dim with the screens
// (protocol 11, #1349). 2.3: provisions the PD trigger and reports its
// contract (protocol 12, #1352). 2.4: MODE reads GP12 (#1388). 2.5: a
// waiting Song or Band section fills its pill at one level and blends to
// the diffused curve when it starts (#1323). 2.6: a clear-track hold fills
// its pill red from both ends toward the centre and, when it fires, flashes
// the full pill three times (CLEAR_HOLD, #1534; still protocol 12, see
// pedal_link.h). 2.7: reads the light sensor on J22 and reports it
// (AMBIENT), and shows the pills and the ring at the app's LED_LEVEL (#1564;
// still protocol 12).
static const uint8_t FW_MAJOR = 2;
static const uint8_t FW_MINOR = 7;

// ---- pin map (console_board.py GPIO table) ---------------------------------
static const uint8_t PIN_LINK_TX = 16, PIN_LINK_RX = 17;
static const uint8_t PIN_PD_SDA = 0, PIN_PD_SCL = 1;
// MODE (PEDAL_BTN_MODE) reads GP12, not GP5: GP5 died on the owner's unit
// (it sits near 0 V with the pull-up on; reworked with a jumper from SW_MODE
// to GP12), and the board design moves SW_MODE to GP12 as well (#1388). GP5
// stays unconfigured.
static const uint8_t FSW_PIN[PEDAL_BTN_COUNT] = {2, 3, 4, 12, 6, 7, 8, 9, 10, 11};
// The ring carrier's UART (J6 pins 3/4). R11/R12 pull both lines up to the
// Pico's own 3V3, so the link idles high while the Pi is off.
static const uint8_t PIN_RING_TX = 13, PIN_RING_RX = 14;
static const uint8_t PIN_IND = 18;
// The CTRL TRS jacks: tip on ADC0/ADC1 with a 10k pull-up, ring feeding 3V3
// through 1k as the pot's top, sleeve to ground.
static const uint8_t CTRL_PIN[PEDAL_CTRL_COUNT] = {26, 27};
// The rings, sensed. On a two-switch pedal on one TRS plug (a BOSS FS-6's A&B
// jack) the second switch shorts the ring to sleeve, which the tip's ADC can
// never see. Each jack's ring reaches these pins through R19/R20 (4.7k): it
// sits at ~3V (an expression pedal's pot top, or an open jack) and drops to 0
// when that switch closes.
static const uint8_t CTRL_RING_PIN[PEDAL_CTRL_COUNT] = {20, 21};
// Jack presence, from the Neutrik NJ6FD-V's ring-normal contact through
// R21/R22 (4.7k): the contact ties this pin to the jack's biased ring while
// the jack is EMPTY and opens the moment a plug goes in, so with the internal
// pull-down the pin reads HIGH = empty, LOW = plugged. Read through
// console_presence.h, which keeps the pad's input buffer off between samples
// (RP2350-E9).
static const uint8_t CTRL_PRESENT_PIN[PEDAL_CTRL_COUNT] = {19, 22};
static const uint8_t PIN_SMPS_PWM = 23;
// J22 pin 5: the light sensor's emitter, with its load to ground (#1564).
static const uint8_t PIN_AMBIENT = 28;

// ---- LEDs --------------------------------------------------------------------
// Ten eight-pixel pills on J24, in the owner-verified data-chain order.
static const uint8_t PILL_PIXELS = 8, IND_N = PEDAL_BTN_COUNT * PILL_PIXELS;
static const uint8_t PILL_BUTTON[PEDAL_BTN_COUNT] = {
  PEDAL_BTN_TRACK4, PEDAL_BTN_TRACK3, PEDAL_BTN_TRACK2, PEDAL_BTN_TRACK1,
  PEDAL_BTN_MODE, PEDAL_BTN_UNDO, PEDAL_BTN_STOP, PEDAL_BTN_REC_PLAY,
  PEDAL_BTN_CLEAR, PEDAL_BTN_BANK
};
static const uint8_t PILL_PEAK = 191;
static const uint8_t PILL_WEIGHTS[PILL_PIXELS] = {38, 92, 201, 255, 255, 201, 92, 38};
// A waiting Song or Band section (#1323) and a clear-track hold (#1534) fill
// at one level, with no centre curve: the mean of the diffused levels
// {28, 69, 151, 191, 191, 151, 69, 28} (878 / 8), so a fully filled pill has
// the same total brightness as the diffused curve.
static const uint8_t PILL_FILL_LEVEL = 110;
// The colour a clear-track hold fills with, before gamma: the global red.
static const Rgb PILL_CLEAR_RED = {255, 0, 0};
// When a clear-track hold fires (a CLEAR_HOLD at 255), the board confirms it:
// the full red pill flashes this many times, each PILL_CLEAR_FLASH_MS on and
// as long dark, about 0.7 s in all, then the pill shows what STATE says.
static const uint8_t PILL_CLEAR_FLASHES = 3;
static const unsigned long PILL_CLEAR_FLASH_MS = 120;
static const unsigned long PILL_CLEAR_FLASH_TOTAL_MS = 2ul * PILL_CLEAR_FLASHES * PILL_CLEAR_FLASH_MS;
// A pill the app already shows red (a recording track, or any state it
// colours red) would hide the red fill. While a clear hold runs on it, its
// own colour drops to PILL_CLEAR_UNDER_RED of 255 (about a third) and the
// fill is drawn at full brightness, PILL_PEAK, over it.
static const uint8_t PILL_CLEAR_UNDER_RED = 85;

// Whether the app's colour for a pill reads red: red is at least half on and
// at least twice green and blue, so the palette's reds count and its orange,
// pink and white do not.
static bool pillReadsRed(Rgb c) {
  return c.r >= 128 && 2u * c.g <= c.r && 2u * c.b <= c.r;
}
// When a pill leaves the queue and stays lit, it blends from its last fill
// to the diffused curve over this long.
static const unsigned long PILL_SETTLE_MS = 300;
// Limit the whole pill chain to ~471 mA of color-channel current using the
// conservative 20 mA/channel model. The ring now has its own supply branch and
// its own budget on the ring carrier. This is a planning model, not measured
// consumption.
static const uint32_t PILL_CHANNEL_BUDGET = 6000;
// DMA keeps interrupts available throughout the 80-pixel transfer.
NeoPixelBus<NeoGrbFeature, Rp2040x4Pio1Ws2812xMethod> ind(IND_N, PIN_IND);

static uint8_t pillPixelIndex(uint8_t group, uint8_t pixel) {
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
static unsigned long g_lastFrameMs = 0;
static unsigned long g_lastHelloMs = 0;
// The app's last CLEAR_HOLD and when it arrived: a fill no message has
// refreshed for PEDAL_LINK_CLEAR_HOLD_STALE_MS is over.
static pedal_clear_hold g_clearHold = {0, 0};
static unsigned long g_clearHoldAtMs = 0;
// Per footswitch, whether a fired clear hold is flashing its pill and when
// the flash began. Each runs on this clock alone: the stale-fill drop, the
// app's no-button message, later STATE frames and a hold firing on another
// pill do not touch it.
static bool g_clearFlashing[PEDAL_BTN_COUNT];
static unsigned long g_clearFlashAtMs[PEDAL_BTN_COUNT];

// The app's LED_LEVEL and the level shown, which fades toward it by
// LED_FADE_STEP every render so a new level is never a jump. Full until the
// app says otherwise, and again when its frames stop.
static uint8_t g_ledTarget = PEDAL_LINK_LED_LEVEL_FULL;
static uint8_t g_ledLevel = PEDAL_LINK_LED_LEVEL_FULL;
static const uint8_t LED_FADE_STEP = 3;  // the whole range in about 1.7 s

static void resetLedLevel() {
  g_ledTarget = PEDAL_LINK_LED_LEVEL_FULL;
  g_ledLevel = PEDAL_LINK_LED_LEVEL_FULL;
}

static void endClearFlashes() {
  for (bool &flashing : g_clearFlashing) flashing = false;
}

// 2048: while bridging, a whole update chunk is copied the other way before
// this buffer is drained again.
SerialPIO ringLink(PIN_RING_TX, PIN_RING_RX, 2048);
static ring_link::Parser g_ringParser;
static ring_link::InputTracker g_ringInput;
static unsigned long g_lastRingStateMs = 0;
static bool g_ringButtonPressed = false;

static void sendRingState();
static void startBridge();

static void sendFrame(const uint8_t *buf, size_t len) {
  LINK.write(buf, len);
}

static void sendHello() {
  uint8_t buf[PEDAL_LINK_MAX_FRAME];
  sendFrame(buf, pedal_link_encode_hello(FW_MAJOR, FW_MINOR, buf));
}

// ---- PD trigger (J23) -------------------------------------------------------
// The 1 ms after each write is the pace the ST NVM flasher was proven at.
static int pdWrite(void *, uint8_t reg, const uint8_t *data, uint8_t len) {
  Wire.beginTransmission(PD_TRIGGER_ADDRESS);
  Wire.write(reg);
  Wire.write(data, len);
  const uint8_t error = Wire.endTransmission();
  delay(1);
  return error;
}

static int pdRead(void *, uint8_t reg, uint8_t *data, uint8_t len) {
  Wire.beginTransmission(PD_TRIGGER_ADDRESS);
  Wire.write(reg);
  if (Wire.endTransmission(false) != 0) return 1;
  if (Wire.requestFrom(PD_TRIGGER_ADDRESS, (size_t)len) != len) return 1;
  for (uint8_t i = 0; i < len; ++i) data[i] = (uint8_t)Wire.read();
  return 0;
}

static void pdSleep(void *, uint32_t ms) { delay(ms); }

static const pd_trigger_bus PD_BUS = {pdWrite, pdRead, pdSleep, nullptr};
static uint8_t g_pdProfile = PEDAL_PD_PROFILE_NOT_READ;
static uint8_t g_pdQuietHellos = 0;
static const uint8_t PD_RETRY_HELLOS = 10;

// The contract is read live: a multi-port charger can renegotiate under us. A
// trigger that is not answering is asked again only every tenth hello: with
// J23 unplugged GP0/GP1 have no pull-ups and every read waits out Wire's
// timeout. One that answers later (J23 seated after boot) is provisioned then.
static void sendPdStatus() {
  pd_trigger_contract c = {};
  if (g_pdProfile == PEDAL_PD_PROFILE_NOT_READ && ++g_pdQuietHellos >= PD_RETRY_HELLOS) {
    g_pdQuietHellos = 0;
    g_pdProfile = pd_trigger_provision(&PD_BUS);
  }
  if (g_pdProfile != PEDAL_PD_PROFILE_NOT_READ && pd_trigger_read_contract(&PD_BUS, &c)) {
    g_pdProfile = PEDAL_PD_PROFILE_NOT_READ;
  }
  uint8_t buf[PEDAL_LINK_MAX_FRAME];
  sendFrame(buf, pedal_link_encode_pd_status(g_pdProfile, c.mismatch, c.millivolts, c.milliamps,
                                             c.max_milliamps, buf));
}

static void handleMessage(uint8_t type, const uint8_t *payload, uint8_t len) {
  switch (type) {
    case PEDAL_LINK_TYPE_STATE: {
      pedal_state decoded;
      if (pedal_link_decode_state(payload, len, &decoded)) {
        if (decoded.goodbye) {  // a goodbye ends any fill or flash
          g_clearHold = {0, 0};
          endClearFlashes();
        }
        g_frame = decoded;
        g_haveFrame = true;
        g_lastFrameMs = millis();
        sendRingState();  // the ring's gain arc and comet follow without delay
      }
      break;  // a malformed frame is dropped; the last good one is kept
    }
    case PEDAL_LINK_TYPE_CLEAR_HOLD: {
      pedal_clear_hold decoded;
      if (pedal_link_decode_clear_hold(payload, len, &decoded)) {
        const uint8_t button = decoded.button - 1;  // valid only when decoded.button != 0
        if (decoded.progress == 255) {
          // The hold fired and the clear was accepted: confirm it, on a pill
          // the app lights (a held pedal always is). A fill on another pill
          // carries on.
          if (g_haveFrame && !g_frame.goodbye && (g_frame.active_button_mask & (1u << button))) {
            g_clearFlashing[button] = true;
            g_clearFlashAtMs[button] = millis();
          }
          if (g_clearHold.button == decoded.button) g_clearHold = {0, 0};
        } else {
          // A new hold on a flashing pill takes it over.
          if (decoded.button != 0) g_clearFlashing[button] = false;
          g_clearHold = decoded;
          g_clearHoldAtMs = millis();
        }
      }
      break;
    }
    case PEDAL_LINK_TYPE_LED_LEVEL: {
      uint8_t level;
      if (pedal_link_decode_led_level(payload, len, &level)) {
        g_ledTarget = level;
        // With nothing lit there is nothing to fade: a board that restarted,
        // or that the app just reconnected to, starts at the app's level
        // instead of flashing full and fading down. The app sends the level
        // before the STATE that answers a hello for this.
        if (!g_haveFrame) g_ledLevel = level;
      }
      break;
    }
    case PEDAL_LINK_TYPE_RING_BRIDGE:
      if (len == 2 && payload[0] == PEDAL_LINK_RING_BRIDGE_MAGIC0 && payload[1] == PEDAL_LINK_RING_BRIDGE_MAGIC1)
        startBridge();
      break;
    default:
      break;
  }
}

static bool g_bridging = false;

static void pollLink() {
  // Stops at RING_BRIDGE: every byte after it belongs to the ring.
  while (!g_bridging && LINK.available() > 0) {
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

// ---- ring carrier -------------------------------------------------------------
// The ring renders from five bytes: the activity colour, the master level and
// three flags. The XIAO keeps its own animation clock, gain-arc timer and
// frozen-comet colour, so this side only says what the app's frame means.
static Rgb globalColor(uint8_t color);

static ring_link::RingState ringStateFromFrame() {
  ring_link::RingState state;
  if (!g_haveFrame || g_frame.goodbye) return state;
  const Rgb activity = globalColor(g_frame.global_color);
  state.r = activity.r;
  state.g = activity.g;
  state.b = activity.b;
  state.gain = g_frame.master_gain;
  state.flags = ring_link::FLAG_LIVE;
  // Blue is the record-armed hint, not transport activity: no comet for it.
  if ((activity.r || activity.g || activity.b) && g_frame.global_color != PEDAL_GLOBAL_BLUE)
    state.flags |= ring_link::FLAG_ACTIVE;
  if (g_frame.loop_length_micros > 0) state.flags |= ring_link::FLAG_LOADED;
  if (g_frame.dimmed) state.flags |= ring_link::FLAG_DIMMED;
  return state;
}

// The LED level follows every state: ring firmware 1.1 and older drop it
// and stay at full brightness.
static void sendRingState() {
  uint8_t payload[ring_link::STATE_LEN], packet[ring_link::MAX_FRAME];
  ring_link::encodeState(ringStateFromFrame(), payload);
  ringLink.write(packet, ring_link::encode(ring_link::STATE, payload, packet));
  const uint8_t level[ring_link::LEVEL_LEN] = {g_ledLevel};
  ringLink.write(packet, ring_link::encode(ring_link::LEVEL, level, packet));
  g_lastRingStateMs = millis();
}

static void sendEncoderButton(bool pressed) {
  if (pressed == g_ringButtonPressed) return;
  g_ringButtonPressed = pressed;
  uint8_t buf[PEDAL_LINK_MAX_FRAME];
  sendFrame(buf, pedal_link_encode_encoder_button(pressed ? 1 : 0, buf));
}

// One ENCODER message per click and one ENCODER_BUTTON per edge, as the v2
// board sent from its own pins. A reset (the XIAO rebooted, or went quiet for
// 500 ms) replays nothing: it only brings the button to its current state.
static void pollRing() {
  while (ringLink.available() > 0) {
    uint8_t type;
    const uint8_t *payload;
    if (!g_ringParser.push((uint8_t)ringLink.read(), type, payload) ||
        type != ring_link::INPUT_STATE) continue;
    const ring_link::InputDelta change = g_ringInput.accept(payload, millis());
    if (change.reset) {
      sendEncoderButton(change.pressed);
      continue;
    }
    for (uint32_t edge = 0; edge < change.edges; ++edge) sendEncoderButton(!g_ringButtonPressed);
    for (int32_t step = 0; step < (change.detents < 0 ? -change.detents : change.detents); ++step) {
      uint8_t buf[PEDAL_LINK_MAX_FRAME];
      sendFrame(buf, pedal_link_encode_encoder(change.detents > 0 ? 1 : -1, buf));
    }
  }
  if (g_ringInput.expire(millis())) sendEncoderButton(false);
}

// ---- ring-update bridge ---------------------------------------------------------
// segno-ring-flash runs before the app. It sends RING_BRIDGE, then talks to the
// XIAO through this board: every byte is copied between the Pi's UART and the
// ring's, at the same 115200 baud, and nothing else runs. The Pi ends it with
// a BRIDGE_END update frame, which this board spots in the Pi's stream (the
// ring ignores it); if the Pi goes quiet instead, the bridge ends on its own.
static const unsigned long BRIDGE_IDLE_MS = 5000;
static unsigned long g_bridgeLastMs = 0;
static uint8_t g_bridgeBody[8];  // BRIDGE_END and its CRC; anything longer is not it
static ring_frame_parser g_bridgeParser;

static void startBridge() {
  g_bridging = true;
  g_bridgeLastMs = millis();
  ring_frame_parser_init(&g_bridgeParser, g_bridgeBody, sizeof(g_bridgeBody));
  ind.ClearTo(RgbColor(0));
  ind.Show();
}

static void endBridge() {
  g_bridging = false;
  pedal_link_parser_init(&g_parser);
  g_ringParser = ring_link::Parser();
  g_haveFrame = false;
  resetLedLevel();
  sendRingState();
  sendHello();
  g_lastHelloMs = millis();
}

static void pumpBridge() {
  const unsigned long now = millis();
  while (LINK.available() > 0) {
    const uint8_t byte = (uint8_t)LINK.read();
    ringLink.write(&byte, 1);
    g_bridgeLastMs = now;
    size_t length = 0;
    uint8_t type;
    const uint8_t *payload;
    size_t n;
    if (ring_frame_parser_push(&g_bridgeParser, byte, &length) &&
        ring_update_message(g_bridgeBody, length, &type, &payload, &n) && type == RING_UPDATE_BRIDGE_END) {
      endBridge();
      return;
    }
  }
  while (ringLink.available() > 0) {
    const uint8_t byte = (uint8_t)ringLink.read();
    LINK.write(&byte, 1);
  }
  if (now - g_bridgeLastMs >= BRIDGE_IDLE_MS) endBridge();
}

// ---- CTRL jacks --------------------------------------------------------------
// One jack takes an expression pedal OR a footswitch, and nobody tells the
// board which. A switch only ever sits at the rails; a pot passes through the
// middle and stays there. So a jack is unknown until it is caught HOLDING an
// intermediate reading, and from then on it is an expression pedal. Measured
// on the bench (2026-09-03): a BOSS FS-6 reads 10 and 4095, an M-Audio EX-P
// sweeps 385..4095.
//
// Three things used to make plugging in and out weird, and this block is
// shaped around them:
//   * A plug sliding in brushes the tip past the other contacts for tens of
//     ms and reads 0 or 4095 on the way. On an expression jack that was a
//     reported slam to one end. Now a jump of CTRL_JUMP or more between two
//     samples starts a quiet period, and nothing is reported until the reading
//     has held still for CTRL_SETTLE_MS. Feet cannot do that; plugs do.
//   * An EMPTY jack reads 4095 -- exactly full toe. Pulling a pedal out drove
//     its target to 100% and left it there. Now a jump that lands on the top
//     rail and stays there for CTRL_DETACH_MS is reported as KIND_NONE, and the
//     app holds whatever the pedal was doing. (A real toe is reached by
//     motion, not by a jump; a hard kick still moves in steps well under
//     CTRL_JUMP at 10 ms sampling.) With a switched jack (board v3) presence
//     is a wire and none of this guessing is needed for it.
//   * The classification was one-way per boot: once an expression pedal, a
//     jack read a later footswitch as a pedal parked at an end. NONE resets
//     it, and a switch jack only becomes an expression jack once a mid-scale
//     reading has HELD for CTRL_SETTLE_MS -- a plug transient never counts.
//   * Pressing a footswitch IS a rail-to-rail jump, so the quiet period above
//     swallowed it: every press and every release was reported ~210 ms late.
//     A jack only has to wait out a jump while a plug might still be arriving
//     -- while it is unknown or empty. Once the board knows the jack holds a
//     footswitch, an edge on it is a foot, debounced at 8 ms and sent at once.
//     The first press after a plug pays the settle time; no later one does.
//   * The ring contact sees the plug's TIP slide past on the way in and out
//     (the ring contact sits shallower than the tip contact), and with an
//     expression pedal that tip is a pot wiper dragged low while the plug's
//     ring brushes the sleeve spring. Read as a switch, that was "footswitch
//     B pressed" on a jack with no footswitch. So the ring is not a switch
//     until it has EARNED it: while the jack is unknown or empty, a ring
//     closure must hold for CTRL_SETTLE_MS (the first B press is late by
//     that much, the rest are debounced like any switch); a jump on the tip
//     silences the ring for the same quiet period; and a jack that turns out
//     to be an expression pedal has no ring switch at all -- its ring is the
//     pot's supply. On v2 only one hole is left: a jack already known as a
//     switch (a footswitch pulled out unseen) gets a pedal plugged in, and
//     the wiper's brush reports one B press before the pot reclassifies the
//     jack. A v3 jack's presence contact resets the jack to unknown first.
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
static const unsigned long CTRL_DETACH_MS = 1000;     // at the rail after a jump
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
static unsigned long g_ctrlRailSinceMs[PEDAL_CTRL_COUNT];    // top rail after a jump since
static bool g_ctrlJumped[PEDAL_CTRL_COUNT];                  // the last big move was a jump
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

// A lost source is not a physical release gesture. Reset contact state
// silently; the whole-jack NONE frame retires application obligations.
static void ctrlResetSwitch(uint8_t jack, uint8_t contact) {
  g_ctrlSwitchRaw[jack][contact] = false;
  g_ctrlSwitchClosed[jack][contact] = false;
  g_ctrlSwitchSinceMs[jack][contact] = 0;
}

static void ctrlDetach(uint8_t jack) {
  for (uint8_t c = 0; c < PEDAL_CTRL_CONTACT_COUNT; c++) ctrlResetSwitch(jack, c);
  if (g_ctrlKind[jack] != CTRL_NONE) {
    sendCtrl(jack, PEDAL_CTRL_TIP, PEDAL_CTRL_KIND_NONE, 0);
  }
  g_ctrlKind[jack] = CTRL_NONE;
  g_ctrlHaveSent[jack] = false;
  g_ctrlSent[jack] = 0;
  g_ctrlJumped[jack] = false;
  g_ctrlMidSinceMs[jack] = 0;
  g_ctrlRailSinceMs[jack] = 0;
}

static void pollCtrl() {
  const unsigned long now = millis();
  if (now - g_ctrlLastSampleMs < CTRL_SAMPLE_MS) return;
  g_ctrlLastSampleMs = now;

  for (uint8_t j = 0; j < PEDAL_CTRL_COUNT; j++) {
    // Presence, debounced: the jack's ring-normal contact, read E9-safely.
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
    // During presence debounce a pulled plug must not manufacture an 8 ms
    // switch-open edge before the 50 ms lifetime boundary can be confirmed.
    if (!presentRaw || !g_ctrlPresent[j]) continue;

    const uint16_t raw = ctrlSample(CTRL_PIN[j]);
    const uint16_t prev = g_ctrlRaw[j];
    g_ctrlRaw[j] = raw;
    const uint16_t delta = raw > prev ? raw - prev : prev - raw;
    const bool mid = raw > CTRL_LOW && raw < CTRL_HIGH;

    // A jump: a plug on its way in or out, never a foot. Say nothing until
    // the reading has held still, and remember that a jump happened so a
    // rail it lands on can be told from a rail it was walked to.
    if (delta >= CTRL_JUMP) {
      g_ctrlQuietUntilMs[j] = now + CTRL_SETTLE_MS;
      g_ctrlJumped[j] = true;
      g_ctrlMidSinceMs[j] = 0;
      g_ctrlRailSinceMs[j] = 0;
    }

    // A jack the board already knows holds a footswitch is not waiting for a
    // plug, and pressing that footswitch is itself a jump: report its edges
    // at once instead of making every press and release wait out the settle
    // time. The reclassification checks below still run once it is settled,
    // so swapping a pedal into this jack is still noticed.
    const bool known = g_ctrlKind[j] == CTRL_SWITCH;
    if (known && !mid) {
      pollCtrlSwitch(j, PEDAL_CTRL_TIP, raw < CTRL_LOW, now);
      pollCtrlRing(j, now);
    }
    if ((long)(now - g_ctrlQuietUntilMs[j]) < 0) continue;

    if (!known && !mid) pollCtrlRing(j, now);

    // Mid-scale that HOLDS is a pot. A single mid-scale sample is a plug
    // passing through, and on a switch jack that used to be enough to
    // reclassify it for the rest of the boot.
    if (mid) {
      if (g_ctrlMidSinceMs[j] == 0) g_ctrlMidSinceMs[j] = now;
      g_ctrlRailSinceMs[j] = 0;
      if (g_ctrlKind[j] != CTRL_EXPRESSION &&
          now - g_ctrlMidSinceMs[j] >= CTRL_SETTLE_MS) {
        // Reclassification retires BOTH switch contacts before the first
        // expression sample, including a jack identified by its ring alone.
        if (g_ctrlKind[j] == CTRL_SWITCH) ctrlDetach(j);
        else {
          for (uint8_t c = 0; c < PEDAL_CTRL_CONTACT_COUNT; c++) ctrlResetSwitch(j, c);
        }
        g_ctrlKind[j] = CTRL_EXPRESSION;
        g_ctrlHaveSent[j] = false;
        g_ctrlJumped[j] = false;
      }
    } else {
      g_ctrlMidSinceMs[j] = 0;
    }

    if (g_ctrlKind[j] == CTRL_EXPRESSION) {
      // Empty-jack detection for a pedal jack: a jump that landed on the top
      // rail and stayed there. Walking to the toe never sets g_ctrlJumped.
      if (g_ctrlJumped[j] && raw >= CTRL_HIGH) {
        if (g_ctrlRailSinceMs[j] == 0) g_ctrlRailSinceMs[j] = now;
        if (now - g_ctrlRailSinceMs[j] >= CTRL_DETACH_MS) {
          ctrlDetach(j);
        }
        // This may be an empty jack, not a pedal at full toe. Hold the last
        // reported position throughout detection: sending 255 while waiting
        // would turn a bound level fully up before NONE could preserve it.
        continue;
      } else if (raw < CTRL_HIGH) {
        g_ctrlRailSinceMs[j] = 0;
        g_ctrlJumped[j] = false;   // it moved: it is a pedal, being played
      }
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
    if (known || mid) continue;  // mid-scale is a classification candidate
    if (g_ctrlKind[j] == CTRL_NONE && raw >= CTRL_LOW) continue;
    if (g_ctrlKind[j] != CTRL_SWITCH && raw < CTRL_LOW) g_ctrlKind[j] = CTRL_SWITCH;
    if (g_ctrlKind[j] == CTRL_UNKNOWN) g_ctrlKind[j] = CTRL_SWITCH;
    pollCtrlSwitch(j, PEDAL_CTRL_TIP, raw < CTRL_LOW, now);
  }
}

// ---- light sensor (J22) ---------------------------------------------------------
// A reading every AMBIENT_SAMPLE_MS, with the pad's pulls off; ambient_light.h
// smooths them. Every AMBIENT_PROBE_MS the pad's pull-up, then its pull-down,
// is switched on for one sample slot each, and the readings say whether
// anything is on the pin (ambient_light_probe). Each step waits one slot,
// 10 ms, for the node to settle: the load and its 100 nF settle in about
// 1 ms. The probe's slots are not samples, so the pulls never shift a reading.
//
// The LEDs stay lit while it reads. The sensor is flush in the plate, looking
// straight up; every pill, the ring and both screens are flush with or below
// the plate surface, 76 mm or more away, so they sit about 90 degrees off its
// axis and the console's own light reaches it only by reflection off hands,
// the player and the knob. The median, the slow average and the hysteresis
// take that up, and the auto curve has a ceiling. If a bench shows the
// console's light moving the reading past the hysteresis, blank the pills for
// a sample slot here.
enum { AMBIENT_SAMPLING = 0, AMBIENT_PROBE_UP, AMBIENT_PROBE_DOWN, AMBIENT_SETTLE };
static ambient_light g_ambient;
static uint8_t g_ambientPhase = AMBIENT_SAMPLING;
static uint16_t g_ambientWithPullUp = 0;
static unsigned long g_ambientLastMs = 0;
static unsigned long g_ambientProbedMs = 0;

static uint16_t ambientRead() {
  // The first conversion after the CTRL jacks' shares its sample capacitor's
  // charge with GP28: drop it.
  (void)analogRead(PIN_AMBIENT);
  uint32_t total = 0;
  for (uint8_t i = 0; i < 8; i++) total += analogRead(PIN_AMBIENT);
  return (uint16_t)(total / 8);
}

static void pollAmbient() {
  const unsigned long now = millis();
  if (now - g_ambientLastMs < AMBIENT_SAMPLE_MS) return;
  g_ambientLastMs = now;
  switch (g_ambientPhase) {
    case AMBIENT_SAMPLING:
      if (!g_ambient.probed || now - g_ambientProbedMs >= AMBIENT_PROBE_MS) {
        gpio_pull_up(PIN_AMBIENT);
        g_ambientPhase = AMBIENT_PROBE_UP;
        return;
      }
      ambient_light_sample(&g_ambient, ambientRead());
      return;
    case AMBIENT_PROBE_UP:
      g_ambientWithPullUp = ambientRead();
      gpio_pull_down(PIN_AMBIENT);
      g_ambientPhase = AMBIENT_PROBE_DOWN;
      return;
    case AMBIENT_PROBE_DOWN:
      ambient_light_probe(&g_ambient, g_ambientWithPullUp, ambientRead());
      gpio_disable_pulls(PIN_AMBIENT);
      g_ambientProbedMs = now;
      g_ambientPhase = AMBIENT_SETTLE;
      return;
    default:
      g_ambientPhase = AMBIENT_SAMPLING;
      return;
  }
}

static void sendAmbient() {
  if (!ambient_light_ready(&g_ambient)) return;
  uint8_t buf[PEDAL_LINK_MAX_FRAME];
  sendFrame(buf, pedal_link_encode_ambient(ambient_light_sensor(&g_ambient),
                                           ambient_light_level(&g_ambient), buf));
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
static Rgb globalColor(uint8_t color) {
  switch (color) {
    case PEDAL_GLOBAL_GREEN: return {0, 255, 0};
    case PEDAL_GLOBAL_RED: return {255, 0, 0};
    // Yellow, on the owner's call. Equal red and green read lime on these LEDs;
    // green at 235 was matched by eye on the unit (#1064).
    case PEDAL_GLOBAL_AMBER: return {255, 235, 0};
    case PEDAL_GLOBAL_BLUE: return {0, 0, 255};
    default: return {0, 0, 0};
  }
}

// Per pill, the levels it last showed while queued and when it left the
// queue: the start of the blend to the diffused curve.
static uint8_t g_pillQueuedLevel[PEDAL_BTN_COUNT][PILL_PIXELS];
static bool g_pillWasQueued[PEDAL_BTN_COUNT];
static bool g_pillSettling[PEDAL_BTN_COUNT];
static unsigned long g_pillSettleAt[PEDAL_BTN_COUNT];

// The app owns both activation and hue for every physical button. The MCU
// only maps that snapshot to the fitted harness and applies optical limits.
static bool renderIndicators() {
  const unsigned long now = millis();
  RgbColor desired[IND_N];
  uint32_t channelTotal = 0;
  // A fill no message has refreshed is over, and forgotten, so it cannot
  // come back with a later frame or when millis() wraps.
  if (g_clearHold.button != 0 && now - g_clearHoldAtMs >= PEDAL_LINK_CLEAR_HOLD_STALE_MS) {
    g_clearHold = {0, 0};
  }
  const bool clearHoldLive = g_clearHold.button != 0;
  const uint32_t clearRed = rgb(PILL_CLEAR_RED.r, PILL_CLEAR_RED.g, PILL_CLEAR_RED.b);
  const uint8_t clearInk[3] = {
      (uint8_t)((((clearRed >> 16) & 255) * PILL_FILL_LEVEL + 127) / 255),
      (uint8_t)((((clearRed >> 8) & 255) * PILL_FILL_LEVEL + 127) / 255),
      (uint8_t)(((clearRed & 255) * PILL_FILL_LEVEL + 127) / 255)};
  const uint8_t clearPeakInk[3] = {
      (uint8_t)((((clearRed >> 16) & 255) * PILL_PEAK + 127) / 255),
      (uint8_t)((((clearRed >> 8) & 255) * PILL_PEAK + 127) / 255),
      (uint8_t)(((clearRed & 255) * PILL_PEAK + 127) / 255)};
  for (uint8_t group = 0; group < PEDAL_BTN_COUNT; ++group) {
    const uint8_t button = PILL_BUTTON[group];
    Rgb color = {0, 0, 0};
    bool lit = false, queued = false;
    if (g_haveFrame && !g_frame.goodbye &&
        (g_frame.active_button_mask & (1u << button))) {
      const pedal_color c = g_frame.pedal_colors[button];
      color = {c.r, c.g, c.b};
      lit = true;
      queued = g_frame.queued_button == button + 1;
    }
    // The app runs the hold; a pill only fills while the app lights it. The
    // flash that confirms a fired hold shows whatever the frame says.
    const bool clearing = lit && clearHoldLive && g_clearHold.button == button + 1;
    if (g_clearFlashing[button] && now - g_clearFlashAtMs[button] >= PILL_CLEAR_FLASH_TOTAL_MS) {
      g_clearFlashing[button] = false;
    }
    const bool flashing = g_haveFrame && !g_frame.goodbye && g_clearFlashing[button];
    // On for the even PILL_CLEAR_FLASH_MS slots of the flash, dark for the odd.
    const bool clearFlashOn = ((now - g_clearFlashAtMs[button]) / PILL_CLEAR_FLASH_MS) % 2 == 0;
    const bool underRed = clearing && pillReadsRed(color);
    const uint8_t *ink = underRed ? clearPeakInk : clearInk;
    // The app decides the queue. The board only records when a pill stops
    // being queued (the section started, the request was dropped, or the
    // pill now shows another track) and blends it from there.
    if (queued) {
      g_pillWasQueued[group] = true;
      g_pillSettling[group] = false;
    } else if (g_pillWasQueued[group]) {
      g_pillWasQueued[group] = false;
      g_pillSettling[group] = true;
      g_pillSettleAt[group] = now;
    }
    const unsigned long settled = now - g_pillSettleAt[group];
    if (!lit || settled >= PILL_SETTLE_MS) g_pillSettling[group] = false;
    // Preserve calibrated color ratios and the tested spatial curve, with no
    // extra gamma/dimmer. The total-current budget only dims crowded patterns.
    const uint32_t corrected = rgb(color.r, color.g, color.b);
    for (uint8_t pixel = 0; pixel < PILL_PIXELS; ++pixel) {
      uint8_t level = (uint8_t)(PILL_PEAK * PILL_WEIGHTS[pixel] / 255.0f + 0.5f);
      if (queued) {
        // A waiting section fills physical left to right by the app's
        // progress, every filled pixel at the same level; the leading pixel
        // fills partially so the edge moves smoothly. Nothing here can finish
        // it: 254 leaves the last pixel short, and only the engine's handoff
        // (a frame with no queue) lights the whole pill.
        const int16_t coverage = g_frame.queued_progress * PILL_PIXELS - pixel * 255;
        const uint16_t fill = coverage <= 0 ? 0 : coverage >= 255 ? 255 : coverage;
        level = (uint8_t)((PILL_FILL_LEVEL * fill + 127) / 255);
        g_pillQueuedLevel[group][pixel] = level;
      } else if (g_pillSettling[group]) {
        const int32_t from = g_pillQueuedLevel[group][pixel];
        level = (uint8_t)(from + ((int32_t)level - from) * (int32_t)settled /
                                     (int32_t)PILL_SETTLE_MS);
      }
      RgbColor value(
          (uint8_t)((((corrected >> 16) & 255) * level + 127) / 255),
          (uint8_t)((((corrected >> 8) & 255) * level + 127) / 255),
          (uint8_t)(((corrected & 255) * level + 127) / 255));
      if (clearing) {
        // A clear-track hold: red grows from both ends toward the centre over
        // whatever the pill shows, at the fill level (at full brightness over
        // a pill already red, dimmed to a third), the leading pixel on each
        // side blending in so the edges move smoothly. The clear itself is
        // the app's; it sends 255 when it fires, and the flash shows that.
        const uint8_t depth = pixel < PILL_PIXELS / 2 ? pixel : PILL_PIXELS - 1 - pixel;
        const int16_t coverage = g_clearHold.progress * (PILL_PIXELS / 2) - depth * 255;
        const uint16_t fill = coverage <= 0 ? 0 : coverage >= 255 ? 255 : coverage;
        if (underRed) {
          value = RgbColor((uint8_t)((value.R * PILL_CLEAR_UNDER_RED + 127) / 255),
                           (uint8_t)((value.G * PILL_CLEAR_UNDER_RED + 127) / 255),
                           (uint8_t)((value.B * PILL_CLEAR_UNDER_RED + 127) / 255));
        }
        const auto blend = [fill](uint8_t base, uint8_t over) {
          return (uint8_t)((base * (255u - fill) + over * fill + 127) / 255);
        };
        value = RgbColor(blend(value.R, ink[0]), blend(value.G, ink[1]), blend(value.B, ink[2]));
      }
      if (flashing) {
        value = clearFlashOn ? RgbColor(clearInk[0], clearInk[1], clearInk[2]) : RgbColor(0);
      }
      desired[pillPixelIndex(group, pixel)] = value;
      channelTotal += value.R + value.G + value.B;
    }
  }
  const uint8_t output = ring_link::outputLevel(g_ledLevel, g_haveFrame && g_frame.dimmed);
  bool changed = false;
  for (uint8_t pixel = 0; pixel < IND_N; ++pixel) {
    RgbColor value = desired[pixel];
    if (channelTotal > PILL_CHANNEL_BUDGET) {
      value.R = (uint32_t)value.R * PILL_CHANNEL_BUDGET / channelTotal;
      value.G = (uint32_t)value.G * PILL_CHANNEL_BUDGET / channelTotal;
      value.B = (uint32_t)value.B * PILL_CHANNEL_BUDGET / channelTotal;
    }
    // The app's LED level (#1564), and then the idle dim with the screens
    // (#1349), both after the budget so a crowded frame dims by the same
    // share as a sparse one.
    ring_link::scalePixel(value.R, value.G, value.B, output);
    if (ind.GetPixelColor(pixel) != value) {
      ind.SetPixelColor(pixel, value);
      changed = true;
    }
  }
  return changed;
}

// The 80-pixel chain uses DMA; unchanged frames are skipped, with a forced
// refresh to heal a glitched LED.
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
    pinMode(CTRL_RING_PIN[j], INPUT_PULLUP);
    // Pulled down with the input buffer off between samples (RP2350-E9).
    console_presence_begin(CTRL_PRESENT_PIN[j]);
    g_ctrlKind[j] = CTRL_UNKNOWN;
    g_ctrlRaw[j] = CTRL_MAX;
    g_ctrlSent[j] = 0;
    g_ctrlHaveSent[j] = false;
    g_ctrlQuietUntilMs[j] = 0;
    g_ctrlMidSinceMs[j] = 0;
    g_ctrlRailSinceMs[j] = 0;
    g_ctrlJumped[j] = false;
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
  // The first read hands the pad to the ADC (input buffer off, pulls off);
  // the probe's pulls go on after it.
  ambient_light_init(&g_ambient);
  g_ambientPhase = AMBIENT_SAMPLING;
  (void)analogRead(PIN_AMBIENT);

  // Before the link: an NVM write takes about a second, once per trigger.
  Wire.setSDA(PIN_PD_SDA);
  Wire.setSCL(PIN_PD_SCL);
  Wire.setClock(100000);
  Wire.setTimeout(25);
  Wire.begin();
  g_pdProfile = pd_trigger_provision(&PD_BUS);

  LINK.setTX(PIN_LINK_TX);
  LINK.setRX(PIN_LINK_RX);
  LINK.setFIFOSize(2048);  // room for two ring-update chunks while bridging
  LINK.begin(LINK_BAUD);
  pedal_link_parser_init(&g_parser);

  ringLink.begin(LINK_BAUD);
  ind.Begin();
  ind.ClearTo(RgbColor(0));
  ind.Show();
  sendRingState();  // dark until segno's first frame

  sendHello();
  g_lastHelloMs = millis();
}

void loop() {
  pollLink();
  if (g_bridging) {
    pumpBridge();
    return;
  }
  pollButtons();
  pollRing();
  pollCtrl();
  pollAmbient();

  const unsigned long now = millis();
  if (now - g_lastHelloMs >= HELLO_MS) {
    g_lastHelloMs = now;
    sendHello();
    sendPdStatus();
    sendAmbient();
    digitalWrite(LED_BUILTIN, !digitalRead(LED_BUILTIN));  // 0.5 Hz heartbeat
  }
  if (g_haveFrame && now - g_lastFrameMs > FRAME_TIMEOUT_MS) {
    g_haveFrame = false;
    g_clearHold = {0, 0};
    endClearFlashes();
    resetLedLevel();
    sendRingState();
  }
  if (now - g_lastRingStateMs >= ring_link::STATE_MS) sendRingState();
  if (now - g_lastRenderMs >= RENDER_MS) {
    g_lastRenderMs = now;
    if (g_ledLevel != g_ledTarget) {
      const int step = (int)g_ledTarget - (int)g_ledLevel;
      g_ledLevel = (uint8_t)(g_ledLevel + (step > LED_FADE_STEP    ? LED_FADE_STEP
                                           : step < -LED_FADE_STEP ? -LED_FADE_STEP
                                                                   : step));
      sendRingState();  // the ring fades with the pills
    }
    const bool refresh = now - g_lastRefreshMs >= REFRESH_MS;
    if (refresh) g_lastRefreshMs = now;
    if (renderIndicators() || refresh) {
      if (refresh) ind.Dirty();
      ind.Show();
    }
  }
}
