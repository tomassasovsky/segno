/*
 * engine_interface.c — the audio interface's adapters: its input switches
 * (#1646) and its own routing (#1046), read from and written to the card
 * Segno records from (and, for the routing, the card it plays to).
 *
 * Input switches: Inst or Line, Pad, Air and 48 V phantom power, per input.
 * The capability model is le_interface_inputs (segno_engine_api.h): for each
 * input, which of the four kinds the card exposes and what each holds, and
 * for phantom power the inputs each switch powers. The UI draws only that.
 *
 * Routing: Segno owns every input and output, so the interface has to be a
 * set of plain converters: hardware output k plays Segno's output k, Segno's
 * input k records hardware input k, and nothing mixes inside it. A Focusrite
 * keeps its routing matrix in its own memory, so a reset unit, another unit or
 * another model arrives with whatever it last stored (the console's 4i4 fed
 * its headphones from PCM 1-2 and played Segno's outputs 3-4 nowhere).
 *
 * Which controls mean what comes from an adapter, chosen by what the card is.
 * An adapter is a table of control-name patterns for the switches, each
 * naming a kind and, for an enumerated control, its item names in value
 * order ('#' in a pattern is an input number and "#-#" a range of them, a
 * shared 48 V switch), and a routing table (le_routing_table) naming the
 * controls that set what each hardware output plays and what each capture
 * channel records. The first adapter whose USB vendor matches and whose
 * tables find a control on the card (or whose check claims it) describes the
 * card; the switches and the routing are chosen the same way, each from the
 * adapters that have that table:
 *
 *  - scarlett2: the kernel's scarlett2 driver (Scarlett Gen 2, 3 and 4 Solo,
 *    2i2 and 4i4, Clarett USB and +, Vocaster One and Two), whose names are
 *    "Line In N <kind> Capture <Switch|Enum>". Its check covers setup (MSD)
 *    mode. Segno sets its routing to pass-through at every device open. (The
 *    big Gen 4 units use the FCP driver, whose routing has no such controls:
 *    left alone.)
 *  - scarlett: the Scarlett 1st Gen driver (mixer_scarlett.c), "Input N
 *    Impedance Switch" and "Input N Pad Switch". Its routing is read, never
 *    set.
 *  - generic: any other card, by keywords in the control's name, keeping only
 *    controls that map to exactly one input (le_generic_match). It has no
 *    routing.
 *
 * An adapter's switches describe Segno's input N only while its capture
 * routing records hardware input N on channel N (le_capture_pass_through);
 * otherwise "Line In N" would not be Segno's input N, and the card reports no
 * controls.
 *
 * A card no adapter describes (most class-compliant interfaces: Behringer UMC,
 * MOTU M2/M4, Audient iD, whose switches are hardware only) reports
 * LE_INTERFACE_NO_CONTROLS and keeps its routing. Adding an interface is a
 * table entry and a fixture: see "Adding an interface" in
 * docs/plan/2026-11-04-feat-interface-input-controls-plan.md.
 *
 * Every write is read back. Nothing is stored: the interface keeps its own
 * settings, and its front-panel buttons change the same controls.
 */

#include <ctype.h>
#include <stdio.h>
#include <string.h>

#include "engine_internal.h"
#include "engine_platform.h"

#define LE_INPUT_KINDS 4 /* LE_INTERFACE_LEVEL .. LE_INTERFACE_PHANTOM */
#define LE_INPUT_MAX_FOUND 64
#define LE_INPUT_NAME_MAX 64
#define LE_ROUTING_MAX_PORTS 64

/* One entry of an adapter's table. */
typedef struct le_input_rule {
  int kind;            /* LE_INTERFACE_LEVEL, _PAD, _AIR or _PHANTOM */
  const char* pattern; /* the control's name; '#' is an input number */
  /* Enumerated: the item names in value order, NULL-terminated. NULL: a
   * switch (boolean). */
  const char* const* items;
} le_input_rule;

/* One family's routing controls. Names and items are printf formats whose
 * one conversion is a port or channel number; NULL where the family has
 * none. */
typedef struct le_routing_table {
  /* 1: Segno sets this routing to pass-through at device open
   * (le_own_interface_routing). 0: it is only read. */
  int owned;
  /* The hardware outputs by port type, in the order the host's playback
   * streams are laid out, NULL-terminated. The k-th of them plays
   * stream_item k, or off_item when there is no stream k. */
  const char* const* outputs;
  /* Direct monitoring, which mixes the inputs into the outputs in hardware:
   * a switch, turned off, and an enumeration, set to off_item. */
  const char* monitor_switch;
  const char* monitor_enum;
  /* The enumeration naming what capture channel k records. */
  const char* capture;
  /* The prefixes of the items that are hardware inputs, NULL-terminated, in
   * the order the capture channels record them. */
  const char* const* hardware;
  /* Hardware input n as an item: what capture channel n records when it is
   * pass-through. */
  const char* input_item;
  /* Playback stream k as an item, and the item for nothing. */
  const char* stream_item;
  const char* off_item;
  /* Whether an item is one of the host's own playback streams: a capture
   * channel that records one is the interface's loopback (#1541). */
  int (*is_loopback)(const char* item);
  /* The unit's input DSP: DSP n as an item, and the enumeration naming the
   * hardware input DSP n processes. */
  const char* dsp_item;
  const char* dsp_input;
} le_routing_table;

