#include <cstdio>
#include <cstdlib>
#include "../ring_board/ring_board.ino"
#define CHECK(x, msg) do { if (!(x)) { std::fprintf(stderr, "FAIL %s:%d %s\n", __FILE__, __LINE__, msg); std::exit(1); } } while (0)
static bool dark() { for (uint32_t pixel : fake_pixels::values[PIN_RING]) if (pixel) return false; return true; }
static void sendState(const pedal_state &state) {
  uint8_t bytes[PEDAL_LINK_MAX_FRAME], encoded[ring_link::MAX_FRAME];
  pedal_link_encode_state(&state, bytes);
  size_t size = ring_link::encode(ring_link::STATE, bytes + 3, encoded);
  for (size_t i = 0; i < size; ++i) ringLink.received.push_back(encoded[i]);
}
static void encoder(uint8_t state) {
  fake_arduino::digital[PIN_ENC_A] = state >> 1;
  fake_arduino::digital[PIN_ENC_B] = state & 1;
  encoderSample();
}
int main() {
  setup();
  CHECK(PIN_RING == 26 && PIN_ENC_A == 27 && PIN_ENC_B == 28 && PIN_ENC_SW == 5,
        "XIAO D0..D3 mapped to actual physical module GPIOs");
  CHECK(ringLink.tx == 3 && ringLink.rx == 4, "XIAO ring TX D10 and RX D9 match PCB");
  CHECK(fake_pixels::values[PIN_RING].size() == 40, "the actual ring output has forty pixels");
  CHECK(dark(), "ring starts dark with no host state");
  pedal_state state = {}; state.master_gain = 128;
  sendState(state); fake_arduino::now = 20; loop();
  CHECK(!dark() && g_ringView == RING_BREATHE, "valid idle state preserves standby breathing");
  state.global_color = PEDAL_GLOBAL_RED; state.loop_length_micros = 1000000;
  sendState(state); fake_arduino::now = 40; loop();
  CHECK(g_ringView == RING_COMET, "record state preserves red comet");
  const auto frozen = fake_pixels::values[PIN_RING];
  state.global_color = PEDAL_GLOBAL_OFF; sendState(state); fake_arduino::now = 60; loop();
  CHECK(g_ringView == RING_COMET && fake_pixels::values[PIN_RING] == frozen,
        "stopping a loaded loop freezes the existing comet");
  state.master_gain = 255; sendState(state); fake_arduino::now = 80; loop();
  CHECK(g_ringView == RING_ARC, "gain update preserves temporary level arc");
  for (uint32_t pixel : fake_pixels::values[PIN_RING])
    CHECK(pixel == 0x008000, "maximum gain fills all forty pixels at the existing brightness cap");
  state.master_gain = 128; sendState(state); fake_arduino::now = 100; loop();
  for (unsigned i = 0; i < 40; ++i)
    CHECK(fake_pixels::values[PIN_RING][i] == (i < 21 ? 0x008000u : 0),
          "half gain scales its arc across forty pixels rather than twenty-four");
  state.master_gain = 0; sendState(state); fake_arduino::now = 120; loop();
  CHECK(dark() && g_ringView == RING_ARC, "zero gain clears the entire forty-pixel arc");
  state.goodbye = 1; sendState(state); fake_arduino::now = 140; loop();
  CHECK(dark(), "host goodbye immediately clears ring");
  state.goodbye = 0; state.master_gain = 255;
  sendState(state); fake_arduino::now = 160; loop();
  CHECK(!dark(), "reconnection restores current state");
  fake_arduino::now += ring_link::TIMEOUT_MS; loop();
  CHECK(dark() && !g_haveFrame, "missing console heartbeat blanks ring in 500ms");
  encoder(2); encoder(0); encoder(1); encoder(3);
  CHECK(g_encDetents == 1, "one clockwise detent reports once");
  encoder(1); encoder(0); encoder(2); encoder(3);
  CHECK(g_encDetents == 0, "one reverse detent cancels once");
  fake_arduino::digital[PIN_ENC_SW] = LOW; pollButton();
  fake_arduino::now += 8; pollButton();
  fake_arduino::digital[PIN_ENC_SW] = HIGH; pollButton();
  fake_arduino::now += 8; pollButton();
  CHECK(g_buttonEdges == 2 && !g_buttonStable, "press/release shorter than snapshot cadence counted");
  sendInput();
  ring_link::Parser parser; uint8_t type = 0; const uint8_t *payload = nullptr; bool decoded = false;
  for (uint8_t byte : ringLink.sent.back()) if (parser.push(byte, type, payload)) decoded = true;
  CHECK(decoded && type == ring_link::INPUT_STATE && ring_link::get32(payload + 8) == 2,
        "real ring sketch snapshot preserves both short-button edges");
  std::puts("Ring sketch rendering, timeout and encoder: ALL PASSED");
}
