#include <cstdio>
#include <cstdlib>
#include "../console_board/console_board.ino"
#define CHECK(x, msg) do { if (!(x)) { std::fprintf(stderr, "FAIL %s:%d %s\n", __FILE__, __LINE__, msg); std::exit(1); } } while (0)
static void queueInput(uint32_t session, uint32_t count, uint32_t edges) {
  uint8_t payload[12], encoded[ring_link::MAX_FRAME];
  ring_link::put32(payload, session); ring_link::put32(payload + 4, count); ring_link::put32(payload + 8, edges);
  size_t size = ring_link::encode(ring_link::INPUT_STATE, payload, encoded);
  for (size_t i = 0; i < size; ++i) ringLink.received.push_back(encoded[i]);
}
static bool dark() {
  for (uint32_t pixel : fake_pixels::values[PIN_IND]) if (pixel) return false;
  return true;
}
static void indicators() {
  setup();
  CHECK(ringLink.tx == 13 && ringLink.rx == 14, "console v3 routes PIO UART on GP13/14");
  CHECK(fake_pixels::values[PIN_IND].size() == 80 && dark(), "all 80 physical LEDs start dark");
  // An asymmetric left-to-right probe makes the harness direction observable;
  // a symmetric diffuser gradient alone cannot catch a reversed pixel map.
  for (uint8_t group = 0; group < 10; ++group)
    for (uint8_t pixel = 0; pixel < 8; ++pixel)
      ind.setPixelColor(pillPixelIndex(group, pixel), (pixel + 1) * 24);
  const auto &pixels = fake_pixels::values[PIN_IND];
  for (unsigned group = 0; group < 8; ++group) {
    CHECK(pixels[group * 8] == 96 && pixels[group * 8 + 7] == 12,
          "front-row data enters the right end of every pill");
  }
  CHECK(pixels[64] == 12 && pixels[71] == 96 && pixels[72] == 12 && pixels[79] == 96,
        "CLEAR and BANK data enter their left ends");
  ind.clear();
  fake_arduino::now = 100;
  loop();
  CHECK(dark(), "waiting for host never creates a startup LED load");
  pedal_state frame = {};
  frame.mode = PEDAL_MODE_FX; frame.global_color = PEDAL_GLOBAL_GREEN;
  frame.active_bank = 1; frame.clear_fade = 1;
  frame.track_leds[4] = PEDAL_LED_RED; frame.track_leds[5] = PEDAL_LED_GREEN;
  frame.track_leds[6] = PEDAL_LED_BLUE; frame.track_leds[7] = PEDAL_LED_OFF;
  uint8_t encoded[PEDAL_LINK_MAX_FRAME]; pedal_link_encode_state(&frame, encoded);
  handleMessage(PEDAL_LINK_TYPE_STATE, encoded + 3, PEDAL_LINK_STATE_LEN);
  renderIndicators();
  CHECK(pixels[59] == 0x008000, "REC/PLAY is physical pill seven");
  CHECK(pixels[35] == 0x000080, "MODE is physical pill four");
  CHECK(pixels[3] == 0 && pixels[11] == 0x000080,
        "the chain starts with active-bank TRACK4 then TRACK3");
  CHECK(pixels[19] == 0x008000 && pixels[27] == 0x800000,
        "TRACK2 then TRACK1 complete the reversed track order");
  CHECK(pixels[43] == 0 && pixels[51] == 0, "UNDO and playing STOP remain dark");
  CHECK(pixels[67] == 0x800000 && pixels[75] == 0x000080,
        "CLEAR/BANK occupy final two groups");
  for (unsigned group = 0; group < 10; ++group)
    for (unsigned i = 0; i < 4; ++i)
      CHECK(pixels[group * 8 + i] == pixels[group * 8 + 7 - i], "gradient symmetric around two centre pixels");
  const uint8_t expectedGreen[8] = {19, 46, 101, 128, 128, 101, 46, 19};
  for (unsigned i = 0; i < 8; ++i)
    CHECK(pixels[56 + i] == (uint32_t)expectedGreen[i] << 8,
          "REC/PLAY uses the approved eight-pixel curve with one brightness cap");
  // Give each track a unique one-at-a-time input in each bank. All eight track
  // entries must reach the right physical group, with no stale pixels behind.
  for (uint8_t bank = 0; bank < 2; ++bank) {
    for (uint8_t track = 0; track < 4; ++track) {
      g_frame = {};
      g_frame.active_bank = bank;
      g_frame.track_leds[bank * 4 + track] = PEDAL_LED_RED;
      renderIndicators();
      for (unsigned group = 0; group < 4; ++group)
        for (unsigned i = 0; i < 8; ++i)
          CHECK(pixels[group * 8 + i] ==
                    (group == 3U - track ? (uint32_t)expectedGreen[i] << 16 : 0),
                "each bank track lights only its matching eight-pixel pill");
    }
  }
  g_frame = {}; g_frame.loop_length_micros = 1000000;
  renderIndicators();
  CHECK(pixels[51] == 0 && pixels[59] == 0,
        "a silent loaded loop does not invent a STOP state");
  g_frame.goodbye = 1; renderIndicators(); CHECK(dark(), "goodbye clears every LED");
  g_frame.goodbye = 0; g_haveFrame = false; renderIndicators(); CHECK(dark(), "expired host frame clears every LED");
}
static void receiveHostState(const pedal_state &state, uint32_t now) {
  uint8_t encoded[PEDAL_LINK_MAX_FRAME];
  const size_t length = pedal_link_encode_state(&state, encoded);
  CHECK(length > 0, "test state encodes");
  for (size_t i = 0; i < length; ++i) Serial1.received.push_back(encoded[i]);
  fake_arduino::now = now;
  loop();
}
static void queuedPills() {
  pedal_state frame = {};
  frame.mode = PEDAL_MODE_PLAY;
  frame.looper_mode = PEDAL_LOOPER_SONG;
  frame.queued_track = 2;  // Logical TRACK2, physical group two.
  frame.track_leds[0] = PEDAL_LED_RED;
  frame.track_leds[1] = PEDAL_LED_BLUE;
  uint32_t now = 10000;
  receiveHostState(frame, now);
  const auto &pixels = fake_pixels::values[PIN_IND];
  for (unsigned i = 16; i < 24; ++i)
    CHECK(pixels[i] == 0, "a fresh queue starts with an empty pill");
  CHECK(pixels[27] == 0x800000, "the currently active track keeps its state color");

  frame.queued_progress = 16;
  receiveHostState(frame, now += 20);
  CHECK(pixels[23] == 0x000900, "queue partially fills the physical leftmost pixel");
  for (unsigned i = 16; i < 23; ++i)
    CHECK(pixels[i] == 0, "queue does not run backwards along the reversed data harness");

  frame.queued_progress = 128;
  receiveHostState(frame, now += 20);
  const uint8_t halfFill[8] = {0, 0, 0, 2, 128, 101, 46, 19};
  for (unsigned i = 0; i < 8; ++i)
    CHECK(pixels[16 + i] == (uint32_t)halfFill[i] << 8,
          "128/255 progress fills the left half plus a partial leading pixel");
  const auto halfway = pixels;
  fake_arduino::now = now += 1000;
  loop();
  CHECK(pixels == halfway, "elapsed device time cannot advance the app's queue");

  frame.queued_progress = 254;
  receiveHostState(frame, now += 20);
  CHECK(pixels[16] == 0x001200 && pixels[23] == 0x001300,
        "maximum queued progress still leaves the final physical pixel incomplete");
  CHECK(pixels[19] == 0x008000 && pixels[20] == 0x008000,
        "near-completion preserves both center peaks");

  // Changing the visible bank hides the old queue instead of moving it to the
  // corresponding switch in that bank. Returning shows the same app snapshot.
  frame.active_bank = 1;
  frame.track_leds[5] = PEDAL_LED_RED;
  receiveHostState(frame, now += 20);
  CHECK(pixels[19] == 0x800000 && pixels[16] == 0x130000,
        "a queue in bank A cannot replace bank B's normal track color");
  frame.queued_track = 6;
  frame.queued_progress = 128;
  receiveHostState(frame, now += 20);
  for (unsigned i = 0; i < 8; ++i)
    CHECK(pixels[16 + i] == (uint32_t)halfFill[i] << 8,
          "bank B's queued logical track reaches the same physical pill");

  frame.mode = PEDAL_MODE_REC;
  receiveHostState(frame, now += 20);
  CHECK(pixels[19] == 0x800000, "Record mode suppresses the queued fill");
  frame.mode = PEDAL_MODE_FX;
  receiveHostState(frame, now += 20);
  CHECK(pixels[19] == 0x800000, "FX mode suppresses the queued fill");
  frame.mode = PEDAL_MODE_PLAY;
  frame.looper_mode = PEDAL_LOOPER_MULTI;
  receiveHostState(frame, now += 20);
  CHECK(pixels[19] == 0x800000, "non-Song playback suppresses the queued fill");
  frame.looper_mode = PEDAL_LOOPER_SONG;
  frame.queued_track = PEDAL_NO_QUEUED_TRACK;
  frame.queued_progress = 0;
  receiveHostState(frame, now += 20);
  CHECK(pixels[19] == 0x800000 && pixels[16] == 0x130000,
        "cancelling restores the normal track state without leftover fill");

  // Only the app's completed state changes the queued pill to fully playing.
  frame.queued_track = 6;
  frame.queued_progress = 254;
  receiveHostState(frame, now += 20);
  frame.queued_track = PEDAL_NO_QUEUED_TRACK;
  frame.queued_progress = 0;
  frame.track_leds[5] = PEDAL_LED_GREEN;
  receiveHostState(frame, now += 20);
  CHECK(pixels[16] == 0x001300 && pixels[23] == 0x001300,
        "confirmed completion restores the full symmetric green pill");

  frame.queued_track = 6;
  frame.queued_progress = 128;
  frame.goodbye = 1;
  receiveHostState(frame, now += 20);
  CHECK(dark(), "goodbye suppresses an in-progress queue");
  frame.goodbye = 0;
  receiveHostState(frame, now += 20);
  fake_arduino::now = now += FRAME_TIMEOUT_MS + 1;
  loop();
  CHECK(dark(), "host lease expiry clears the queued fill");
  frame.queued_track = PEDAL_NO_QUEUED_TRACK;
  frame.queued_progress = 0;
  receiveHostState(frame, now += 20);
  CHECK(pixels[16] == 0x001300, "reconnect renders current state instead of reviving a queue");
}
static void physicalAcknowledgements() {
  pedal_state frame = {};
  frame.loop_length_micros = 1000000;
  uint32_t now = 30000;
  receiveHostState(frame, now);
  const auto &pixels = fake_pixels::values[PIN_IND];
  CHECK(pixels[51] == 0 && pixels[43] == 0, "idle STOP and UNDO are dark");
  fake_arduino::digital[FSW_PIN[PEDAL_BTN_STOP]] = LOW;
  fake_arduino::digital[FSW_PIN[PEDAL_BTN_UNDO]] = LOW;
  fake_arduino::now = now += 20; loop();
  CHECK(pixels[51] == 0 && pixels[43] == 0, "raw switch edges await debounce");
  fake_arduino::now = now += 20; loop();
  CHECK(pixels[51] == 0x800000 && pixels[43] == 0x000080,
        "debounced STOP and UNDO presses update without a new host frame");
  fake_arduino::digital[FSW_PIN[PEDAL_BTN_STOP]] = HIGH;
  fake_arduino::digital[FSW_PIN[PEDAL_BTN_UNDO]] = HIGH;
  fake_arduino::now = now += 20; loop();
  fake_arduino::now = now += 20; loop();
  CHECK(pixels[51] == 0 && pixels[43] == 0, "release removes both press acknowledgements");
}
static void recoveredInput() {
  g_ringInput = {}; g_ringParser = {}; ringLink.received.clear();
  fake_arduino::sent.clear(); fake_arduino::now = 1000;
  queueInput(1, 0, 0); pollRing();
  fake_arduino::now = 1080;
  queueInput(1, 3, 2); pollRing();
  CHECK(g_ringButtonPresses == 1 && g_ringButtonReleases == 1 && !g_ringButtonPressed,
        "short press/release survives complete snapshot loss");
  pedal_link_parser parser; pedal_link_parser_init(&parser);
  int detents = 0;
  for (const auto &packet : fake_arduino::sent) for (uint8_t byte : packet) {
    uint8_t type, length; const uint8_t *payload;
    if (pedal_link_parser_push(&parser, byte, &type, &payload, &length) && type == PEDAL_LINK_TYPE_ENCODER)
      detents += (int8_t)payload[0];
  }
  CHECK(detents == 3, "recovered cumulative detents forwarded through real app codec");
  queueInput(1, 3, 3); pollRing(); CHECK(g_ringButtonPressed, "held encoder button tracked");
  fake_arduino::now += ring_link::TIMEOUT_MS; pollRing();
  CHECK(!g_ringButtonPressed, "link loss releases held encoder button");
  fake_arduino::sent.clear(); queueInput(2, 400, 0); pollRing();
  CHECK(fake_arduino::sent.empty(), "ring reboot never produces phantom volume movement");
}
static pedal_state lastRingState() {
  ring_link::Parser parser;
  pedal_state state = {};
  bool found = false;
  for (const auto &packet : ringLink.sent) for (uint8_t byte : packet) {
    uint8_t type; const uint8_t *payload;
    if (parser.push(byte, type, payload) && type == ring_link::STATE) {
      CHECK(pedal_link_decode_state(payload, PEDAL_LINK_STATE_LEN, &state), "forwarded ring state is valid");
      found = true;
    }
  }
  CHECK(found, "console loop emits ring state");
  return state;
}
static void hostBridgeAndExpiry() {
  pedal_state frame = {};
  frame.global_color = PEDAL_GLOBAL_GREEN; frame.master_gain = 173;
  frame.looper_mode = PEDAL_LOOPER_SONG; frame.mode = PEDAL_MODE_PLAY;
  frame.queued_track = 4; frame.queued_progress = 128;
  uint8_t encoded[PEDAL_LINK_MAX_FRAME];
  const size_t length = pedal_link_encode_state(&frame, encoded);
  fake_arduino::now = 2000;
  for (size_t i = 0; i < length; ++i) Serial1.received.push_back(encoded[i]);
  ringLink.sent.clear();
  loop();
  CHECK(!dark(), "real host UART state illuminates physical pills");
  pedal_state forwarded = lastRingState();
  CHECK(!forwarded.goodbye && forwarded.global_color == PEDAL_GLOBAL_GREEN && forwarded.master_gain == 173,
        "host state crosses production parser and ring UART bridge");
  CHECK(forwarded.queued_track == 4 && forwarded.queued_progress == 128,
        "ring bridge forwards both new state bytes without truncation");
  // Corruption arriving near the lease boundary cannot renew the old frame.
  fake_arduino::now += FRAME_TIMEOUT_MS - 1;
  encoded[length - 1] ^= 1;
  for (size_t i = 0; i < length; ++i) Serial1.received.push_back(encoded[i]);
  loop();
  CHECK(!dark(), "last valid host frame remains until lease expires");
  fake_arduino::now += ring_link::STATE_MS + 1;
  ringLink.sent.clear(); loop();
  CHECK(dark(), "host expiry in real loop clears every physical pill");
  CHECK(lastRingState().goodbye, "host expiry forwards goodbye to ring despite corrupt traffic");
  CHECK(lastRingState().queued_track == PEDAL_NO_QUEUED_TRACK && !lastRingState().queued_progress,
        "expired host queue is absent from the ring goodbye state");
  encoded[length - 1] ^= 1;
  fake_arduino::now += ring_link::STATE_MS;
  for (size_t i = 0; i < length; ++i) Serial1.received.push_back(encoded[i]);
  ringLink.sent.clear(); loop();
  CHECK(!dark() && !lastRingState().goodbye,
        "valid host reconnection restores indicators and ring state");
}
int main() { indicators(); queuedPills(); physicalAcknowledgements(); hostBridgeAndExpiry(); recoveredInput(); std::puts("Console v3 physical chain, queue progress and ring input: ALL PASSED"); }
