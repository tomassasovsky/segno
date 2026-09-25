#include <cassert>
#include <cstdio>
#include <string>

#include "../led_pill_test/led_pill_test.ino"

static void at(uint32_t now) {
  fake_arduino::now = now;
  loop();
}

static void send(const std::string &text) {
  for (unsigned char byte : text) fake_arduino::received.push_back(byte);
  while (Serial1.available()) loop();
}

static void expectGreen(const uint8_t (&expected)[8]) {
  assert(pill.shown.size() == 8);
  for (size_t i = 0; i < 8; ++i) assert(pill.shown[i] == (uint32_t)expected[i] << 8);
}

int main() {
  // The separately powered 40-pixel ring may retain the previous animation.
  for (uint16_t i = 0; i < 40; ++i) ring.setPixelColor(i, 0x00ff00);
  setup();
  assert(pill.pin == 18);
  assert(pill.type == (NEO_GRB + NEO_KHZ800));
  assert(ring.pin == 12 && ring.showCount == 1);
  assert(ring.shown.size() == 40);
  for (const auto pixel : ring.shown) assert(pixel == 0);
  for (const auto pin : SWITCH_PINS) assert(digitalRead(pin) == HIGH);

  const uint8_t dim[8] = {4, 10, 23, 29, 29, 23, 10, 4};
  const uint8_t bright[8] = {28, 69, 151, 191, 191, 151, 69, 28};
  const uint8_t dark[8] = {};
  expectGreen(dim);
  at(125);
  // At a quarter of the rising ramp, easing gives 54, not the linear ramp's 69.
  assert(pill.shown[3] == (54U << 8));
  at(500);
  expectGreen(bright);
  at(1000);
  expectGreen(dim);

  // The actual output remains symmetric with the two middle LEDs brightest
  // throughout a full breath. It rises, falls, and reaches both endpoints.
  uint32_t previous = pill.shown[3];
  for (uint32_t t = 1010; t <= 2000; t += 10) {
    at(t);
    for (size_t i = 0; i < 4; ++i) assert(pill.shown[i] == pill.shown[7 - i]);
    assert(pill.shown[0] < pill.shown[1]);
    assert(pill.shown[1] < pill.shown[2]);
    assert(pill.shown[2] < pill.shown[3]);
    assert(pill.shown[3] <= (191U << 8));
    assert(t <= 1500 ? pill.shown[3] >= previous : pill.shown[3] <= previous);
    previous = pill.shown[3];
  }

  // Full green bypasses the curve to distinguish light loss from dimming.
  const uint8_t full[8] = {255, 255, 255, 255, 255, 255, 255, 255};
  send("pill full\n");
  expectGreen(full);
  const auto &fullStatus = fake_arduino::sent.back();
  const std::string fullLine(fullStatus.begin(), fullStatus.end());
  assert(fullLine.find("mode=full active=full") != std::string::npos);
  assert(fullLine.find("peak=255") != std::string::npos);
  at(3000);
  expectGreen(full);
  send("pill on\r\n");
  expectGreen(bright);
  at(9876);
  expectGreen(bright);
  send("pill off\n");
  expectGreen(dark);
  at(9999);
  expectGreen(dark);
  send("pill status\n");
  const auto &status = fake_arduino::sent.back();
  const std::string line(status.begin(), status.end());
  assert(line.find("PILL v1 mode=off active=off") == 0);
  assert(line.find("pixels=0,0,0,0,0,0,0,0\n") != std::string::npos);

  // Invalid or overlong input cannot accidentally select a test mode.
  send(std::string(80, 'x') + "pill on\n");
  expectGreen(dark);
  send(std::string("pill on\0\n", 9));
  expectGreen(dark);
  send("on\n");
  expectGreen(dark);
  // Input still pending after one loop proves a serial flood yields to rendering.
  for (int i = 0; i < 100; ++i) fake_arduino::received.push_back('x');
  const unsigned beforeFlood = pill.showCount;
  at(10009);
  assert(Serial1.available() > 0);
  assert(pill.showCount > beforeFlood);
  send("\n");
  expectGreen(dark);
  send("pill on\n");
  expectGreen(bright);

  send("pill demo\n");
  const uint32_t start = (uint32_t)millis();
  at(start + 500);
  expectGreen(bright);
  at(start + 8000);
  expectGreen(bright);
  at(start + 10990);
  expectGreen(bright);
  at(start + 11000);
  expectGreen(dark);
  at(start + 12990);
  expectGreen(dark);
  at(start + 13000);
  expectGreen(dim);

  // Physical switches change modes only after a stable press.
  fake_arduino::digital[3] = LOW;
  at(24000);
  at(24007);
  assert(mode == DEMO);
  at(24008);
  assert(mode == OFF);
  expectGreen(dark);
  fake_arduino::digital[4] = LOW;
  at(24010);
  at(24018);
  assert(mode == ON);
  expectGreen(bright);
  fake_arduino::digital[2] = LOW;
  at(24020);
  at(24028);
  assert(mode == BREATHE);
  expectGreen(dim);
  for (const auto pin : SWITCH_PINS) fake_arduino::digital[pin] = HIGH;
  at(24030);
  at(24038);
  assert(mode == BREATHE);

  // A millis() rollover must not change the phase or skip the next frame.
  at(UINT32_MAX - 99);
  send("pill breathe\n");
  at(400);
  expectGreen(bright);
  at(900);
  expectGreen(dim);
  assert(ring.showCount == 1);
  puts("LED pill: pixel output, breathing, modes, UART, switches and rollover pass");
}
