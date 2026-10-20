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
  {"rec", PEDAL_MODE_REC}, {"play", PEDAL_MODE_PLAY}, {"fx", PEDAL_MODE_FX},
  {"custom", PEDAL_MODE_CUSTOM}};
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
    case PEDAL_LINK_TYPE_ENCODER_BUTTON:
      CHECK(len == 1 && payload[0] <= 1, "%s: bad encoder button payload", name);
      m = pedal_link_encode_encoder_button(payload[0], again);
      break;
    case PEDAL_LINK_TYPE_CTRL:
      CHECK(len == 4, "%s: ctrl with %u payload bytes, want 4", name, len);
      CHECK(payload[0] < PEDAL_CTRL_COUNT, "%s: ctrl jack %u out of range", name, payload[0]);
      CHECK(payload[1] < PEDAL_CTRL_CONTACT_COUNT, "%s: ctrl contact %u out of range", name,
            payload[1]);
      CHECK(payload[2] < PEDAL_CTRL_KIND_COUNT, "%s: ctrl kind %u out of range", name, payload[2]);
      /* The ring can only ever be a switch: it is the pot's supply on an
       * expression pedal, so there is no travel to read there. */
      CHECK(payload[1] == PEDAL_CTRL_TIP || payload[2] == PEDAL_CTRL_KIND_SWITCH,
            "%s: an expression pedal on the ring", name);
      /* NONE is the whole jack, said through its tip, and carries no value. */
      CHECK(payload[2] != PEDAL_CTRL_KIND_NONE || payload[3] == 0,
            "%s: an empty jack with a value", name);
      m = pedal_link_encode_ctrl(payload[0], payload[1], payload[2], payload[3], again);
      break;
    case PEDAL_LINK_TYPE_PD_STATUS:
      CHECK(len == PEDAL_LINK_PD_STATUS_LEN && payload[0] < PEDAL_PD_PROFILE_COUNT && payload[1] <= 1,
            "%s: bad pd status payload", name);
      m = pedal_link_encode_pd_status(payload[0], payload[1], (uint16_t)(payload[2] | payload[3] << 8),
                                      (uint16_t)(payload[4] | payload[5] << 8),
                                      (uint16_t)(payload[6] | payload[7] << 8), again);
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
  } else if (strcmp(name, "pd_status_stale.bin") == 0) {
    CHECK(payload[0] == PEDAL_PD_PROFILE_MATCHES && payload[1] == 0 &&
              (payload[2] | payload[3] << 8) == 20000 && (payload[4] | payload[5] << 8) == 3000 &&
              (payload[6] | payload[7] << 8) == 4700,
          "pd_status_stale: fields drifted");
  } else if (strcmp(name, "pd_status_not_read.bin") == 0) {
    CHECK(payload[0] == PEDAL_PD_PROFILE_NOT_READ && payload[2] == 0 && payload[4] == 0,
          "pd_status_not_read: fields drifted");
  } else if (strcmp(name, "button_track3_down.bin") == 0) {
    CHECK(payload[0] == PEDAL_BTN_TRACK3 && payload[1] == 1, "button_track3_down: %u %u", payload[0], payload[1]);
  } else if (strcmp(name, "button_bank_up.bin") == 0) {
    CHECK(payload[0] == PEDAL_BTN_BANK && payload[1] == 0, "button_bank_up: %u %u", payload[0], payload[1]);
  } else if (strcmp(name, "encoder_minus3.bin") == 0) {
    CHECK((int8_t)payload[0] == -3, "encoder_minus3: %d", (int8_t)payload[0]);
  } else if (strcmp(name, "encoder_plus1.bin") == 0) {
    CHECK((int8_t)payload[0] == 1, "encoder_plus1: %d", (int8_t)payload[0]);
  } else if (strcmp(name, "encoder_button_down.bin") == 0) {
    CHECK(payload[0] == 1, "encoder_button_down: %u", payload[0]);
  } else if (strcmp(name, "encoder_button_up.bin") == 0) {
    CHECK(payload[0] == 0, "encoder_button_up: %u", payload[0]);
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
  } else if (strcmp(name, "custom_mode_bankb.bin") == 0) {
    CHECK(st.mode == PEDAL_MODE_CUSTOM && st.active_bank == 1 && st.selected_track == 5 &&
              st.global_color == PEDAL_GLOBAL_AMBER && st.looper_mode == PEDAL_LOOPER_BAND &&
              st.counting_in && st.loop_length_micros == 1234567u && st.master_gain == 128 &&
              st.track_leds[1] == PEDAL_LED_RED && st.track_leds[5] == PEDAL_LED_BLUE &&
              !st.goodbye && !st.clear_fade,
          "custom_mode_bankb: fields differ");
  } else if (strcmp(name, "song_queue_track2_127.bin") == 0) {
    CHECK(st.looper_mode == PEDAL_LOOPER_SONG && st.mode == PEDAL_MODE_PLAY &&
              st.queued_button == PEDAL_BTN_TRACK2 + 1 && st.queued_progress == 127 &&
              st.track_leds[1] == PEDAL_LED_GREEN,
          "song_queue_track2_127: fields differ");
  } else if (strcmp(name, "song_queue_track4_254.bin") == 0) {
    CHECK(st.queued_button == PEDAL_BTN_TRACK4 + 1 && st.queued_progress == 254 &&
              st.active_bank == 1,
          "song_queue_track4_254: fields differ");
  } else if (strcmp(name, "song_queue_none.bin") == 0) {
    CHECK(st.looper_mode == PEDAL_LOOPER_SONG && st.queued_button == 0 &&
              st.queued_progress == 0,
          "song_queue_none: fields differ");
  } else if (strcmp(name, "dimmed.bin") == 0) {
    CHECK(st.dimmed == 1 && st.global_color == PEDAL_GLOBAL_GREEN && st.active_button_mask == 1 &&
              !st.counting_in && !st.goodbye,
          "dimmed: fields differ");
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
  pl[0] = 0x20;
  CHECK(pedal_link_decode_state(pl, PEDAL_LINK_STATE_LEN, &out) == 0, "reserved flag accepted");
  pl[0] = 0;
  pl[1] = PEDAL_MODE_CUSTOM;
  CHECK(pedal_link_decode_state(pl, PEDAL_LINK_STATE_LEN, &out) == 1 &&
            out.mode == PEDAL_MODE_CUSTOM,
        "custom mode rejected");
  pl[1] = PEDAL_MODE_COUNT;
  CHECK(pedal_link_decode_state(pl, PEDAL_LINK_STATE_LEN, &out) == 0, "bad mode accepted");
  pl[1] = 0;
  pl[13] = PEDAL_LED_COUNT;
  CHECK(pedal_link_decode_state(pl, PEDAL_LINK_STATE_LEN, &out) == 0, "bad LED accepted");
  pl[13] = 0;
  CHECK(pedal_link_decode_state(pl, PEDAL_LINK_STATE_LEN - 1, &out) == 0, "short payload accepted");
}