typedef struct le_input_adapter {
  const char* name;
  unsigned usb_vendor; /* 0: any card */
  const le_input_rule* rules; /* NULL: the generic keyword rules */
  size_t rule_count;
  /* Runs after the rules have filled *out and the capture routing has been
   * checked; returns 1 when it claims the card whatever the rules found (it
   * may change out->state). */
  int (*check)(const le_mixer* m, le_interface_inputs* out);
  const le_routing_table* routing; /* NULL: none */
} le_input_adapter;

/* A control an adapter matched. */
typedef struct le_input_found {
  int kind;
  int first; /* 1-based inputs; first == last except for a shared 48 V */
  int last;
  int type;  /* LE_MIXER_BOOLEAN or LE_MIXER_ENUMERATED */
  /* Enumerated, from a table: item names in value order. NULL: the value is
   * the control's own (0/1 for a switch, the item index for a generic
   * two-item enumeration). */
  const char* const* items;
  char name[LE_INPUT_NAME_MAX];
} le_input_found;

/* What a scan found, and where each switch's control is. */
typedef struct le_input_map {
  le_interface_inputs caps;
  le_input_found found[LE_INPUT_MAX_FOUND];
  int count;
  int at[LE_INPUT_KINDS][LE_INTERFACE_MAX_INPUTS]; /* found index, or -1 */
  int phantom_at[LE_INTERFACE_MAX_PHANTOM];        /* found index */
} le_input_map;

/* ---- the tables ---- */

static const char* const k_line_inst[] = {"Line", "Inst", NULL};
static const char* const k_air_presence[] = {"Off", "Presence",
                                             "Presence + Drive", NULL};
static const char* const k_line_hiz[] = {"Line", "Hi-Z", NULL};
static const char* const k_pad_10db[] = {"0dB", "-10dB", NULL};

/* scarlett2_add_line_in_ctls in the kernel's sound/usb/mixer_scarlett2.c. */
static const le_input_rule k_scarlett2_rules[] = {
    {LE_INTERFACE_LEVEL, "Line In # Level Capture Enum", k_line_inst},
    {LE_INTERFACE_PAD, "Line In # Pad Capture Switch", NULL},
    {LE_INTERFACE_AIR, "Line In # Air Capture Switch", NULL},
    {LE_INTERFACE_AIR, "Line In # Air Capture Enum", k_air_presence},
    {LE_INTERFACE_PHANTOM, "Line In # Phantom Power Capture Switch", NULL},
    {LE_INTERFACE_PHANTOM, "Line In #-# Phantom Power Capture Switch", NULL},
};

/* The scarlett2 routing, from the names sound/usb/mixer_scarlett2.c creates
 * (the ones alsa-scarlett-gui reads too):
 *  - The hardware outputs are "Analogue Output NN Playback Enum", then
 *    "S/PDIF Output N Playback Enum", then "ADAT Output N Playback Enum", the
 *    order in which the driver and Focusrite's own defaults lay out the host's
 *    playback streams; each item "PCM k" is stream k.
 *  - "Direct Monitor Playback Switch" (Solo) and "Direct Monitor Playback
 *    Enum" (2i2, item "Off").
 *  - Capture channel k is "PCM NN Capture Enum" (NN = k), whose hardware
 *    items are "Analogue n", "S/PDIF n" and "ADAT n". A unit with input
 *    processing (Gen 4, Vocaster) may record one through its DSP: item
 *    "DSP n", whose "DSP Input n Capture Enum" selects the hardware input.
 * The mixer ("Mixer Input NN Capture Enum" and its gains) is not in the
 * table: once no output and no input selects a "Mix" item, it reaches
 * nothing. */
static const char* const k_scarlett2_outputs[] = {
    "Analogue Output %02d Playback Enum",
    "S/PDIF Output %d Playback Enum",
    "ADAT Output %d Playback Enum",
    NULL,
};
static const char* const k_scarlett2_hardware[] = {"Analogue ", "S/PDIF ",
                                                   "ADAT ", NULL};
