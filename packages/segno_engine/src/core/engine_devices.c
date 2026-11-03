/*
 * engine_devices.c — device discovery, loopback detection, id resolution, and
 * backend selection (S1 split from engine.c).
 *
 * THREAD OWNERSHIP: control thread. Everything here runs on transient ma_context
 * objects (enumeration / loopback detection) or is a pure selector — none of it
 * touches a running device or the audio thread. le_find_loopback / enumerate_devices
 * / le_resolve_device_id are also called by the miniaudio backend and the per-OS
 * seams (declared in engine_private.h); le_classify_capture_device /
 * le_label_is_loopback / le_excluded_mask_from_names / le_select_backend are the
 * unit-tested pure cores (declared in engine_internal.h). Behaviour unchanged.
 */
#include <ctype.h>
#include <stdint.h>
#include <stdio.h> /* snprintf */
#include <string.h>

#include "engine_internal.h"  /* le_classify_capture_device, le_select_backend, ... */
#include "engine_miniaudio.h" /* le_miniaudio_backend */
#include "engine_platform.h"  /* le_platform_device_id_to_str */
#include "engine_private.h"   /* le_engine, enumerate_devices/le_find_loopback decls */
#include "segno_engine_api.h"
#include "miniaudio.h"

/* ---- loopback detection ---- */

static int contains_ci(const char* haystack, const char* needle) {
  if (haystack == NULL || needle == NULL) return 0;
  const size_t nlen = strlen(needle);
  if (nlen == 0) return 1;
  for (const char* h = haystack; *h != '\0'; ++h) {
    size_t i = 0;
    while (i < nlen && h[i] != '\0' &&
           tolower((unsigned char)h[i]) == tolower((unsigned char)needle[i])) {
      ++i;
    }
    if (i == nlen) return 1;
  }
  return 0;
}

le_loopback_kind le_classify_capture_device(const char* name) {
  if (name == NULL) return LE_LOOPBACK_NONE;
  if (contains_ci(name, "monitor of")) return LE_LOOPBACK_MONITOR;
  static const char* const virtual_names[] = {
      "blackhole", "soundflower", "loopback audio", "loopback",
      "vb-audio",  "vb-cable",    "cable output",   "voicemeeter",
  };
  for (size_t i = 0; i < sizeof(virtual_names) / sizeof(virtual_names[0]); ++i) {
    if (contains_ci(name, virtual_names[i])) return LE_LOOPBACK_VIRTUAL;
  }
  return LE_LOOPBACK_NONE;
}

int le_label_is_loopback(const char* label) {
  /* Case-insensitive "loop" match. This covers both the generic "Loopback"
   * label and the Focusrite convention of naming the two loopback inputs
   * "Loop 1" / "Loop 2" (verified on a Scarlett 4i4). "loop" subsumes
   * "loopback", so one substring check handles both. */
  return contains_ci(label, "loop");
}

int le_capture_source_is_loopback(const char* source) {
  /* "PCM <n>" is the host's own playback stream n in the scarlett2 routing,
   * so the channel returns what the engine plays (#1541). Exact, as the
   * driver writes it. */
  return source != NULL && strncmp(source, "PCM ", 4) == 0 &&
         source[4] >= '0' && source[4] <= '9';
}

int le_alsa_ctl_name_from_uid(const char* uid, char* out, size_t cap) {
  if (uid == NULL || out == NULL || cap == 0) return 0;
  /* The card is what follows the plugin's colon: "hw:1,0", "plughw:1,0", and
   * the appliance's own ":1,0" (engine_linux.c's enumeration). */
  const char* card = strchr(uid, ':');
  if (card == NULL) return 0;
  ++card;
  if (strncmp(card, "CARD=", 5) == 0) card += 5;
  size_t len = 0;
  while (card[len] != '\0' && card[len] != ',') ++len;
  if (len == 0) return 0;
  const int written = snprintf(out, cap, "hw:%.*s", (int)len, card);
  return written > 0 && (size_t)written < cap;
}

