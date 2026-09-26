// Temporary diagnostic for the old console PCB: ten eight-pixel pills on GP18.
// Always starts dark. Restore the appliance's installed firmware after testing.
#include <Adafruit_NeoPixel.h>
#include <stdio.h>
#include <string.h>

static const uint8_t PILL_COUNT = 10, PIXELS_PER_PILL = 8, PEAK = 32;
static const uint32_t SLOT_MS = 5000, RUN_MS = 2 * PILL_COUNT * SLOT_MS;
static const char* LABELS[PILL_COUNT] = {
    "4", "3", "2", "1", "MODE", "UNDO", "STOP", "REC/PLAY", "CLEAR", "BANK"};
Adafruit_NeoPixel pills(PILL_COUNT * PIXELS_PER_PILL, 18, NEO_GRB + NEO_KHZ800);
Adafruit_NeoPixel ring(24, 12, NEO_GRB + NEO_KHZ800);
static bool running = false;
static uint32_t started = 0;
static uint16_t lastStep = 65535;
static char command[24];
static uint8_t commandLength = 0;
static bool commandOverflow = false;

static void report(const char* state, uint8_t group = 0) {
  char line[120];
  const int size = snprintf(line, sizeof(line),
      "CHAIN state=%s pill=%s peak=32 pixels=80 elapsed=%lu\n", state,
      running ? LABELS[group] : "none", (unsigned long)((uint32_t)millis() - started));
  Serial1.write((const uint8_t*)line, (size_t)size);
}

static void stop() {
  running = false;
  pills.clear();
  pills.show();
  ring.clear();
  ring.show();
  report("off");
}

static void render(uint32_t now) {
  if (!running) return;
  const uint32_t elapsed = now - started;
  if (elapsed >= RUN_MS) { stop(); return; }
  const uint8_t group = (elapsed / SLOT_MS) % PILL_COUNT;
  const uint32_t phase = elapsed % SLOT_MS;
  // Three one-second primary colors, then eight 200 ms left-to-right steps.
  const uint8_t step = phase < 3000 ? phase / 1000 :
      phase < 4600 ? 3 + (phase - 3000) / 200 : 11;
  const uint16_t absoluteStep = (elapsed / SLOT_MS) * 12 + step;
  if (absoluteStep == lastStep) return;
  lastStep = absoluteStep;
  pills.clear();
  if (step < 3) {
    const uint32_t color = Adafruit_NeoPixel::Color(
        step == 0 ? PEAK : 0, step == 1 ? PEAK : 0, step == 2 ? PEAK : 0);
    for (uint8_t i = 0; i < PIXELS_PER_PILL; ++i)
      pills.setPixelColor(group * PIXELS_PER_PILL + i, color);
  } else if (step < 11) {
    const uint8_t physicalPixel = step - 3;
    const uint8_t wirePixel = group < 8 ? 7 - physicalPixel : physicalPixel;
    pills.setPixelColor(group * PIXELS_PER_PILL + wirePixel,
                        Adafruit_NeoPixel::Color(0, PEAK, 0));
  }
  pills.show();
  if (step < 4 || step == 11)
    report(step == 0 ? "red" : step == 1 ? "green" : step == 2 ? "blue" :
           step == 3 ? "chase-left-to-right" : "gap", group);
}

static void receive(uint32_t now) {
  for (uint8_t n = 0; n < 32 && Serial1.available(); ++n) {
    const int byte = Serial1.read();
    if (byte == '\r') continue;
    if (byte == '\n') {
      command[commandLength] = '\0';
      if (!commandOverflow) {
        if (!strcmp(command, "chain run") && !running) {
          started = now;
          lastStep = 65535;
          running = true;
        } else if (!strcmp(command, "chain off")) stop();
      }
      commandLength = 0;
      commandOverflow = false;
    } else if (byte < 32 || byte > 126 || commandLength == sizeof(command) - 1) {
      commandOverflow = true;
    } else if (!commandOverflow) command[commandLength++] = (char)byte;
  }
}

void setup() {
  Serial1.setTX(16);
  Serial1.setRX(17);
  Serial1.begin(115200);
  pinMode(3, INPUT_PULLUP);  // Old board STOP: pressing it immediately blanks LEDs.
  ring.begin();
  pills.begin();
  stop();
}

void loop() {
  const uint32_t now = (uint32_t)millis();
  receive(now);
  if (running && digitalRead(3) == LOW) stop();
  render(now);
}
