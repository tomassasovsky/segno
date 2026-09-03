/*
 * Host contract test: the firmware's pedal_link.c against the golden fixtures
 * packages/pedal_repository generates from its own codec. Every fixture must
 * parse to exactly one valid frame, decode, and re-encode to the same bytes;
 * a handful are also checked field by field so a symmetric bug on both sides
 * (a shifted byte in both encoders, say) still fails.
 *
 * Built and run by run_tests.sh. Fixture dir: argv[1], or the default below.
 */
#include <dirent.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "../console_board/pedal_link.h"

#define DEFAULT_FIXTURES "packages/pedal_repository/test/fixtures"

static int g_failures = 0;
#define CHECK(cond, ...)                                     \
  do {                                                       \
    if (!(cond)) {                                           \
      g_failures++;                                          \
      fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__);   \
      fprintf(stderr, __VA_ARGS__);                          \
      fprintf(stderr, "\n");                                 \
    }                                                        \
  } while (0)

static size_t read_file(const char *path, uint8_t *buf, size_t cap) {
  FILE *f = fopen(path, "rb");
  if (!f) return 0;
  size_t n = fread(buf, 1, cap, f);
  fclose(f);
  return n;
}

/* Parse `bytes` one at a time; return how many valid frames completed, copy
 * the last one's type/payload out, and (when `dropped` is non-NULL) report how
 * many frames the parser threw away. */
static int parse_all(const uint8_t *bytes, size_t n, uint8_t *type, uint8_t *payload, uint8_t *len,
                     unsigned *dropped) {
  pedal_link_parser p;
  pedal_link_parser_init(&p);
  int frames = 0;
  for (size_t i = 0; i < n; i++) {
    uint8_t t, l;
    const uint8_t *pl;
    if (pedal_link_parser_push(&p, bytes[i], &t, &pl, &l)) {
      frames++;
      *type = t;
      *len = l;
      memcpy(payload, pl, l);
    }
  }
  if (dropped) *dropped = (unsigned)p.dropped;
  return frames;
}

/* Every enum value, by its Dart name, pinned to the C constant. A fixture
 * enum_<table>_<name>.bin exists for each; the count per table must equal the
 * C PEDAL_*_COUNT, so an added/removed/reordered value on either side fails. */
typedef struct { const char *name; int value; } enum_pin;
static const enum_pin BTN_PINS[] = {
  {"recPlay", PEDAL_BTN_REC_PLAY}, {"stop", PEDAL_BTN_STOP}, {"undo", PEDAL_BTN_UNDO},
  {"mode", PEDAL_BTN_MODE}, {"track1", PEDAL_BTN_TRACK1}, {"track2", PEDAL_BTN_TRACK2},
  {"track3", PEDAL_BTN_TRACK3}, {"track4", PEDAL_BTN_TRACK4}, {"clear", PEDAL_BTN_CLEAR},
  {"bank", PEDAL_BTN_BANK}};
static const enum_pin MODE_PINS[] = {
  {"rec", PEDAL_MODE_REC}, {"play", PEDAL_MODE_PLAY}, {"fx", PEDAL_MODE_FX}};
static const enum_pin LOOPER_PINS[] = {
  {"multi", PEDAL_LOOPER_MULTI}, {"sync", PEDAL_LOOPER_SYNC}, {"song", PEDAL_LOOPER_SONG},
  {"band", PEDAL_LOOPER_BAND}, {"free", PEDAL_LOOPER_FREE}};
static const enum_pin GLOBAL_PINS[] = {
  {"off", PEDAL_GLOBAL_OFF}, {"green", PEDAL_GLOBAL_GREEN}, {"red", PEDAL_GLOBAL_RED},
  {"amber", PEDAL_GLOBAL_AMBER}, {"blue", PEDAL_GLOBAL_BLUE}};
static const enum_pin LED_PINS[] = {
  {"off", PEDAL_LED_OFF}, {"green", PEDAL_LED_GREEN}, {"red", PEDAL_LED_RED},
  {"blue", PEDAL_LED_BLUE}};

typedef struct { const char *table; const enum_pin *pins; size_t n; int count; } enum_table;
static const enum_table TABLES[] = {
  {"button", BTN_PINS, sizeof(BTN_PINS) / sizeof(*BTN_PINS), PEDAL_BTN_COUNT},
  {"mode", MODE_PINS, sizeof(MODE_PINS) / sizeof(*MODE_PINS), PEDAL_MODE_COUNT},
  {"looper", LOOPER_PINS, sizeof(LOOPER_PINS) / sizeof(*LOOPER_PINS), PEDAL_LOOPER_COUNT},
  {"global", GLOBAL_PINS, sizeof(GLOBAL_PINS) / sizeof(*GLOBAL_PINS), PEDAL_GLOBAL_COUNT},
  {"led", LED_PINS, sizeof(LED_PINS) / sizeof(*LED_PINS), PEDAL_LED_COUNT},
};