static const le_routing_table k_scarlett2_routing = {
    .owned = 1,
    .outputs = k_scarlett2_outputs,
    .monitor_switch = "Direct Monitor Playback Switch",
    .monitor_enum = "Direct Monitor Playback Enum",
    .capture = "PCM %02d Capture Enum",
    .hardware = k_scarlett2_hardware,
    .input_item = "Analogue %d",
    .stream_item = "PCM %d",
    .off_item = "Off",
    .is_loopback = le_capture_source_is_loopback,
    .dsp_item = "DSP %d",
    .dsp_input = "DSP Input %d Capture Enum",
};

/* The impedance and pad switches of sound/usb/mixer_scarlett.c. */
static const le_input_rule k_scarlett_rules[] = {
    {LE_INTERFACE_LEVEL, "Input # Impedance Switch", k_line_hiz},
    {LE_INTERFACE_PAD, "Input # Pad Switch", k_pad_10db},
};

/* The 1st Gen driver routes capture too: "Input Source NN Capture Route"
 * selects what capture channel NN records, "Analog N" being input N. Segno
 * does not set this routing. */
static const le_routing_table k_scarlett_routing = {
    .owned = 0,
    .capture = "Input Source %02d Capture Route",
    .input_item = "Analog %d",
};

static int le_scarlett2_check(const le_mixer* m, le_interface_inputs* out);

#define LE_FOCUSRITE_USB_VENDOR 0x1235u

static const le_input_adapter k_adapters[] = {
    {"scarlett2", LE_FOCUSRITE_USB_VENDOR, k_scarlett2_rules,
     sizeof(k_scarlett2_rules) / sizeof(k_scarlett2_rules[0]),
     le_scarlett2_check, &k_scarlett2_routing},
    {"scarlett", LE_FOCUSRITE_USB_VENDOR, k_scarlett_rules,
     sizeof(k_scarlett_rules) / sizeof(k_scarlett_rules[0]), NULL,
     &k_scarlett_routing},
    {"generic", 0, NULL, 0, NULL, NULL},
};

#define LE_ADAPTER_COUNT (sizeof(k_adapters) / sizeof(k_adapters[0]))

/* Whether the adapter can describe a card with this USB vendor. */
static int le_adapter_vendor_matches(const le_input_adapter* a,
                                     const le_mixer* m) {
  return a->usb_vendor == 0 || a->usb_vendor == m->usb_vendor;
}

/* ---- matching ---- */

/* Matches `name` against `pattern` exactly, '#' reading a decimal number.
 * Returns how many numbers it read into nums[0..1], or -1. */
static int le_pattern_match(const char* pattern, const char* name,
                            int nums[2]) {
  int n = 0;
  while (*pattern != '\0') {
    if (*pattern == '#') {
      if (!isdigit((unsigned char)*name) || n == 2) return -1;
      int v = 0;
      while (isdigit((unsigned char)*name)) {
        if (v > 999) return -1;
        v = v * 10 + (*name++ - '0');
      }
      nums[n++] = v;
      ++pattern;
    } else if (*pattern++ != *name++) {
      return -1;
    }
  }
  return *name == '\0' ? n : -1;
}

static int le_ieq(const char* a, const char* b) {
  while (*a != '\0' && *b != '\0') {
    if (tolower((unsigned char)*a++) != tolower((unsigned char)*b++)) return 0;
  }
  return *a == *b;
}

/* Whether lower-case `s` holds `word` with no letter or digit either side. */
static int le_has_word(const char* s, const char* word) {
  const size_t len = strlen(word);
  for (const char* p = strstr(s, word); p != NULL; p = strstr(p + 1, word)) {
    const int before = p > s && isalnum((unsigned char)p[-1]);
    const int after = isalnum((unsigned char)p[len]);
    if (!before && !after) return 1;
  }
  return 0;
}

/* Whether an enumeration item reads as the kind's off (on = 0) or on (1). */
static int le_generic_item_is(int kind, const char* item, int on) {
  if (le_ieq(item, on ? "On" : "Off")) return 1;
  if (kind == LE_INTERFACE_LEVEL) {
    return on ? le_ieq(item, "Inst") || le_ieq(item, "Instrument") ||
                    le_ieq(item, "Hi-Z") || le_ieq(item, "HiZ")
              : le_ieq(item, "Line");
  }
  if (kind == LE_INTERFACE_PAD) {
    if (!on) return le_ieq(item, "0dB");
    const size_t len = strlen(item);
    return item[0] == '-' && len > 3 && le_ieq(item + len - 2, "dB");
  }
  return 0;
}

/* The generic rules: a mixer control whose name has exactly one kind keyword
 * (phantom or 48v: phantom power; pad; hi-z, hiz, inst, instrument or
 * impedance: the level; air) and, once "48V" is taken out, exactly one input
 * number (or a range "a-b", for phantom power only), and that is a switch or
 * a two-item enumeration whose items read as off and on. Playback controls
 * are not inputs. Fills *f and returns 1 when it is one. */
