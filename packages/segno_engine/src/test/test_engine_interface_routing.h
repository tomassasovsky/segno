/* The interface's own routing (#1046): le_own_scarlett2_routing and
 * le_scarlett2_loopback_mask against a fake card. The 4i4 card is read from
 * an `amixer contents` dump of the console's (fixtures/alsa); the others are
 * built here. Included by test_engine_core.c. */

#define RT_MAX_CTLS 128
#define RT_MAX_ITEMS 24

typedef struct rt_ctl {
  char name[64];
  int mixer; /* iface=MIXER: the only controls the rules can reach */
  int type;
  unsigned items;
  char item[RT_MAX_ITEMS][24];
  unsigned value;
} rt_ctl;

typedef struct rt_card {
  rt_ctl ctl[RT_MAX_CTLS];
  int count;
  int writes;
  const char* refuse; /* a write to this control fails */
  const char* stuck;  /* a write to this control succeeds but changes nothing */
} rt_card;

static rt_ctl* rt_lookup(rt_card* card, const char* name) {
  for (int i = 0; i < card->count; ++i) {
    if (card->ctl[i].mixer && strcmp(card->ctl[i].name, name) == 0) {
      return &card->ctl[i];
    }
  }
  return NULL;
}

static int rt_find(void* ctx, const char* name, int* type, unsigned* items) {
  const rt_ctl* c = rt_lookup((rt_card*)ctx, name);
  if (c == NULL) return 0;
  *type = c->type;
  *items = c->items;
  return 1;
}

static const char* rt_item_name(void* ctx, const char* name, unsigned item) {
  const rt_ctl* c = rt_lookup((rt_card*)ctx, name);
  return c != NULL && item < c->items ? c->item[item] : NULL;
}

static int rt_read(void* ctx, const char* name, unsigned* value) {
  const rt_ctl* c = rt_lookup((rt_card*)ctx, name);
  if (c == NULL) return -1;
  *value = c->value;
  return 0;
}

static int rt_write(void* ctx, const char* name, unsigned value) {
  rt_card* card = (rt_card*)ctx;
  rt_ctl* c = rt_lookup(card, name);
  if (c == NULL) return -1;
  card->writes++;
  if (card->refuse != NULL && strcmp(card->refuse, name) == 0) return -1;
  if (card->stuck != NULL && strcmp(card->stuck, name) == 0) return 0;
  if (c->type == LE_MIXER_ENUMERATED && value >= c->items) return -1;
  c->value = value;
  return 0;
}

static le_mixer rt_mixer(rt_card* card) {
  le_mixer m = {card, rt_find, rt_item_name, rt_read, rt_write};
  return m;
}

/* Reads an `amixer -c N contents` dump: each control's iface, name, type,
 * items and first value. */
static void rt_load(rt_card* card, const char* path) {
  memset(card, 0, sizeof(*card));
  FILE* f = fopen(path, "r");
  CHECK(f != NULL);
  if (f == NULL) return;
  char line[512];
  rt_ctl* c = NULL;
  while (fgets(line, sizeof(line), f) != NULL) {
    const char* name = strstr(line, "name='");
    if (strncmp(line, "numid=", 6) == 0 && name != NULL &&
        card->count < RT_MAX_CTLS) {
      c = &card->ctl[card->count++];
      c->mixer = strstr(line, "iface=MIXER") != NULL;
      name += 6;
      const char* end = strrchr(name, '\'');
      const size_t len = end != NULL ? (size_t)(end - name) : 0;
      snprintf(c->name, sizeof(c->name), "%.*s", (int)len, name);
    } else if (c == NULL) {
      continue;
    } else if (strstr(line, "; type=ENUMERATED") != NULL) {
      c->type = LE_MIXER_ENUMERATED;
    } else if (strstr(line, "; type=BOOLEAN") != NULL) {
      c->type = LE_MIXER_BOOLEAN;
    } else if (strstr(line, "; Item #") != NULL && c->items < RT_MAX_ITEMS) {
      const char* item = strchr(line, '\'');
      const char* end = strrchr(line, '\'');
      if (item != NULL && end > item) {
        snprintf(c->item[c->items++], sizeof(c->item[0]), "%.*s",
                 (int)(end - item - 1), item + 1);
      }
    } else if (strncmp(line, "  : values=", 11) == 0) {
      const char* v = line + 11;
      c->value = strncmp(v, "on", 2) == 0 ? 1u : (unsigned)strtoul(v, NULL, 10);
    }
  }
  fclose(f);
}