static int g_enum_seen[sizeof(TABLES) / sizeof(*TABLES)];

/* enum_<table>_<name>.bin: check the wire value against the C constant. */
static void check_enum_fixture(const char *name, uint8_t type, const uint8_t *payload,
                               const pedal_state *st) {
  for (size_t t = 0; t < sizeof(TABLES) / sizeof(*TABLES); t++) {
    const enum_table *tab = &TABLES[t];
    size_t tl = strlen(tab->table);
    if (strncmp(name + 5, tab->table, tl) != 0 || name[5 + tl] != '_') continue;
    const char *val = name + 6 + tl;
    size_t vl = strlen(val) - 4; /* strip .bin */
    int want = -1;
    for (size_t i = 0; i < tab->n; i++) {
      if (strlen(tab->pins[i].name) == vl && strncmp(tab->pins[i].name, val, vl) == 0) {
        want = tab->pins[i].value;
      }
    }
    CHECK(want >= 0, "%s: Dart enum name unknown to the C table", name);
    if (want < 0) return;
    g_enum_seen[t]++;
    int got;
    if (strcmp(tab->table, "button") == 0) {
      CHECK(type == PEDAL_LINK_TYPE_BUTTON, "%s: not a BUTTON frame", name);
      got = payload[0];
    } else {
      CHECK(type == PEDAL_LINK_TYPE_STATE, "%s: not a STATE frame", name);
      got = strcmp(tab->table, "mode") == 0     ? st->mode
            : strcmp(tab->table, "looper") == 0 ? st->looper_mode
            : strcmp(tab->table, "global") == 0 ? st->global_color
                                                : st->track_leds[0];
    }
    CHECK(got == want, "%s: wire value %d, C constant %d", name, got, want);
    return;
  }
  CHECK(0, "%s: no C enum table for this fixture", name);
}