static int le_generic_match(const le_mixer* m, const char* name,
                            le_input_found* f) {
  char s[LE_INPUT_NAME_MAX];
  size_t i = 0;
  for (; name[i] != '\0' && i + 1 < sizeof(s); ++i) {
    s[i] = (char)tolower((unsigned char)name[i]);
  }
  s[i] = '\0';
  if (strstr(s, "playback") != NULL) return 0;
  int phantom = strstr(s, "phantom") != NULL;
  for (char* v = strstr(s, "48v"); v != NULL; v = strstr(v, "48v")) {
    phantom = 1;
    memset(v, ' ', 3);
  }
  int kinds = 0;
  int kind = -1;
  if (phantom) kinds++, kind = LE_INTERFACE_PHANTOM;
  if (le_has_word(s, "pad")) kinds++, kind = LE_INTERFACE_PAD;
  if (le_has_word(s, "air")) kinds++, kind = LE_INTERFACE_AIR;
  if (strstr(s, "hi-z") != NULL || le_has_word(s, "hiz") ||
      le_has_word(s, "inst") || le_has_word(s, "instrument") ||
      le_has_word(s, "impedance")) {
    kinds++, kind = LE_INTERFACE_LEVEL;
  }
  if (kinds != 1) return 0;

  /* The input numbers: one number, or one range. */
  int numbers = 0;
  int first = 0;
  int last = 0;
  for (const char* p = s; *p != '\0';) {
    if (!isdigit((unsigned char)*p)) {
      ++p;
      continue;
    }
    int a = 0;
    while (isdigit((unsigned char)*p) && a <= 999) a = a * 10 + (*p++ - '0');
    int b = a;
    if (p[0] == '-' && isdigit((unsigned char)p[1])) {
      ++p;
      b = 0;
      while (isdigit((unsigned char)*p) && b <= 999) b = b * 10 + (*p++ - '0');
    }
    ++numbers;
    first = a;
    last = b;
  }
  if (numbers != 1 || (first != last && kind != LE_INTERFACE_PHANTOM)) {
    return 0;
  }

  int type = 0;
  unsigned items = 0;
  if (!m->find(m->ctx, name, &type, &items)) return 0;
  if (type == LE_MIXER_ENUMERATED) {
    const char* item = items == 2 ? m->item_name(m->ctx, name, 0) : NULL;
    if (item == NULL || !le_generic_item_is(kind, item, 0)) return 0;
    item = m->item_name(m->ctx, name, 1);
    if (item == NULL || !le_generic_item_is(kind, item, 1)) return 0;
  } else if (type != LE_MIXER_BOOLEAN) {
    return 0;
  }
  f->kind = kind;
  f->first = first;
  f->last = last;
  f->type = type;
  f->items = NULL;
  return 1;
}

/* The index of the item named `item` in enumerated control `name`, or -1. */
static int le_item_index(const le_mixer* m, const char* name, unsigned items,
                         const char* item) {
  for (unsigned i = 0; i < items; ++i) {
    const char* have = m->item_name(m->ctx, name, i);
    if (have != NULL && strcmp(have, item) == 0) return (int)i;
  }
  return -1;
}

/* Whether table rule `r` describes control `name`; fills *f. */
static int le_rule_match(const le_mixer* m, const le_input_rule* r,
                         const char* name, le_input_found* f) {
  int nums[2] = {0, 0};
  const int n = le_pattern_match(r->pattern, name, nums);
  if (n < 1) return 0;
  int type = 0;
  unsigned items = 0;
  if (!m->find(m->ctx, name, &type, &items)) return 0;
  if (r->items == NULL) {
    if (type != LE_MIXER_BOOLEAN) return 0;
  } else {
    if (type != LE_MIXER_ENUMERATED) return 0;
    for (const char* const* it = r->items; *it != NULL; ++it) {
      if (le_item_index(m, name, items, *it) < 0) return 0;
    }
  }
  f->kind = r->kind;
  f->first = nums[0];
  f->last = n == 2 ? nums[1] : nums[0];
  f->type = type;
  f->items = r->items;
  return 1;
}

/* The switch's value as le_interface_input reports it, or -1 when it cannot
 * be read or holds an item the table does not know. */
static int le_found_value(const le_mixer* m, const le_input_found* f) {
  unsigned raw = 0;
  if (m->read(m->ctx, f->name, &raw) < 0) return -1;
  if (f->type == LE_MIXER_BOOLEAN) return raw != 0;
  if (f->items == NULL) return raw <= 1 ? (int)raw : -1;
  const char* item = m->item_name(m->ctx, f->name, raw);
  if (item == NULL) return -1;
  for (int v = 0; f->items[v] != NULL; ++v) {
    if (strcmp(f->items[v], item) == 0) return v;
  }
  return -1;
}

/* The number of values the switch takes. */
static int le_found_choices(const le_input_found* f) {
  if (f->items == NULL) return 2;
  int n = 0;
  while (f->items[n] != NULL) ++n;
  return n;
}

