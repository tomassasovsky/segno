// Standalone diffuser bench test for one eight-pixel WS2812B pill on J7.
// This temporarily replaces the console controller. See README.md to restore it.
#include <Adafruit_NeoPixel.h>
#include <stdio.h>
#include <string.h>

static const uint8_t PIXEL_COUNT = 8;
static const uint8_t PIXEL_PIN = 18;
static const uint8_t PEAK = 191;  // 75% of the green channel; no second dimmer.
static const uint32_t PERIOD_MS = 1000;
// Cosine-shaped spatial curve, normalized to the two middle LEDs.
static const uint8_t WEIGHTS[PIXEL_COUNT] = {38, 92, 201, 255, 255, 201, 92, 38};
static const uint8_t SWITCH_PINS[] = {2, 3, 4};  // REC/PLAY, STOP, UNDO.
enum Mode { BREATHE, OFF, ON, DEMO, FULL };
static const Mode SWITCH_MODES[] = {BREATHE, OFF, ON};
static const uint32_t DEMO_MS = 13000;  // 8 s breathe, 3 s on, 2 s off.

Adafruit_NeoPixel pill(PIXEL_COUNT, PIXEL_PIN, NEO_GRB + NEO_KHZ800);
Adafruit_NeoPixel ring(40, 12, NEO_GRB + NEO_KHZ800);
static Mode mode = BREATHE;
static uint32_t modeStarted = 0;
static uint32_t lastFrame = 0;
static uint32_t lastStatus = 0;
static uint8_t levels[PIXEL_COUNT] = {};
static int switchRaw[3] = {HIGH, HIGH, HIGH};
static int switchStable[3] = {HIGH, HIGH, HIGH};
static uint32_t switchChanged[3] = {};
static char command[24];
static uint8_t commandLength = 0;
static bool commandOverflow = false;

static const char* modeName(Mode value) {
  switch (value) {
    case BREATHE: return "breathe";
    case OFF: return "off";
    case ON: return "on";
    case DEMO: return "demo";
    case FULL: return "full";
  }
  return "off";
}

static Mode activeMode(uint32_t elapsed) {
  if (mode != DEMO) return mode;
  const uint32_t position = elapsed % DEMO_MS;
  return position < 8000 ? BREATHE : position < 11000 ? ON : OFF;
}

static void render(uint32_t now) {
  const uint32_t elapsed = now - modeStarted;
  const Mode active = activeMode(elapsed);
  float envelope = 0;
  if (active == ON) envelope = 1;
  if (active == BREATHE) {
    const float phase = (elapsed % PERIOD_MS) / (float)PERIOD_MS;
    const float triangle = phase < 0.5f ? phase * 2 : (1 - phase) * 2;
    envelope = 0.15f + 0.85f * triangle * triangle * (3 - 2 * triangle);
  }
  for (uint8_t i = 0; i < PIXEL_COUNT; ++i) {
    levels[i] = active == FULL ? 255 :
        (uint8_t)(PEAK * envelope * WEIGHTS[i] / 255.0f + 0.5f);
    pill.setPixelColor(i, Adafruit_NeoPixel::Color(0, levels[i], 0));
  }
  pill.show();
}

static void report(uint32_t now) {
  char line[180];
  const int length = snprintf(line, sizeof(line),
      "PILL v1 mode=%s active=%s ms=%lu period=1000 peak=%u grb=1 pixels=%u,%u,%u,%u,%u,%u,%u,%u\n",
      modeName(mode), modeName(activeMode(now - modeStarted)),
      (unsigned long)now, activeMode(now - modeStarted) == FULL ? 255U : (unsigned)PEAK,
      levels[0], levels[1], levels[2], levels[3],
      levels[4], levels[5], levels[6], levels[7]);
  Serial1.write((const uint8_t*)line, (size_t)length);
  lastStatus = now;
}

static void selectMode(Mode next, uint32_t now) {
  mode = next;
  modeStarted = now;
  render(now);
  report(now);
}

static void receiveCommands(uint32_t now) {
  // Bound serial work so even a continuous stream cannot starve LED updates.
  for (uint8_t n = 0; n < 32 && Serial1.available(); ++n) {
    const int byte = Serial1.read();
    if (byte == '\r') continue;
    if (byte == '\n') {
      command[commandLength] = '\0';
      if (!commandOverflow) {
        if (!strcmp(command, "pill breathe")) selectMode(BREATHE, now);
        else if (!strcmp(command, "pill on")) selectMode(ON, now);
        else if (!strcmp(command, "pill off")) selectMode(OFF, now);
        else if (!strcmp(command, "pill demo")) selectMode(DEMO, now);
        else if (!strcmp(command, "pill full")) selectMode(FULL, now);
        else if (!strcmp(command, "pill status")) report(now);
      }
      commandLength = 0;
      commandOverflow = false;
    } else if (byte < 32 || byte > 126 || commandLength == sizeof(command) - 1) {
      commandOverflow = true;
    } else if (!commandOverflow) {
      command[commandLength++] = (char)byte;
    }
  }
}

static void pollSwitches(uint32_t now) {
  for (uint8_t i = 0; i < 3; ++i) {
    const int value = digitalRead(SWITCH_PINS[i]);
    if (value != switchRaw[i]) {
      switchRaw[i] = value;
      switchChanged[i] = now;
    }
    if (value != switchStable[i] && (uint32_t)(now - switchChanged[i]) >= 8) {
      switchStable[i] = value;
      if (value == LOW) selectMode(SWITCH_MODES[i], now);
    }
  }
}

void setup() {
  Serial1.setTX(16);
  Serial1.setRX(17);
  Serial1.begin(115200);
  for (uint8_t pin : SWITCH_PINS) pinMode(pin, INPUT_PULLUP);
  // Clear any state the separately powered encoder ring retained before reset.
  ring.begin();
  ring.clear();
  ring.show();
  pill.begin();
  pill.clear();
  pill.show();
  selectMode(BREATHE, (uint32_t)millis());
}

void loop() {
  const uint32_t now = (uint32_t)millis();
  receiveCommands(now);
  pollSwitches(now);
  if ((uint32_t)(now - lastFrame) >= 10) {
    render(now);
    lastFrame = now;
  }
  if ((uint32_t)(now - lastStatus) >= 1000) report(now);
}
