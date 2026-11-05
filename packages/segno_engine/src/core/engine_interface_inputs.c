/*
 * engine_interface_inputs.c — the interface's input switches (#1646): Inst or
 * Line, Pad, Air and 48 V phantom power, per input, read from and written to
 * the card Segno records from.
 *
 * The capability model is le_interface_inputs (segno_engine_api.h): for each
 * input, which of the four kinds the card exposes and what each holds, and
 * for phantom power the inputs each switch powers. The UI draws only that.
 *
 * Which controls mean what comes from an adapter, chosen by what the card is.
 * An adapter is a table of control-name patterns, each naming a kind and, for
 * an enumerated control, its item names in value order; '#' in a pattern is
 * an input number and "#-#" a range of them (a shared 48 V switch). The first
 * adapter whose USB vendor matches and whose table finds a control on the
 * card (or whose check claims it) describes the card:
 *
 *  - scarlett2: the kernel's scarlett2 driver (Scarlett Gen 2, 3 and 4 Solo,
 *    2i2 and 4i4, Clarett USB and +, Vocaster One and Two), whose names are
 *    "Line In N <kind> Capture <Switch|Enum>". Its check covers what belongs
 *    to that driver: setup (MSD) mode, and capture routing that is not
 *    pass-through, where "Line In N" would not be Segno's input N.
 *  - scarlett: the Scarlett 1st Gen driver (mixer_scarlett.c), "Input N
 *    Impedance Switch" and "Input N Pad Switch", while its capture routing
 *    records input N on channel N.
 *  - generic: any other card, by keywords in the control's name, keeping only
 *    controls that map to exactly one input (le_generic_match).
 *
 * A card no adapter describes (most class-compliant interfaces: Behringer UMC,
 * MOTU M2/M4, Audient iD, whose switches are hardware only) reports
 * LE_INTERFACE_NO_CONTROLS. Adding an interface is a table entry and a fixture:
 * see "Adding an interface" in docs/plan/2026-11-04-feat-interface-input-controls-plan.md.
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

/* One entry of an adapter's table. */
typedef struct le_input_rule {
  int kind;            /* LE_INTERFACE_LEVEL, _PAD, _AIR or _PHANTOM */
  const char* pattern; /* the control's name; '#' is an input number */
  /* Enumerated: the item names in value order, NULL-terminated. NULL: a
   * switch (boolean). */
  const char* const* items;
} le_input_rule;

typedef struct le_input_adapter {
  const char* name;
  unsigned usb_vendor; /* 0: any card */
  const le_input_rule* rules; /* NULL: the generic keyword rules */
  size_t rule_count;
  /* Runs after the rules have filled *out; returns 1 when it claims the card
   * whatever the rules found (it may change out->state). */
  int (*check)(const le_mixer* m, le_interface_inputs* out);
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

/* The impedance and pad switches of sound/usb/mixer_scarlett.c. */
static const le_input_rule k_scarlett_rules[] = {
    {LE_INTERFACE_LEVEL, "Input # Impedance Switch", k_line_hiz},
    {LE_INTERFACE_PAD, "Input # Pad Switch", k_pad_10db},
};

static int le_scarlett2_check(const le_mixer* m, le_interface_inputs* out);
static int le_scarlett_check(const le_mixer* m, le_interface_inputs* out);

#define LE_FOCUSRITE_USB_VENDOR 0x1235u

static const le_input_adapter k_adapters[] = {
    {"scarlett2", LE_FOCUSRITE_USB_VENDOR, k_scarlett2_rules,
     sizeof(k_scarlett2_rules) / sizeof(k_scarlett2_rules[0]),
     le_scarlett2_check},
    {"scarlett", LE_FOCUSRITE_USB_VENDOR, k_scarlett_rules,
     sizeof(k_scarlett_rules) / sizeof(k_scarlett_rules[0]),
     le_scarlett_check},
    {"generic", 0, NULL, 0, NULL},
};

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

/* ---- scarlett2's own checks ---- */

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
 * (scarlett2_add_msd_ctl). Otherwise the controls describe Segno's inputs only
 * while capture channel N records hardware input N, directly or through the
 * unit's DSP (#1046's pass-through); a unit without capture routing controls
 * (Solo and 2i2 3rd Gen) is wired that way. */
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
  /* A card with the driver's names is this driver's, even when none of its
   * controls could be read: the generic rules, which check no routing, never
   * take it over. */
  if (out->state != LE_INTERFACE_CONTROLS) {
    return le_has_control_prefix(m, "Line In ");
  }
  char control[32];
  char hardware[32];
  char selected[48];
  for (int n = 1; n <= out->input_count; ++n) {
    snprintf(control, sizeof(control), "PCM %02d Capture Enum", n);
    if (!m->find(m->ctx, control, &type, &items)) continue;
    snprintf(hardware, sizeof(hardware), "Analogue %d", n);
    if (le_mixer_selected(m, control, selected, sizeof(selected)) &&
        (strcmp(selected, hardware) == 0 ||
         le_capture_via_dsp(m, control, hardware))) {
      continue;
    }
    le_inputs_clear(out);
    return 1;
  }
  return 1;
}

/* The 1st Gen driver routes capture too: "Input Source NN Capture Route"
 * selects what capture channel NN records. Its switches describe Segno's
 * input N only while that is "Analog N"; Segno does not set this routing. */
static int le_scarlett_check(const le_mixer* m, le_interface_inputs* out) {
  if (out->state != LE_INTERFACE_CONTROLS) return 0;
  char control[40];
  char hardware[32];
  char selected[48];
  int type = 0;
  unsigned items = 0;
  for (int n = 1; n <= out->input_count; ++n) {
    snprintf(control, sizeof(control), "Input Source %02d Capture Route", n);
    if (!m->find(m->ctx, control, &type, &items)) continue;
    snprintf(hardware, sizeof(hardware), "Analog %d", n);
    if (le_mixer_selected(m, control, selected, sizeof(selected)) &&
        strcmp(selected, hardware) == 0) {
      continue;
    }
    le_inputs_clear(out);
    return 1;
  }
  return 1;
}

/* ---- scan and write ---- */

static void le_inputs_scan_map(const le_mixer* m, le_input_map* map) {
  for (size_t a = 0; a < sizeof(k_adapters) / sizeof(k_adapters[0]); ++a) {
    const le_input_adapter* adapter = &k_adapters[a];
    if (adapter->usb_vendor != 0 && adapter->usb_vendor != m->usb_vendor) {
      continue;
    }
    le_adapter_collect(m, adapter, map);
    int claimed = map->caps.state == LE_INTERFACE_CONTROLS;
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