static void le_inputs_clear(le_interface_inputs* out) {
  memset(out, 0, sizeof(*out));
  out->state = LE_INTERFACE_NO_CONTROLS;
  for (int i = 0; i < LE_INTERFACE_MAX_INPUTS; ++i) {
    le_interface_input* in = &out->inputs[i];
    in->level = in->pad = in->air = in->phantom_group = -1;
  }
}

static void le_map_clear(le_input_map* map) {
  le_inputs_clear(&map->caps);
  map->count = 0;
  for (int k = 0; k < LE_INPUT_KINDS; ++k) {
    for (int i = 0; i < LE_INTERFACE_MAX_INPUTS; ++i) map->at[k][i] = -1;
  }
  for (int g = 0; g < LE_INTERFACE_MAX_PHANTOM; ++g) map->phantom_at[g] = -1;
}

/* Whether two found controls of one kind cover a common input. */
static int le_found_overlap(const le_input_found* a, const le_input_found* b) {
  return a->kind == b->kind && a->first <= b->last && b->first <= a->last;
}

/* Runs one adapter over the card into *map: every control it matches, then,
 * of those, the ones no other control of the same kind contends with, laid
 * out per input. */
static void le_adapter_collect(const le_mixer* m, const le_input_adapter* a,
                               le_input_map* map) {
  le_map_clear(map);
  char name[LE_INPUT_NAME_MAX];
  for (unsigned i = 0; map->count < LE_INPUT_MAX_FOUND; ++i) {
    const char* listed = m->control_name(m->ctx, i);
    if (listed == NULL) break;
    snprintf(name, sizeof(name), "%s", listed);
    le_input_found* f = &map->found[map->count];
    int matched = 0;
    if (a->rules == NULL) {
      matched = le_generic_match(m, name, f);
    } else {
      for (size_t r = 0; r < a->rule_count && !matched; ++r) {
        matched = le_rule_match(m, &a->rules[r], name, f);
      }
    }
    if (!matched || f->first < 1 || f->last < f->first ||
        f->last > LE_INTERFACE_MAX_INPUTS) {
      continue;
    }
    snprintf(f->name, sizeof(f->name), "%s", name);
    map->count++;
  }

  /* Phantom groups in input order, whatever order the card lists them. */
  int order[LE_INPUT_MAX_FOUND];
  for (int i = 0; i < map->count; ++i) order[i] = i;
  for (int i = 1; i < map->count; ++i) {
    for (int j = i; j > 0 && map->found[order[j]].first <
                                 map->found[order[j - 1]].first;
         --j) {
      const int t = order[j];
      order[j] = order[j - 1];
      order[j - 1] = t;
    }
  }

  le_interface_inputs* caps = &map->caps;
  for (int oi = 0; oi < map->count; ++oi) {
    const int i = order[oi];
    const le_input_found* f = &map->found[i];
    int contended = 0;
    for (int j = 0; j < map->count && !contended; ++j) {
      contended = j != i && le_found_overlap(f, &map->found[j]);
    }
    if (contended) continue;
    const int value = le_found_value(m, f);
    if (value < 0) continue;
    if (f->kind == LE_INTERFACE_PHANTOM) {
      if (caps->phantom_count == LE_INTERFACE_MAX_PHANTOM) continue;
      const int g = caps->phantom_count++;
      caps->phantom[g].first = f->first;
      caps->phantom[g].last = f->last;
      caps->phantom[g].on = value;
      map->phantom_at[g] = i;
      for (int in = f->first; in <= f->last; ++in) {
        caps->inputs[in - 1].phantom_group = g;
      }
    } else {
      le_interface_input* in = &caps->inputs[f->first - 1];
      if (f->kind == LE_INTERFACE_LEVEL) in->level = value;
      if (f->kind == LE_INTERFACE_PAD) in->pad = value;
      if (f->kind == LE_INTERFACE_AIR) {
        in->air = value;
        in->air_choices = le_found_choices(f);
      }
      map->at[f->kind][f->first - 1] = i;
    }
    if (f->last > caps->input_count) caps->input_count = f->last;
    caps->state = LE_INTERFACE_CONTROLS;
  }
}

/* ---- routing ---- */

int le_capture_source_is_loopback(const char* source) {
  /* "PCM <n>" is the host's own playback stream n in the scarlett2 routing,
   * so the channel returns what the engine plays (#1541). Exact, as the
   * driver writes it. */
  return source != NULL && strncmp(source, "PCM ", 4) == 0 &&
         source[4] >= '0' && source[4] <= '9';
}

/* Looks up control `format` with port `n`; fills `name` (64 bytes). */
static int le_find_port(const le_mixer* m, const char* format, int n,
                        char name[64], int* type, unsigned* items) {
  snprintf(name, 64, format, n);
  return m->find(m->ctx, name, type, items);
}