/* Adds an enumerated mixer control whose items are `items`, '|'-separated. */
static void rt_add_enum(rt_card* card, const char* name, const char* items,
                        unsigned value) {
  rt_ctl* c = &card->ctl[card->count++];
  memset(c, 0, sizeof(*c));
  snprintf(c->name, sizeof(c->name), "%s", name);
  c->mixer = 1;
  c->type = LE_MIXER_ENUMERATED;
  c->value = value;
  const char* p = items;
  while (*p != '\0' && c->items < RT_MAX_ITEMS) {
    const char* bar = strchr(p, '|');
    const size_t len = bar != NULL ? (size_t)(bar - p) : strlen(p);
    snprintf(c->item[c->items++], sizeof(c->item[0]), "%.*s", (int)len, p);
    p += len + (bar != NULL ? 1 : 0);
  }
}

static unsigned rt_value(rt_card* card, const char* name) {
  const rt_ctl* c = rt_lookup(card, name);
  CHECK(c != NULL);
  return c != NULL ? c->value : 9999u;
}

static const char* rt_selected(rt_card* card, const char* name) {
  const rt_ctl* c = rt_lookup(card, name);
  CHECK(c != NULL && c->value < c->items);
  return c != NULL && c->value < c->items ? c->item[c->value] : "";
}

static void rt_set(rt_card* card, const char* name, const char* item) {
  rt_ctl* c = rt_lookup(card, name);
  CHECK(c != NULL);
  if (c == NULL) return;
  for (unsigned i = 0; i < c->items; ++i) {
    if (strcmp(c->item[i], item) == 0) c->value = i;
  }
  CHECK(strcmp(c->item[c->value], item) == 0);
}

#define RT_4I4 "src/test/fixtures/alsa/scarlett_4i4_gen3.txt"

/* The console's 4i4 as dumped: already pass-through, so nothing is written,
 * and capture 5-6 return PCM 1-2 (the loopback #1541 times on). */
static void test_routing_4i4_pass_through_writes_nothing(void) {
  printf("test_routing_4i4_pass_through_writes_nothing\n");
  static rt_card card;
  rt_load(&card, RT_4I4);
  CHECK(card.count == 90);
  const le_mixer m = rt_mixer(&card);
  le_routing_report r;
  le_own_scarlett2_routing(&m, &r);
  CHECK(r.controls == 10); /* 4 analogue outputs, 6 capture channels */
  CHECK(r.changed == 0);
  CHECK(r.failed == 0);
  CHECK(r.first_failed[0] == '\0');
  CHECK(card.writes == 0);
  CHECK(le_scarlett2_loopback_mask(&m, 6) == 0x30u);
  CHECK(le_scarlett2_loopback_mask(&m, 4) == 0u);
}

/* The bench finding: outputs fed from the mixer (headphones = PCM 1-2 again),
 * Segno's outputs 3-4 nowhere, and stray capture sources. One open restores
 * pass-through; the mixer itself is left as it was. */