static void check_fixture(const char *dir, const char *name) {
  char path[1024];
  snprintf(path, sizeof(path), "%s/%s", dir, name);
  uint8_t bytes[256];
  size_t n = read_file(path, bytes, sizeof(bytes));
  CHECK(n >= 4, "%s: unreadable or too short", name);
  if (n < 4) return;

  uint8_t type = 0, len = 0, payload[PEDAL_LINK_MAX_PAYLOAD];
  int frames = parse_all(bytes, n, &type, payload, &len, NULL);
  CHECK(frames == 1, "%s: parsed %d frames, want 1", name, frames);
  if (frames != 1) return;

  /* Round trip through the firmware encoder. */
  uint8_t again[PEDAL_LINK_MAX_FRAME];
  size_t m = 0;
  pedal_state st;
  memset(&st, 0, sizeof(st));
  switch (type) {
    case PEDAL_LINK_TYPE_STATE:
      if (!pedal_link_decode_state(payload, len, &st)) {
        // Reading `st` after this would report indeterminate bytes as wire
        // values, which can pass by coincidence and hide the real failure.
        CHECK(0, "%s: decode_state rejected it", name);
        return;
      }
      m = pedal_link_encode_state(&st, again);
      break;
    case PEDAL_LINK_TYPE_BUTTON:
      CHECK(len == 2 && payload[0] < PEDAL_BTN_COUNT && payload[1] <= 1, "%s: bad button payload", name);
      m = pedal_link_encode_button(payload[0], payload[1], again);
      break;
    case PEDAL_LINK_TYPE_ENCODER:
      CHECK(len == 1, "%s: bad encoder payload", name);
      m = pedal_link_encode_encoder((int8_t)payload[0], again);
      break;
    case PEDAL_LINK_TYPE_CTRL:
      CHECK(len == 3, "%s: ctrl with %u payload bytes, want 3", name, len);
      CHECK(payload[0] < PEDAL_CTRL_COUNT, "%s: ctrl jack %u out of range", name, payload[0]);
      CHECK(payload[1] < PEDAL_CTRL_KIND_COUNT, "%s: ctrl kind %u out of range", name, payload[1]);
      m = pedal_link_encode_ctrl(payload[0], payload[1], payload[2], again);
      break;
    case PEDAL_LINK_TYPE_HELLO:
      CHECK(len == 3 && payload[0] == PEDAL_LINK_PROTOCOL_VERSION, "%s: bad hello", name);
      m = pedal_link_encode_hello(payload[1], payload[2], again);
      break;
    default:
      CHECK(0, "%s: unknown type 0x%02X", name, type);
      return;
  }
  CHECK(m == n && memcmp(again, bytes, n) == 0, "%s: re-encode differs (%zu vs %zu bytes)", name, m, n);

  if (strncmp(name, "enum_", 5) == 0) {
    check_enum_fixture(name, type, payload, &st);
    return;
  }

  /* Field checks on the named fixtures, against golden_frames.dart. */
  if (strcmp(name, "hello.bin") == 0) {
    CHECK(payload[1] == 1 && payload[2] == 0, "hello: fw %u.%u, want 1.0", payload[1], payload[2]);
  } else if (strcmp(name, "button_track3_down.bin") == 0) {
    CHECK(payload[0] == PEDAL_BTN_TRACK3 && payload[1] == 1, "button_track3_down: %u %u", payload[0], payload[1]);
  } else if (strcmp(name, "button_bank_up.bin") == 0) {
    CHECK(payload[0] == PEDAL_BTN_BANK && payload[1] == 0, "button_bank_up: %u %u", payload[0], payload[1]);
  } else if (strcmp(name, "encoder_minus3.bin") == 0) {
    CHECK((int8_t)payload[0] == -3, "encoder_minus3: %d", (int8_t)payload[0]);
  } else if (strcmp(name, "encoder_plus1.bin") == 0) {
    CHECK((int8_t)payload[0] == 1, "encoder_plus1: %d", (int8_t)payload[0]);
  } else if (strcmp(name, "playing_bankb.bin") == 0) {
    CHECK(st.active_bank == 1 && st.selected_track == 6 && st.mode == PEDAL_MODE_PLAY &&
              st.global_color == PEDAL_GLOBAL_AMBER && st.looper_mode == PEDAL_LOOPER_SYNC &&
              st.loop_length_micros == 4000000u && st.master_gain == 128 &&
              st.track_leds[0] == PEDAL_LED_GREEN && st.track_leds[6] == PEDAL_LED_RED &&
              !st.goodbye && !st.clear_fade,
          "playing_bankb: fields differ");
  } else if (strcmp(name, "blank_goodbye.bin") == 0) {
    CHECK(st.goodbye == 1 && st.global_color == PEDAL_GLOBAL_OFF && st.master_gain == 255,
          "blank_goodbye: fields differ");
  } else if (strcmp(name, "fx_mode.bin") == 0) {
    CHECK(st.mode == PEDAL_MODE_FX && st.looper_mode == PEDAL_LOOPER_FREE &&
              st.loop_length_micros == 0xFFFFFFFFu && st.track_leds[0] == PEDAL_LED_BLUE &&
              st.track_leds[1] == PEDAL_LED_OFF && st.selected_track == 2,
          "fx_mode: fields differ");
  } else if (strcmp(name, "mode_counting_in.bin") == 0) {
    CHECK(st.counting_in == 1 && st.looper_mode == PEDAL_LOOPER_BAND && st.global_color == PEDAL_GLOBAL_RED,
          "mode_counting_in: fields differ");
  }
}