/* The item enumerated `control` selects, copied into `out`; 0 when it cannot
 * be read. */
static int le_mixer_selected(const le_mixer* m, const char* control,
                             char* out, size_t cap) {
  int type = 0;
  unsigned items = 0;
  unsigned value = 0;
  if (!m->find(m->ctx, control, &type, &items) ||
      type != LE_MIXER_ENUMERATED || m->read(m->ctx, control, &value) < 0 ||
      value >= items) {
    return 0;
  }
  const char* name = m->item_name(m->ctx, control, value);
  if (name == NULL) return 0;
  snprintf(out, cap, "%s", name);
  return 1;
}

/* Whether capture `control` records hardware source `hardware` through the
 * unit's input DSP: it selects DSP n, and DSP n's input selects
 * `hardware`. */
static int le_capture_via_dsp(const le_mixer* m, const le_routing_table* t,
                              const char* control, const char* hardware) {
  if (t->dsp_item == NULL) return 0;
  char current[48];
  if (!le_mixer_selected(m, control, current, sizeof(current))) return 0;
  int n = 0;
  if (sscanf(current, t->dsp_item, &n) != 1 || n <= 0) return 0;
  char dsp[64];
  char feeds[48];
  snprintf(dsp, sizeof(dsp), t->dsp_input, n);
  return le_mixer_selected(m, dsp, feeds, sizeof(feeds)) &&
         strcmp(feeds, hardware) == 0;
}

/* Whether capture channels 1 to `inputs` record hardware inputs 1 to
 * `inputs`, directly or through the unit's input DSP (#1046's pass-through).
 * A channel without a capture control (Solo and 2i2 3rd Gen have none) is
 * wired that way. */
static int le_capture_pass_through(const le_mixer* m,
                                   const le_routing_table* t, int inputs) {
  char control[64];
  char hardware[32];
  char selected[48];
  int type = 0;
  unsigned items = 0;
  for (int n = 1; n <= inputs; ++n) {
    if (!le_find_port(m, t->capture, n, control, &type, &items)) continue;
    snprintf(hardware, sizeof(hardware), t->input_item, n);
    if (le_mixer_selected(m, control, selected, sizeof(selected)) &&
        (strcmp(selected, hardware) == 0 ||
         le_capture_via_dsp(m, t, control, hardware))) {
      continue;
    }
    return 0;
  }
  return 1;
}

/* Whether the card has any control routing table `t` covers. */
static int le_routing_claims(const le_mixer* m, const le_routing_table* t) {
  char control[64];
  int type = 0;
  unsigned items = 0;
  if (t->capture != NULL &&
      le_find_port(m, t->capture, 1, control, &type, &items)) {
    return 1;
  }
  for (const char* const* o = t->outputs; o != NULL && *o != NULL; ++o) {
    if (le_find_port(m, *o, 1, control, &type, &items)) return 1;
  }
  return (t->monitor_switch != NULL &&
          m->find(m->ctx, t->monitor_switch, &type, &items)) ||
         (t->monitor_enum != NULL &&
          m->find(m->ctx, t->monitor_enum, &type, &items));
}

/* The card's routing table: that of the first adapter with one whose USB
 * vendor matches and whose table finds a control on the card; NULL when
 * none does. */
static const le_routing_table* le_routing_for(const le_mixer* m) {
  for (size_t a = 0; a < LE_ADAPTER_COUNT; ++a) {
    const le_input_adapter* adapter = &k_adapters[a];
    if (adapter->routing == NULL || !le_adapter_vendor_matches(adapter, m)) {
      continue;
    }
    if (le_routing_claims(m, adapter->routing)) return adapter->routing;
  }
  return NULL;
}

static void le_routing_set(const le_mixer* m, const char* control,
                           unsigned want, le_routing_report* r) {
  r->controls++;
  unsigned have = 0;
  if (m->read(m->ctx, control, &have) == 0 && have == want) return;
  r->changed++;
  if (m->write(m->ctx, control, want) == 0 &&
      m->read(m->ctx, control, &have) == 0 && have == want) {
    return;
  }
  if (r->failed++ == 0) {
    snprintf(r->first_failed, sizeof(r->first_failed), "%s", control);
  }
}

/* Sets enumerated `control` to the item named `item`, or to the table's off
 * item when it has none. A control without either is left alone. */
static void le_routing_select(const le_mixer* m, const le_routing_table* t,
                              const char* control, unsigned items,
                              const char* item, le_routing_report* r) {
  int index = le_item_index(m, control, items, item);
  if (index < 0) index = le_item_index(m, control, items, t->off_item);
  if (index >= 0) le_routing_set(m, control, (unsigned)index, r);
}