static void test_routing_4i4_from_stored_mixes(void) {
  printf("test_routing_4i4_from_stored_mixes\n");
  static rt_card card;
  rt_load(&card, RT_4I4);
  rt_set(&card, "Analogue Output 01 Playback Enum", "Mix A");
  rt_set(&card, "Analogue Output 02 Playback Enum", "Mix B");
  rt_set(&card, "Analogue Output 03 Playback Enum", "Mix C");
  rt_set(&card, "Analogue Output 04 Playback Enum", "Mix D");
  rt_set(&card, "PCM 02 Capture Enum", "Analogue 1");
  rt_set(&card, "PCM 03 Capture Enum", "Mix E");
  rt_set(&card, "PCM 05 Capture Enum", "Off");
  rt_set(&card, "PCM 06 Capture Enum", "Mix F");
  const unsigned mixer_in_1 = rt_value(&card, "Mixer Input 01 Capture Enum");
  const le_mixer m = rt_mixer(&card);
  CHECK(le_scarlett2_loopback_mask(&m, 6) == 0u);

  le_routing_report r;
  le_own_scarlett2_routing(&m, &r);
  CHECK(r.controls == 10);
  CHECK(r.changed == 8);
  CHECK(r.failed == 0);
  CHECK(card.writes == 8);
  CHECK(strcmp(rt_selected(&card, "Analogue Output 01 Playback Enum"),
               "PCM 1") == 0);
  CHECK(strcmp(rt_selected(&card, "Analogue Output 02 Playback Enum"),
               "PCM 2") == 0);
  CHECK(strcmp(rt_selected(&card, "Analogue Output 03 Playback Enum"),
               "PCM 3") == 0);
  CHECK(strcmp(rt_selected(&card, "Analogue Output 04 Playback Enum"),
               "PCM 4") == 0);
  CHECK(strcmp(rt_selected(&card, "PCM 01 Capture Enum"), "Analogue 1") == 0);
  CHECK(strcmp(rt_selected(&card, "PCM 02 Capture Enum"), "Analogue 2") == 0);
  CHECK(strcmp(rt_selected(&card, "PCM 03 Capture Enum"), "Analogue 3") == 0);
  CHECK(strcmp(rt_selected(&card, "PCM 04 Capture Enum"), "Analogue 4") == 0);
  CHECK(strcmp(rt_selected(&card, "PCM 05 Capture Enum"), "PCM 1") == 0);
  CHECK(strcmp(rt_selected(&card, "PCM 06 Capture Enum"), "PCM 2") == 0);
  CHECK(rt_value(&card, "Mixer Input 01 Capture Enum") == mixer_in_1);
  CHECK(le_scarlett2_loopback_mask(&m, 6) == 0x30u);

  /* The next open finds it owned and writes nothing. */
  le_own_scarlett2_routing(&m, &r);
  CHECK(r.changed == 0);
  CHECK(card.writes == 8);
}

/* A write the card refuses, and one it accepts but does not keep (read back),
 * are both reported; the rest is still set. */
static void test_routing_reports_what_it_could_not_set(void) {
  printf("test_routing_reports_what_it_could_not_set\n");
  static rt_card card;
  rt_load(&card, RT_4I4);
  rt_set(&card, "Analogue Output 03 Playback Enum", "PCM 1");
  rt_set(&card, "Analogue Output 04 Playback Enum", "PCM 2");
  rt_set(&card, "PCM 05 Capture Enum", "Off");
  card.refuse = "Analogue Output 03 Playback Enum";
  card.stuck = "PCM 05 Capture Enum";
  const le_mixer m = rt_mixer(&card);
  le_routing_report r;
  le_own_scarlett2_routing(&m, &r);
  CHECK(r.controls == 10);
  CHECK(r.changed == 3);
  CHECK(r.failed == 2);
  CHECK(strcmp(r.first_failed, "Analogue Output 03 Playback Enum") == 0);
  CHECK(strcmp(rt_selected(&card, "Analogue Output 04 Playback Enum"),
               "PCM 4") == 0);
}

/* A card without scarlett2 routing controls (a class-compliant interface) is
 * left alone and excludes nothing. */