static void check_rejections(void) {
  uint8_t frame[PEDAL_LINK_MAX_FRAME];
  size_t n = pedal_link_encode_button(PEDAL_BTN_UNDO, 1, frame);
  CHECK(n == 6, "button frame is %zu bytes, want 6", n);

  /* Corrupt checksum: dropped, then the next frame still parses. */
  uint8_t stream[12];
  memcpy(stream, frame, 6);
  stream[5] ^= 0x01;
  memcpy(stream + 6, frame, 6);
  uint8_t type, len, payload[PEDAL_LINK_MAX_PAYLOAD];
  unsigned dropped = 0;
  CHECK(parse_all(stream, 12, &type, payload, &len, &dropped) == 1,
        "corrupt checksum was not dropped / resync failed");
  CHECK(dropped == 1, "corrupt checksum: dropped %u, want 1", dropped);

  /* Garbage before a frame is skipped. */
  uint8_t junk[9] = {0x00, 0x13, 0x37};
  memcpy(junk + 3, frame, 6);
  CHECK(parse_all(junk, 9, &type, payload, &len, NULL) == 1, "garbage prefix broke parsing");

  /* A stray sync right before a frame, and a sync where a length byte should
   * be: the frame behind each still parses. */
  uint8_t stray[7] = {0xA5};
  memcpy(stray + 1, frame, 6);
  CHECK(parse_all(stray, 7, &type, payload, &len, &dropped) == 1, "stray sync ate the next frame");
  CHECK(dropped == 1, "stray sync: dropped %u, want 1", dropped);
  uint8_t synclen[8] = {0xA5, PEDAL_LINK_TYPE_STATE};
  memcpy(synclen + 2, frame, 6);
  CHECK(parse_all(synclen, 8, &type, payload, &len, &dropped) == 1,
        "sync in the length slot ate the next frame");
  CHECK(dropped == 1, "sync in length slot: dropped %u, want 1", dropped);

  /* Oversized length resyncs. */
  uint8_t big[10] = {0xA5, 0x01, PEDAL_LINK_MAX_PAYLOAD + 1, 0x00};
  memcpy(big + 4, frame, 6);
  CHECK(parse_all(big, 10, &type, payload, &len, NULL) == 1, "oversized length did not resync");

  /* A corrupted length that is still in range is rejected at the length byte,
   * so the frame that follows is NOT swallowed: a STATE header claiming 0x1F
   * followed immediately by a good BUTTON frame yields that button. */
  uint8_t badlen[9] = {0xA5, PEDAL_LINK_TYPE_STATE, PEDAL_LINK_STATE_LEN + 12};
  memcpy(badlen + 3, frame, 6);
  CHECK(parse_all(badlen, 9, &type, payload, &len, NULL) == 1 && type == PEDAL_LINK_TYPE_BUTTON,
        "in-range corrupted length swallowed the next frame");

  /* An unknown type is rejected at the type byte, same reason. */
  uint8_t badtype[9] = {0xA5, 0x7E, 0x02};
  memcpy(badtype + 3, frame, 6);
  CHECK(parse_all(badtype, 9, &type, payload, &len, NULL) == 1 && type == PEDAL_LINK_TYPE_BUTTON,
        "unknown type swallowed the next frame");


  /* decode_state rejections. */
  pedal_state s;
  memset(&s, 0, sizeof(s));
  s.master_gain = 255;
  uint8_t sf[PEDAL_LINK_MAX_FRAME];
  pedal_link_encode_state(&s, sf);
  uint8_t *pl = sf + 3;
  pedal_state out;
  CHECK(pedal_link_decode_state(pl, PEDAL_LINK_STATE_LEN, &out) == 1, "blank state rejected");
  pl[0] = 0x10;
  CHECK(pedal_link_decode_state(pl, PEDAL_LINK_STATE_LEN, &out) == 0, "reserved flag accepted");
  pl[0] = 0;
  pl[1] = PEDAL_MODE_COUNT;
  CHECK(pedal_link_decode_state(pl, PEDAL_LINK_STATE_LEN, &out) == 0, "bad mode accepted");
  pl[1] = 0;
  pl[13] = PEDAL_LED_COUNT;
  CHECK(pedal_link_decode_state(pl, PEDAL_LINK_STATE_LEN, &out) == 0, "bad LED accepted");
  pl[13] = 0;
  CHECK(pedal_link_decode_state(pl, PEDAL_LINK_STATE_LEN - 1, &out) == 0, "short payload accepted");
}

int main(int argc, char **argv) {
  /* Liveness: the board must outlive one lost STATE reply. */
  CHECK(PEDAL_LINK_FRAME_TIMEOUT_MS >= 2u * PEDAL_LINK_HELLO_MS,
        "frame timeout %u ms does not span two hellos of %u ms", (unsigned)PEDAL_LINK_FRAME_TIMEOUT_MS,
        (unsigned)PEDAL_LINK_HELLO_MS);
  const char *dir = argc > 1 ? argv[1] : DEFAULT_FIXTURES;
  DIR *d = opendir(dir);
  if (!d) {
    fprintf(stderr, "cannot open fixture dir %s\n", dir);
    return 2;
  }
  int count = 0;
  struct dirent *e;
  while ((e = readdir(d)) != NULL) {
    size_t l = strlen(e->d_name);
    if (l > 4 && strcmp(e->d_name + l - 4, ".bin") == 0) {
      check_fixture(dir, e->d_name);
      count++;
    }
  }
  closedir(d);
  CHECK(count >= 10, "only %d fixtures found in %s", count, dir);
  for (size_t t = 0; t < sizeof(TABLES) / sizeof(*TABLES); t++) {
    CHECK(g_enum_seen[t] == TABLES[t].count,
          "%s: %d enum fixtures, C has %d values — the tables drifted",
          TABLES[t].table, g_enum_seen[t], TABLES[t].count);
  }
  check_rejections();
  if (g_failures) {
    fprintf(stderr, "%d failure(s)\n", g_failures);
    return 1;
  }
  printf("pedal_link contract: %d fixtures, ALL PASSED\n", count);
  return 0;
}