static int le_is_hardware_source(const le_routing_table* t,
                                 const char* item) {
  if (item == NULL) return 0;
  for (const char* const* p = t->hardware; *p != NULL; ++p) {
    if (strncmp(item, *p, strlen(*p)) == 0) return 1;
  }
  return 0;
}

/* Hardware output k plays playback stream k, and direct monitoring is
 * off. */
static void le_own_outputs(const le_mixer* m, const le_routing_table* t,
                           le_routing_report* r) {
  char control[64];
  char item[48];
  int type = 0;
  unsigned items = 0;
  int stream = 0;
  for (const char* const* o = t->outputs; o != NULL && *o != NULL; ++o) {
    for (int n = 1; n <= LE_ROUTING_MAX_PORTS; ++n) {
      if (!le_find_port(m, *o, n, control, &type, &items)) break;
      ++stream;
      if (type != LE_MIXER_ENUMERATED) continue;
      snprintf(item, sizeof(item), t->stream_item, stream);
      le_routing_select(m, t, control, items, item, r);
    }
  }
  if (t->monitor_switch != NULL &&
      m->find(m->ctx, t->monitor_switch, &type, &items) &&
      type == LE_MIXER_BOOLEAN) {
    le_routing_set(m, t->monitor_switch, 0, r);
  }
  if (t->monitor_enum != NULL &&
      m->find(m->ctx, t->monitor_enum, &type, &items) &&
      type == LE_MIXER_ENUMERATED) {
    le_routing_select(m, t, t->monitor_enum, items, t->off_item, r);
  }
}

/* Capture channel k records hardware input k (directly, or through the input
 * DSP); the channels past the hardware inputs return playback streams 1,
 * 2, ... when `loopback`, and are off otherwise. */
static void le_own_inputs(const le_mixer* m, const le_routing_table* t,
                          int loopback, le_routing_report* r) {
  char control[64];
  char item[48];
  char hardware_name[48];
  int type = 0;
  unsigned items = 0;
  for (int k = 1; k <= LE_ROUTING_MAX_PORTS; ++k) {
    if (!le_find_port(m, t->capture, k, control, &type, &items)) break;
    if (type != LE_MIXER_ENUMERATED) continue;
    int hardware = 0;
    int source = -1;
    for (unsigned i = 0; i < items; ++i) {
      const char* name = m->item_name(m->ctx, control, i);
      if (!le_is_hardware_source(t, name)) continue;
      if (++hardware == k) {
        source = (int)i;
        snprintf(hardware_name, sizeof(hardware_name), "%s", name);
      }
    }
    if (source >= 0) {
      if (le_capture_via_dsp(m, t, control, hardware_name)) {
        r->controls++;
      } else {
        le_routing_set(m, control, (unsigned)source, r);
      }
    } else {
      snprintf(item, sizeof(item), t->stream_item, k - hardware);
      le_routing_select(m, t, control, items, loopback ? item : t->off_item,
                        r);
    }
  }
}

void le_own_interface_routing(const le_mixer* m, int roles,
                              le_routing_report* out) {
  memset(out, 0, sizeof(*out));
  const le_routing_table* t = le_routing_for(m);
  if (t == NULL || !t->owned) return;
  if (roles & LE_ROUTING_OUTPUTS) le_own_outputs(m, t, out);
  if (roles & LE_ROUTING_INPUTS) {
    le_own_inputs(m, t, (roles & LE_ROUTING_OUTPUTS) != 0, out);
  }
}

uint32_t le_interface_loopback_mask(const le_mixer* m, int channel_count) {
  const le_routing_table* t = le_routing_for(m);
  if (t == NULL || t->is_loopback == NULL) return 0;
  char control[64];
  int type = 0;
  unsigned items = 0;
  uint32_t mask = 0;
  const int n =
      channel_count < LE_MAX_CHANNELS ? channel_count : LE_MAX_CHANNELS;
  for (int ch = 0; ch < n; ++ch) {
    unsigned value = 0;
    if (!le_find_port(m, t->capture, ch + 1, control, &type, &items) ||
        type != LE_MIXER_ENUMERATED || m->read(m->ctx, control, &value) < 0 ||
        value >= items) {
      continue;
    }
    if (t->is_loopback(m->item_name(m->ctx, control, value))) {
      mask |= 1u << ch;
    }
  }
  return mask;
}

/* ---- scarlett2's own check ---- */

static int le_has_control_prefix(const le_mixer* m, const char* prefix) {
  const size_t len = strlen(prefix);
  for (unsigned i = 0;; ++i) {
    const char* name = m->control_name(m->ctx, i);
    if (name == NULL) return 0;
    if (strncmp(name, prefix, len) == 0) return 1;
  }
}