static void test_routing_leaves_other_cards_alone(void) {
  printf("test_routing_leaves_other_cards_alone\n");
  static rt_card card;
  memset(&card, 0, sizeof(card));
  rt_add_enum(&card, "Line In 1 Level Capture Enum", "Line|Inst", 1);
  const le_mixer m = rt_mixer(&card);
  le_routing_report r;
  le_own_scarlett2_routing(&m, &r);
  CHECK(r.controls == 0);
  CHECK(r.changed == 0);
  CHECK(card.writes == 0);
  CHECK(rt_value(&card, "Line In 1 Level Capture Enum") == 1u);
  CHECK(le_scarlett2_loopback_mask(&m, 2) == 0u);
}

/* The driver's order across port types: analogue, then S/PDIF outputs take
 * the next playback streams, an output past the last stream is Off, capture
 * takes the analogue then the S/PDIF inputs, and direct monitoring (Solo's
 * switch, 2i2's enum) goes off. */
static void test_routing_spdif_order_and_direct_monitor(void) {
  printf("test_routing_spdif_order_and_direct_monitor\n");
  static rt_card card;
  memset(&card, 0, sizeof(card));
  const char* items =
      "Off|Analogue 1|Analogue 2|S/PDIF 1|S/PDIF 2|Mix A|Mix B|PCM 1|PCM 2|"
      "PCM 3";
  rt_add_enum(&card, "Analogue Output 01 Playback Enum", items, 5);
  rt_add_enum(&card, "Analogue Output 02 Playback Enum", items, 6);
  rt_add_enum(&card, "S/PDIF Output 1 Playback Enum", items, 7);
  rt_add_enum(&card, "S/PDIF Output 2 Playback Enum", items, 8);
  for (int k = 1; k <= 6; ++k) {
    char name[32];
    snprintf(name, sizeof(name), "PCM %02d Capture Enum", k);
    rt_add_enum(&card, name, items, 0);
  }
  rt_add_enum(&card, "Direct Monitor Playback Enum", "Off|Mono|Stereo", 2);
  rt_ctl* sw = &card.ctl[card.count++];
  snprintf(sw->name, sizeof(sw->name), "Direct Monitor Playback Switch");
  sw->mixer = 1;
  sw->type = LE_MIXER_BOOLEAN;
  sw->value = 1;

  const le_mixer m = rt_mixer(&card);
  le_routing_report r;
  le_own_scarlett2_routing(&m, &r);
  CHECK(r.controls == 12);
  CHECK(r.changed == 12);
  CHECK(r.failed == 0);
  CHECK(strcmp(rt_selected(&card, "Analogue Output 01 Playback Enum"),
               "PCM 1") == 0);
  CHECK(strcmp(rt_selected(&card, "Analogue Output 02 Playback Enum"),
               "PCM 2") == 0);
  CHECK(strcmp(rt_selected(&card, "S/PDIF Output 1 Playback Enum"),
               "PCM 3") == 0);
  CHECK(strcmp(rt_selected(&card, "S/PDIF Output 2 Playback Enum"), "Off") ==
        0);
  CHECK(strcmp(rt_selected(&card, "PCM 01 Capture Enum"), "Analogue 1") == 0);
  CHECK(strcmp(rt_selected(&card, "PCM 02 Capture Enum"), "Analogue 2") == 0);
  CHECK(strcmp(rt_selected(&card, "PCM 03 Capture Enum"), "S/PDIF 1") == 0);
  CHECK(strcmp(rt_selected(&card, "PCM 04 Capture Enum"), "S/PDIF 2") == 0);
  CHECK(strcmp(rt_selected(&card, "PCM 05 Capture Enum"), "PCM 1") == 0);
  CHECK(strcmp(rt_selected(&card, "PCM 06 Capture Enum"), "PCM 2") == 0);
  CHECK(strcmp(rt_selected(&card, "Direct Monitor Playback Enum"), "Off") ==
        0);
  CHECK(rt_value(&card, "Direct Monitor Playback Switch") == 0u);
  CHECK(le_scarlett2_loopback_mask(&m, 6) == 0x30u);
}