/* RING_BRIDGE is the Pi tool's, not the app's, so no Dart fixture covers it:
 * pin its bytes here. */
static void check_ring_bridge(void) {
  uint8_t frame[PEDAL_LINK_MAX_FRAME];
  const size_t n = pedal_link_encode_ring_bridge(frame);
  const uint8_t want[6] = {0xA5, 0x12, 0x02, 'R', 'B', 0x12 ^ 0x02 ^ 'R' ^ 'B'};
  CHECK(n == 6 && memcmp(frame, want, 6) == 0, "ring bridge frame drifted");
  uint8_t type, len, payload[PEDAL_LINK_MAX_PAYLOAD];
  CHECK(parse_all(frame, n, &type, payload, &len, NULL) == 1 && type == PEDAL_LINK_TYPE_RING_BRIDGE &&
            len == 2 && payload[0] == 'R' && payload[1] == 'B',
        "ring bridge frame does not parse");
}

static void check_physical_state(void) {
  const uint8_t p[53] = {0,3,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,255,
    0,128,255,165,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,
    18,19,20,21,22,23,254,253,252,1,2,10,200};
  pedal_state state;
  CHECK(PEDAL_LINK_PROTOCOL_VERSION == 12 && PEDAL_LINK_STATE_LEN == 53,
        "wire reservation changed");
  CHECK(pedal_link_decode_state(p,53,&state),"literal RGB state refused");
  CHECK(state.active_button_mask == 0x201 && state.pedal_colors[0].g == 128 &&
        state.pedal_colors[1].r == 165 && state.pedal_colors[9].b == 252,
        "literal RGB/mask positions changed");
  CHECK(state.queued_button == PEDAL_BTN_BANK + 1 && state.queued_progress == 200,
        "literal queue positions changed");
  uint8_t encoded[PEDAL_LINK_MAX_FRAME];
  CHECK(pedal_link_encode_state(&state,encoded)==57 && !memcmp(encoded+3,p,53),
        "literal state encoding differs");
  /* The queue: a button past the last, progress 255 (a full pill is never
   * drawn from a queue) and progress without a button are each refused, by
   * the decoder and by the encoder. */
  const uint8_t queues[][2] = {{PEDAL_BTN_COUNT + 1, 0}, {1, 255}, {0, 1}};
  for (size_t i = 0; i < sizeof(queues) / sizeof(*queues); ++i) {
    uint8_t q[53]; memcpy(q,p,53);
    q[51] = queues[i][0]; q[52] = queues[i][1];
    pedal_state before; memset(&before,0x5a,sizeof(before)); state=before;
    CHECK(!pedal_link_decode_state(q,53,&state),"bad queue accepted");
    CHECK(!memcmp(&state,&before,sizeof(state)),"queue refusal mutated output");
    pedal_state good;
    CHECK(pedal_link_decode_state(p,53,&good),"literal state refused");
    good.queued_button = queues[i][0]; good.queued_progress = queues[i][1];
    CHECK(pedal_link_encode_state(&good,encoded)==0,"bad queue encoded");
  }
  uint8_t bad[54]; memcpy(bad,p,53); bad[53]=0;
  for (unsigned bit=2; bit<8; ++bit) {
    bad[50]=(uint8_t)(1u<<bit);
    pedal_state before; memset(&before,0x5a,sizeof(before));
    state=before;
    CHECK(!pedal_link_decode_state(bad,53,&state),"reserved mask accepted");
    CHECK(!memcmp(&state,&before,sizeof(state)),"refusal mutated output");
  }
  bad[50]=2;
  const uint8_t lengths[]={0,19,21,49,50,51,52,54};
  for (size_t i=0;i<sizeof(lengths);++i) {
    pedal_state before; memset(&before,0x5a,sizeof(before)); state=before;
    CHECK(!pedal_link_decode_state(bad,lengths[i],&state),"wrong length accepted");
    CHECK(!memcmp(&state,&before,sizeof(state)),"length refusal mutated output");
  }
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
  check_physical_state();
  check_ring_bridge();
  if (g_failures) {
    fprintf(stderr, "%d failure(s)\n", g_failures);
    return 1;
  }
  printf("pedal_link contract: %d fixtures, ALL PASSED\n", count);
  return 0;
}