/* A unit in setup (MSD) mode has only "MSD Mode Switch", and keeps it, off,
 * until it is power-cycled once setup mode is turned off
 * (scarlett2_add_msd_ctl). A card with the driver's names is this driver's
 * even when none of its controls could be read, or its capture is not
 * pass-through: the generic rules, which check no routing, never take it
 * over. */
static int le_scarlett2_check(const le_mixer* m, le_interface_inputs* out) {
  int type = 0;
  unsigned items = 0;
  unsigned msd = 0;
  if (m->find(m->ctx, "MSD Mode Switch", &type, &items) &&
      type == LE_MIXER_BOOLEAN && !le_has_control_prefix(m, "Line In ") &&
      m->read(m->ctx, "MSD Mode Switch", &msd) == 0) {
    le_inputs_clear(out);
    out->state =
        msd ? LE_INTERFACE_SETUP_MODE : LE_INTERFACE_SETUP_MODE_RESTART;
    return 1;
  }
  return out->state == LE_INTERFACE_CONTROLS ||
         le_has_control_prefix(m, "Line In ");
}

/* ---- scan and write ---- */

static void le_inputs_scan_map(const le_mixer* m, le_input_map* map) {
  for (size_t a = 0; a < LE_ADAPTER_COUNT; ++a) {
    const le_input_adapter* adapter = &k_adapters[a];
    if (!le_adapter_vendor_matches(adapter, m)) continue;
    le_adapter_collect(m, adapter, map);
    int claimed = map->caps.state == LE_INTERFACE_CONTROLS;
    if (claimed && adapter->routing != NULL &&
        !le_capture_pass_through(m, adapter->routing,
                                 map->caps.input_count)) {
      le_inputs_clear(&map->caps);
    }
    if (adapter->check != NULL) claimed |= adapter->check(m, &map->caps);
    if (!claimed) continue;
    if (map->caps.state != LE_INTERFACE_NO_CONTROLS) {
      snprintf(map->caps.adapter, sizeof(map->caps.adapter), "%s",
               adapter->name);
    }
    if (map->caps.state != LE_INTERFACE_CONTROLS) map->count = 0;
    return;
  }
  le_map_clear(map);
}

void le_interface_inputs_scan(const le_mixer* m, le_interface_inputs* out) {
  /* The map is a few KB: static would race two isolates, so it lives on the
   * caller's (non-audio) thread stack. */
  le_input_map map;
  le_inputs_scan_map(m, &map);
  *out = map.caps;
}

/* Writes `raw` to `name` when it differs, and reads it back. */
static int32_t le_write_checked(const le_mixer* m, const char* name,
                                unsigned raw) {
  unsigned have = 0;
  if (m->read(m->ctx, name, &have) == 0 && have == raw) return LE_OK;
  if (m->write(m->ctx, name, raw) < 0) return LE_ERR_DEVICE;
  if (m->read(m->ctx, name, &have) < 0 || have != raw) return LE_ERR_DEVICE;
  return LE_OK;
}

int32_t le_interface_inputs_write(const le_mixer* m, int32_t control,
                                  int32_t index, int32_t value) {
  le_input_map map;
  le_inputs_scan_map(m, &map);
  if (control == LE_INTERFACE_SETUP_MODE_OFF) {
    return map.caps.state == LE_INTERFACE_SETUP_MODE
               ? le_write_checked(m, "MSD Mode Switch", 0)
               : LE_ERR_INVALID;
  }
  if (map.caps.state != LE_INTERFACE_CONTROLS || control < 0 ||
      control >= LE_INPUT_KINDS || index < 0) {
    return LE_ERR_INVALID;
  }
  int at = -1;
  if (control == LE_INTERFACE_PHANTOM) {
    if (index < map.caps.phantom_count) at = map.phantom_at[index];
  } else if (index < LE_INTERFACE_MAX_INPUTS) {
    at = map.at[control][index];
  }
  if (at < 0) return LE_ERR_INVALID;
  const le_input_found* f = &map.found[at];
  if (value < 0 || value >= le_found_choices(f)) return LE_ERR_INVALID;
  unsigned raw = (unsigned)value;
  if (f->items != NULL) {
    int type = 0;
    unsigned items = 0;
    if (!m->find(m->ctx, f->name, &type, &items)) return LE_ERR_DEVICE;
    const int item = le_item_index(m, f->name, items, f->items[value]);
    if (item < 0) return LE_ERR_DEVICE;
    raw = (unsigned)item;
  }
  return le_write_checked(m, f->name, raw);
}

/* ---- FFI ---- */

int32_t le_interface_inputs_read(const char* uid, le_interface_inputs* out) {
  if (out == NULL) return LE_ERR_INVALID;
  le_inputs_clear(out);
  le_platform_interface_inputs_read(uid, out);
  return LE_OK;
}

int32_t le_interface_input_set(const char* uid, int32_t control,
                               int32_t index, int32_t value) {
  return le_platform_interface_input_set(uid, control, index, value);
}