/* ---- the interface's own routing (#1046) ----
 *
 * Segno owns every input and output, so the interface has to be a set of plain
 * converters: hardware output k plays Segno's output k, Segno's input k records
 * hardware input k, and nothing mixes inside it. A Focusrite keeps its routing
 * matrix in its own memory, so a reset unit, another unit or another model
 * arrives with whatever it last stored (the console's 4i4 fed its headphones
 * from PCM 1-2 and played Segno's outputs 3-4 nowhere).
 *
 * The rules are per kernel driver, matched on the control names it creates
 * (sound/usb/mixer_scarlett2.c, the names alsa-scarlett-gui reads too). One
 * driver, scarlett2, covers Scarlett Gen 2 and Gen 3, the Gen 4 Solo, 2i2 and
 * 4i4, Clarett USB and Clarett+, and Vocaster. (The big Gen 4 units use the
 * FCP driver, whose routing has no such controls: left alone.)
 *
 * Outputs, on the card Segno plays to (LE_ROUTING_OUTPUTS):
 *  - The hardware outputs are "Analogue Output NN Playback Enum", then
 *    "S/PDIF Output N Playback Enum", then "ADAT Output N Playback Enum", the
 *    order in which the driver and Focusrite's own defaults lay out the host's
 *    playback streams. The k-th of them plays item "PCM k", or "Off" when
 *    there is no stream k.
 *  - "Direct Monitor Playback Switch" (Solo) and "Direct Monitor Playback
 *    Enum" (2i2, item "Off") mix the inputs into the outputs in hardware, so
 *    they are switched off.
 *
 * Inputs, on the card Segno records from (LE_ROUTING_INPUTS), so that the
 * loopback slots set here are the ones the engine's mask excludes:
 *  - Segno's input k is "PCM NN Capture Enum" (NN = k). Inputs up to the number
 *    of hardware inputs record them in the same order (the items "Analogue n",
 *    "S/PDIF n", "ADAT n"). A unit with input processing (Gen 4, Vocaster)
 *    may feed one through its DSP instead: "DSP n" whose "DSP Input n Capture
 *    Enum" selects that same hardware input is that input, processed, and is
 *    kept. An input past the hardware inputs is the interface's loopback slot.
 *    When Segno also plays to this card, it returns Segno's output
 *    k - (hardware inputs), "PCM 1" first: the engine excludes those channels
 *    from recording, monitoring and routing, and the record offset is timed
 *    on them (#1541). When Segno plays to another card, nothing of Segno's
 *    would come back there, so it is "Off".
 *
 * The mixer ("Mixer Input NN Capture Enum" and its gains) is left as it is:
 * once no output and no input selects a "Mix" item, it reaches nothing.
 *
 * Each control is written only when it differs (every scarlett2 routing write
 * sends the whole matrix over USB) and read back after. Not controllable, so
 * left to the user: output levels and the hardware monitor knob, and outputs a
 * model wires together (the 4i4's headphones play line outputs 3-4). At 88.2
 * kHz and above, units with ADAT ports open fewer channels than the controls
 * count, so their loopback slots may fall outside what is opened. */

#define LE_ROUTING_MAX_PORTS 64

static int le_mixer_find_item(const le_mixer* m, const char* control,
                              unsigned items, const char* item) {
  for (unsigned i = 0; i < items; ++i) {
    const char* name = m->item_name(m->ctx, control, i);
    if (name != NULL && strcmp(name, item) == 0) return (int)i;
  }
  return -1;
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

/* Sets enumerated `control` to the item named `item`, or to "Off" when it has
 * none. A control without either is left alone. */
static void le_routing_select(const le_mixer* m, const char* control,
                              unsigned items, const char* item,
                              le_routing_report* r) {
  int index = le_mixer_find_item(m, control, items, item);
  if (index < 0) index = le_mixer_find_item(m, control, items, "Off");
  if (index >= 0) le_routing_set(m, control, (unsigned)index, r);
}

static int le_is_hardware_source(const char* item) {
  return item != NULL && (strncmp(item, "Analogue ", 9) == 0 ||
                          strncmp(item, "S/PDIF ", 7) == 0 ||
                          strncmp(item, "ADAT ", 5) == 0);
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

/* Whether capture `control` already records hardware source `hardware`
 * through the unit's input DSP: it selects "DSP n" and "DSP Input n Capture
 * Enum" selects `hardware`. */
static int le_capture_via_dsp(const le_mixer* m, const char* control,
                              const char* hardware) {
  char current[48];
  if (!le_mixer_selected(m, control, current, sizeof(current))) return 0;
  int n = 0;
  if (sscanf(current, "DSP %d", &n) != 1 || n <= 0) return 0;
  char dsp[48];
  char feeds[48];
  snprintf(dsp, sizeof(dsp), "DSP Input %d Capture Enum", n);
  return le_mixer_selected(m, dsp, feeds, sizeof(feeds)) &&
         strcmp(feeds, hardware) == 0;
}

static void le_own_scarlett2_outputs(const le_mixer* m, le_routing_report* r) {
  char control[48];
  char item[48];
  int type = 0;
  unsigned items = 0;
  /* Hardware outputs: the k-th plays playback stream k. */
  static const char* const outputs[] = {"Analogue Output %02d Playback Enum",
                                        "S/PDIF Output %d Playback Enum",
                                        "ADAT Output %d Playback Enum"};
  int stream = 0;
  for (size_t t = 0; t < sizeof(outputs) / sizeof(outputs[0]); ++t) {
    for (int n = 1; n <= LE_ROUTING_MAX_PORTS; ++n) {
      snprintf(control, sizeof(control), outputs[t], n);
      if (!m->find(m->ctx, control, &type, &items)) break;
      ++stream;
      if (type != LE_MIXER_ENUMERATED) continue;
      snprintf(item, sizeof(item), "PCM %d", stream);
      le_routing_select(m, control, items, item, r);
    }
  }
  /* Direct monitoring mixes the inputs into the outputs. */
  if (m->find(m->ctx, "Direct Monitor Playback Switch", &type, &items) &&
      type == LE_MIXER_BOOLEAN) {
    le_routing_set(m, "Direct Monitor Playback Switch", 0, r);
  }
  if (m->find(m->ctx, "Direct Monitor Playback Enum", &type, &items) &&
      type == LE_MIXER_ENUMERATED) {
    le_routing_select(m, "Direct Monitor Playback Enum", items, "Off", r);
  }
}

static void le_own_scarlett2_inputs(const le_mixer* m, int loopback,
                                    le_routing_report* r) {
  char control[48];
  char item[48];
  char hardware_name[48];
  int type = 0;
  unsigned items = 0;
  /* Capture channels: the hardware inputs in order, then the loopback. */
  for (int k = 1; k <= LE_ROUTING_MAX_PORTS; ++k) {
    snprintf(control, sizeof(control), "PCM %02d Capture Enum", k);
    if (!m->find(m->ctx, control, &type, &items)) break;
    if (type != LE_MIXER_ENUMERATED) continue;
    int hardware = 0;
    int source = -1;
    for (unsigned i = 0; i < items; ++i) {
      const char* name = m->item_name(m->ctx, control, i);
      if (!le_is_hardware_source(name)) continue;
      if (++hardware == k) {
        source = (int)i;
        snprintf(hardware_name, sizeof(hardware_name), "%s", name);
      }
    }
    if (source >= 0) {
      if (le_capture_via_dsp(m, control, hardware_name)) {
        r->controls++;
      } else {
        le_routing_set(m, control, (unsigned)source, r);
      }
    } else {
      snprintf(item, sizeof(item), "PCM %d", k - hardware);
      le_routing_select(m, control, items, loopback ? item : "Off", r);
    }
  }
}

void le_own_scarlett2_routing(const le_mixer* m, int roles,
                              le_routing_report* out) {
  memset(out, 0, sizeof(*out));
  if (roles & LE_ROUTING_OUTPUTS) le_own_scarlett2_outputs(m, out);
  if (roles & LE_ROUTING_INPUTS) {
    le_own_scarlett2_inputs(m, (roles & LE_ROUTING_OUTPUTS) != 0, out);
  }
}

uint32_t le_scarlett2_loopback_mask(const le_mixer* m, int channel_count) {
  char control[48];
  int type = 0;
  unsigned items = 0;
  uint32_t mask = 0;
  const int n =
      channel_count < LE_MAX_CHANNELS ? channel_count : LE_MAX_CHANNELS;
  for (int ch = 0; ch < n; ++ch) {
    snprintf(control, sizeof(control), "PCM %02d Capture Enum", ch + 1);
    unsigned value = 0;
    if (!m->find(m->ctx, control, &type, &items) ||
        type != LE_MIXER_ENUMERATED || m->read(m->ctx, control, &value) < 0 ||
        value >= items) {
      continue;
    }
    if (le_capture_source_is_loopback(m->item_name(m->ctx, control, value))) {
      mask |= 1u << ch;
    }
  }
  return mask;
}

uint32_t le_excluded_mask_from_names(le_channel_name_fn get_name, void* ctx,
                                     int channel_count) {
  /* Pure bit-setting core shared by every platform's label probe: walk the
   * input channels, ask the caller's provider for each channel's name, and set
   * the bit for any name le_label_is_loopback matches. The OS-specific part is
   * only the *source* of the names (Core Audio on macOS), so
   * this stays unit-testable with a fake provider and free of any OS calls.
   * Channels beyond LE_MAX_CHANNELS (the mask's width) are ignored. */
  if (get_name == NULL) return 0;
  uint32_t mask = 0;
  const int n =
      channel_count < LE_MAX_CHANNELS ? channel_count : LE_MAX_CHANNELS;
  for (int c = 0; c < n; ++c) {
    const char* name = get_name(ctx, c);
    if (name != NULL && le_label_is_loopback(name)) {
      mask |= (1u << c);
    }
  }
  return mask;
}

void le_find_loopback(ma_context* ctx, le_loopback_info* out,
                      ma_device_id* out_id) {
  out->available = 0;
  out->kind = LE_LOOPBACK_NONE;
  out->device_name[0] = '\0';

  ma_device_info* playback = NULL;
  ma_uint32 playback_count = 0;
  ma_device_info* capture = NULL;
  ma_uint32 capture_count = 0;
  if (ma_context_get_devices(ctx, &playback, &playback_count, &capture,
                             &capture_count) != MA_SUCCESS) {
    return;
  }

  for (ma_uint32 i = 0; i < capture_count; ++i) {
    const le_loopback_kind kind = le_classify_capture_device(capture[i].name);
    if (kind != LE_LOOPBACK_NONE) {
      out->available = 1;
      out->kind = kind;
      strncpy(out->device_name, capture[i].name, sizeof(out->device_name) - 1);
      out->device_name[sizeof(out->device_name) - 1] = '\0';
      if (out_id != NULL) *out_id = capture[i].id;
      return;
    }
  }

  if (ma_context_is_loopback_supported(ctx)) {
    out->available = 1;
    out->kind = LE_LOOPBACK_BACKEND;
  }
}

/* Every transient probe context in the engine opens through here — see the
 * contract on the declaration in engine_private.h.
 *
 * The list comes from le_platform_probe_backends, NOT le_platform_backends. The
 * streaming list is an ordered PREFERENCE and miniaudio takes the first backend
 * that initialises, so handing it to a probe would change which backend the
 * probe LANDS on, not just which ones it may reach — on desktop Linux a probe
 * would open on JACK and enumerate one synthetic default device per direction
 * instead of the host's cards. The probe seam pins only where a backend must be
 * positively excluded (Linux + SEGNO_ALSA_ONLY) and otherwise hands back
 * (NULL, 0), which is byte-for-byte the ma_context_init call these sites made
 * before. */
ma_result le_probe_context_init(ma_context* ctx) {
  const ma_backend* backends = NULL;
  ma_uint32 backend_count = 0;
  le_platform_probe_backends(&backends, &backend_count);
  return ma_context_init(backends, backend_count, NULL, ctx);
}

int32_t le_detect_loopback(le_loopback_info* out) {
  if (out == NULL) return LE_ERR_INVALID;
  ma_context ctx;
  if (le_probe_context_init(&ctx) != MA_SUCCESS) {
    out->available = 0;
    out->kind = LE_LOOPBACK_NONE;
    out->device_name[0] = '\0';
    return LE_ERR_INVALID;
  }
  le_find_loopback(&ctx, out, NULL);
  ma_context_uninit(&ctx);
  return LE_OK;
}

/* ---- device enumeration & pinning ---- */

/* Serializes a miniaudio device id into a printable, round-trippable token.
 * The backend-specific encoding (char string vs Windows wchar string) lives
 * behind the platform seam so this portable core stays free of OS #ifs; see
 * le_platform_device_id_to_str (engine_platform.h). Enumeration and resolution
 * both route through here, so the token round-trips via strcmp on every OS. */
static void device_id_to_str(const ma_device_id* id, char* out, size_t cap) {
  le_platform_device_id_to_str(id, out, cap);
}

/* The channel count `id` can carry in `capture`'s direction, or 0 when the
 * device cannot answer.
 *
 * ma_context_get_devices returns the CHEAP list — id, name, default flag — and
 * nothing else; the counts live behind ma_context_get_device_info, one query
 * per device. They were never unobtainable here, only unasked-for.
 *
 * Takes the WIDEST advertised format rather than the first: a device that
 * advertises both a 2ch stereo and an 18ch multitrack format is an 18-in
 * interface, and reading nativeDataFormats[0] would call it a stereo one. */
static int32_t query_device_channels(ma_context* ctx, const ma_device_id* id,
                                     int capture) {
  ma_device_info info;
  const ma_device_type type = capture ? ma_device_type_capture
                                      : ma_device_type_playback;
  if (ma_context_get_device_info(ctx, type, id, &info) != MA_SUCCESS) return 0;
  ma_uint32 widest = 0;
  for (ma_uint32 i = 0; i < info.nativeDataFormatCount; ++i) {
    if (info.nativeDataFormats[i].channels > widest) {
      widest = info.nativeDataFormats[i].channels;
    }
  }
  return (int32_t)widest;
}

/* Channel counts memoised per (device id, direction), across enumerations.
 *
 * query_device_channels is the EXPENSIVE half of enumeration — on CoreAudio a
 * run of blocking HAL property reads, one call per device — and enumeration is
 * on a 1 Hz poll so the picker notices an interface being plugged in. Asking
 * once per device instead of once per second per device keeps that poll costing
 * what it cost before the counts existed: a box's channel count does not change
 * while it is plugged in, and an id that comes back is the same box.
 *
 * Control thread only, like everything else in this file (see the header
 * comment), so no lock. A full table is simply a miss, which costs exactly what
 * the uncached path always cost.
 *
 * Sized for BOTH directions at the caller's own capacity, not for one. The FFI
 * caller (native_audio_engine.dart, _maxDevices) asks for up to 64 per
 * direction, so a playback+capture pair can legitimately hand back 128 — and a
 * table capped at 64 would stop memoising partway through the second direction
 * on a big rig, silently putting that tail back on a blocking HAL query per
 * device per second with no log and no counter to say so. Exactly the rigs with
 * enough channels to care about the readout are the ones that would hit it. */
#define LE_CHANNEL_CACHE_MAX 128

/* How many sightings an entry is trusted for before it is read again.
 *
 * A countdown ON THE ENTRY, deliberately, rather than one cursor walking the
 * table: the two enumeration passes each visit only their OWN direction's
 * entries, so a shared cursor spends half its steps parked on entries the
 * current pass never looks at — and because the passes strictly alternate, an
 * even entry count locks each index to one direction's parity and leaves every
 * entry whose direction disagrees with its index parity never re-read at all.
 * A per-entry countdown is decremented exactly when that entry is sighted, so
 * every entry refreshes on its own schedule whatever the table looks like.
 *
 * At the 1 Hz enumeration poll this is a re-read roughly every half minute per
 * device — enough to heal a macOS aggregate that gained a member (its UID does
 * not change) without putting the query back on the hot path.
 *
 * The value itself lives in engine_internal.h so the test that walks entries
 * past their TTL derives its pass count from this number instead of hardcoding
 * one that a retune would quietly leave short. */

typedef struct le_channel_cache_entry {
  char id[256];
  int capture;
  int32_t channels;
  /* Sightings still to go before this entry is re-read. */
  int trust;
} le_channel_cache_entry;

static le_channel_cache_entry g_channel_cache[LE_CHANNEL_CACHE_MAX];
static int g_channel_cache_count = 0;

/* The memo's decision core, with the expensive query indirected through `query`
 * (called with `env`; returns the channel count, 0 = failed/UNKNOWN) so the TTL
 * rules are unit-testable with scripted answers on a box with no devices at
 * all. The live path enters through device_channels below.
 *
 * ONLY a positive answer is memoised. A failed query (channels == 0) is never
 * cached: it returns UNKNOWN and is re-asked on the very next sighting, so a
 * device reporting a transient 0 (e.g. ma_context_get_device_info momentarily
 * failing mid CoreAudio hotplug/reconfigure) self-corrects on the next ~1 Hz
 * poll instead of being pinned at UNKNOWN for up to a TTL window.
 *
 * This is the only path that reaches the memo — device_info_copy's miniaudio
 * enumeration, i.e. macOS/Windows and the Linux JACK/Pulse routes. #649 briefly
 * memoised failures here too (defense against ALSA's PCM-hint clutter: dozens
 * of plugin pseudo-devices that fail their ~38 ms query permanently, re-paid on
 * every 1 Hz pass, ~950 ms per tick on a Pi). But the route fix in
 * le_linux_enum_route_pick sends that jack-less/pulse-less config to
 * le_alsa_enumerate_cards — whose own le_alsa_channels_cached memo never enters
 * this function — so no clutter-shaped list reaches this table any more. The
 * negative cache therefore bought nothing on the miniaudio path while adding a
 * staleness window, so it is dropped and the pre-#649 self-correcting rule
 * restored. */
static int32_t channel_memo(const char* key, int capture,
                            int32_t (*query)(void* env), void* env) {
  for (int i = 0; i < g_channel_cache_count; ++i) {
    le_channel_cache_entry* hit = &g_channel_cache[i];
    if (hit->capture != capture || strcmp(hit->id, key) != 0) continue;
    if (--hit->trust > 0) return hit->channels;
    hit->trust = LE_CHANNEL_CACHE_TTL;
    const int32_t fresh = query(env);
    /* A failed re-read keeps what was already known: 0 means UNKNOWN, and a
     * transient failure must not blank a count the device has answered. Every
     * cached entry is positive (only positives are inserted below), so this
     * only ever protects a real count against a momentary 0. */
    if (fresh > 0) hit->channels = fresh;
    return hit->channels;
  }
  const int32_t channels = query(env);
  /* Only a real answer is remembered — caching a failure would pin the device
   * at UNKNOWN until its trust expired, blinding the readout to a device that
   * would have answered on the next poll. Positive entries are unbounded only
   * in theory: the table is keyed by real device ids in two directions, so in
   * practice it holds at most the host's actual playback+capture device count,
   * far under LE_CHANNEL_CACHE_MAX (128), and a full table simply degrades to
   * the always-query path with no correctness loss. */
  if (channels > 0 && g_channel_cache_count < LE_CHANNEL_CACHE_MAX) {
    const int index = g_channel_cache_count++;
    le_channel_cache_entry* entry = &g_channel_cache[index];
    strncpy(entry->id, key, sizeof(entry->id) - 1);
    entry->id[sizeof(entry->id) - 1] = '\0';
    entry->capture = capture;
    entry->channels = channels;
    /* Seeded from the insertion index so entries fall due on different
     * sightings rather than the whole table re-reading on one poll. */
    entry->trust = index % LE_CHANNEL_CACHE_TTL + 1;
  }
  return channels;
}

int32_t le_channel_memo_for_test(const char* key, int capture,
                                 int32_t (*query)(void* env), void* env) {
  return channel_memo(key, capture, query, env);
}

/* Adapter marshalling the live miniaudio query through channel_memo's
 * indirection. */
typedef struct le_channel_query_env {
  ma_context* ctx;
  const ma_device_id* id;
  int capture;
} le_channel_query_env;

static int32_t channel_query_thunk(void* env) {
  const le_channel_query_env* q = (const le_channel_query_env*)env;
  return query_device_channels(q->ctx, q->id, q->capture);
}

static int32_t device_channels(ma_context* ctx, const ma_device_id* id,
                               const char* key, int capture) {
  le_channel_query_env env;
  env.ctx = ctx;
  env.id = id;
  env.capture = capture;
  return channel_memo(key, capture, channel_query_thunk, &env);
}

static void device_info_copy(le_device_info* dst, const ma_device_info* src,
                             ma_context* ctx, int capture) {
  /* Zero everything first so no field it does not fill carries stack
   * garbage. */
  memset(dst, 0, sizeof(*dst));
  device_id_to_str(&src->id, dst->id, sizeof(dst->id));
  strncpy(dst->name, src->name, sizeof(dst->name) - 1);
  dst->name[sizeof(dst->name) - 1] = '\0';
  dst->is_default = src->isDefault ? 1 : 0;
  /* Only the direction being enumerated: a playback device reports what it can
   * PLAY and never the other way round, so the opposite field stays 0. A device
   * that cannot answer keeps 0 too, which still means UNKNOWN — the UI omits
   * the readout rather than printing a zero count. The serialized id is the
   * cache key, so it has to be written before this. */
  if (capture) {
    dst->input_channels = device_channels(ctx, &src->id, dst->id, 1);
  } else {
    dst->output_channels = device_channels(ctx, &src->id, dst->id, 0);
  }
}

/* Which enumerator the Linux platform seam should try first (engine_platform.h
 * has the enum). Pure policy — the dlopen probes feeding it live in
 * engine_linux.c — kept in the portable core so the table is compiled and
 * unit-tested on every OS.
 *
 * The invariant this table protects is id ↔ backend consistency: an enumerated
 * id must resolve (le_resolve_device_id, a strcmp against the open context's
 * own enumeration below) on the backend the device will actually OPEN on,
 * which le_platform_backends orders JACK → PulseAudio → ALSA. Row by row:
 *
 *  - alsa_only (appliance): ALSA cards, unchanged — the open is pinned to the
 *    ALSA backend and the card ids are its tokens.
 *  - libjack present: JACK enumeration; the open lands on JACK and the ids are
 *    JACK node names. (If JACK then declines at runtime — server down, no
 *    ports — the seam returns 0 and miniaudio takes it, as before #649.)
 *  - no libjack, libpulse present: decline to miniaudio — its default probe
 *    order reaches Pulse, the open also lands on Pulse, ids match, and Pulse
 *    enumeration has none of the ALSA hint-clutter pathology.
 *  - NEITHER library (#649): ALSA cards. This is the only configuration whose
 *    device opens on the ALSA backend without SEGNO_ALSA_ONLY, and the cards
 *    ids (":<card>,<dev>") are by construction the tokens miniaudio's
 *    simplified ALSA enumeration yields for the same hardware (the header
 *    comment on le_alsa_enumerate_cards), so resolution still pins. Before
 *    #649 this row fell to miniaudio's full ALSA probe: the whole PCM hint
 *    namespace, ~38 ms per mostly-failing channel query, ~950 ms per 1 Hz
 *    poll tick on a Pi — versus ~0.15 ms reading /proc/asound/cards.
 *
 * Every ALSA_CARDS row still has the portable miniaudio backstop behind it:
 * cards enumeration declines when no card has a PCM in the asked direction
 * (unplugged interface, HDMI-only box), and enumerate_devices then runs the
 * miniaudio path — the pinned appliance behaviour (see the comment there). */
le_linux_enum_route le_linux_enum_route_pick(int alsa_only, int jack_present,
                                             int pulse_present) {
  if (alsa_only) return LE_LINUX_ENUM_ALSA_CARDS;
  if (jack_present) return LE_LINUX_ENUM_JACK;
  if (pulse_present) return LE_LINUX_ENUM_MINIAUDIO;
  return LE_LINUX_ENUM_ALSA_CARDS; /* the #649 fall-through */
}

/* Fills `out` (room for `max`) with the host's playback or capture devices and
 * writes the count into *count. Uses a transient context so it never disturbs a
 * running device. `capture` selects the direction. Externally linked (declared
 * in engine_private.h) so the Linux JACK pin hook can resolve friendly device
 * names through it; defined only here. */
int32_t enumerate_devices(le_device_info* out, int32_t max, int32_t* count,
                          int capture) {
  if (out == NULL || count == NULL || max <= 0) return LE_ERR_INVALID;
  *count = 0;
  /* Prefer the platform-native list when the OS has a better source than
   * miniaudio's default backend. On Linux that is JACK: playback runs on the
   * JACK backend, so enumerating via ALSA (miniaudio's default) both surfaces
   * plugin clutter and hands back ids that never match a JACK port prefix, so a
   * selection cannot route. When this handles it, the ids pin correctly. */
  if (le_platform_enumerate_devices(out, max, count, capture)) return LE_OK;
  /* The seam declines whenever it finds no card in this direction — an
   * appliance whose interface is unplugged, or one whose only remaining cards
   * are the filtered-out vc4-hdmi outputs — so this fall-through runs on the
   * appliance too, once per direction per poll. It must stay pinned. */
  ma_context ctx;
  if (le_probe_context_init(&ctx) != MA_SUCCESS) return LE_ERR_INVALID;
  ma_device_info* playback = NULL;
  ma_uint32 playback_count = 0;
  ma_device_info* cap = NULL;
  ma_uint32 cap_count = 0;
  if (ma_context_get_devices(&ctx, &playback, &playback_count, &cap,
                             &cap_count) != MA_SUCCESS) {
    ma_context_uninit(&ctx);
    return LE_ERR_INVALID;
  }
  ma_device_info* list = capture ? cap : playback;
  ma_uint32 n = capture ? cap_count : playback_count;
  int32_t written = 0;
  for (ma_uint32 i = 0; i < n && written < max; ++i) {
    device_info_copy(&out[written++], &list[i], &ctx, capture);
  }
  *count = written;
  ma_context_uninit(&ctx);
  return LE_OK;
}

int32_t le_enumerate_playback_devices(le_device_info* out, int32_t max,
                                      int32_t* count) {
  return enumerate_devices(out, max, count, /*capture=*/0);
}

int32_t le_enumerate_capture_devices(le_device_info* out, int32_t max,
                                     int32_t* count) {
  return enumerate_devices(out, max, count, /*capture=*/1);
}

/* Looks up the device whose serialized id equals `want` in the already-open
 * `ctx` and copies its native id into *out_id. Returns 1 on a match (out_id set)
 * or 0 if `want` is empty / unmatched / enumeration failed. */
int le_resolve_device_id(ma_context* ctx, int capture, const char* want,
                         ma_device_id* out_id) {
  if (want == NULL || want[0] == '\0') return 0;
  ma_device_info* playback = NULL;
  ma_uint32 playback_count = 0;
  ma_device_info* cap = NULL;
  ma_uint32 cap_count = 0;
  if (ma_context_get_devices(ctx, &playback, &playback_count, &cap,
                             &cap_count) != MA_SUCCESS) {
    return 0;
  }
  ma_device_info* list = capture ? cap : playback;
  ma_uint32 n = capture ? cap_count : playback_count;
  char buf[256];
  for (ma_uint32 i = 0; i < n; ++i) {
    device_id_to_str(&list[i].id, buf, sizeof(buf));
    if (strcmp(buf, want) == 0) {
      *out_id = list[i].id;
      return 1;
    }
  }
  return 0;
}

/* ---- device backend selection ---- */

#ifdef LE_NATIVE_TESTS
const le_device_backend* le_test_backend_override = NULL;
#endif

/* Selects the device backend: miniaudio, the only one this engine ships (or
 * the native tests' fake device). */
const le_device_backend* le_select_backend(void) {
#ifdef LE_NATIVE_TESTS
  if (le_test_backend_override != NULL) return le_test_backend_override;
#endif
  return &le_miniaudio_backend;
}

