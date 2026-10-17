/*
 * synth_patch.c — the nineteen Segno synthesis patches and their family
 * parameters (#1197), plus the public catalogue reads in segno_engine_api.h.
 *
 * Values are the accepted catalogue's (docs/design/instrument-catalogue.js,
 * main checkout): id, family, first-partial wave, second-partial ratio,
 * transient sustain level and the three defaults per patch; the resonant
 * leads' Q of 2.8 and the extra bells partial come from instrument-runtime.js.
 * Order is the catalogue's and is part of the contract (sessions store the id,
 * the app lists in this order).
 *
 * One deliberate difference from the prototype: it displayed attack as
 * 0.08 + v/100 * 2.4 s but synthesized 0.008 + v/100 * 0.9 s. Here the
 * attack parameter has one mapping, the synthesized one, and the app shows
 * what the voice does.
 */
#include <math.h>
#include <string.h>

#include "segno_engine_api.h"
#include "synth_voice.h"

#define W_SINE LE_SYNTH_WAVE_SINE
#define W_TRI LE_SYNTH_WAVE_TRIANGLE
#define W_SAW LE_SYNTH_WAVE_SAW
#define W_SQR LE_SYNTH_WAVE_SQUARE
#define W_NOISE LE_SYNTH_WAVE_NOISE

/* id, family, wave, ratio, level, resonance, transient, extra, electronic,
 * defaults */
static const le_synth_patch k_patches[LE_SYNTH_PATCHES] = {
    {"piano", LE_SYNTH_KEYS, W_TRI, 2.0f, 0.12f, 0.7f, 1, 0, 0, {68, 72, 22}},
    {"keys", LE_SYNTH_KEYS, W_SINE, 3.0f, 0.18f, 0.7f, 1, 0, 0, {52, 60, 45}},
    {"clav", LE_SYNTH_KEYS, W_SAW, 2.0f, 0.06f, 0.7f, 1, 0, 0, {80, 18, 65}},
    {"organ", LE_SYNTH_ORGANS, W_SINE, 2.0f, 0.65f, 0.7f, 0, 0, 0, {60, 35, 8}},
    {"reed", LE_SYNTH_ORGANS, W_TRI, 3.0f, 0.5f, 0.7f, 0, 0, 0, {45, 12, 22}},
    {"lead", LE_SYNTH_SYNTHS, W_SAW, 1.006f, 0.48f, 2.8f, 0, 0, 0, {72, 2, 25}},
    {"pad", LE_SYNTH_SYNTHS, W_TRI, 1.004f, 0.5f, 0.7f, 0, 0, 0, {42, 60, 72}},
    {"pluck", LE_SYNTH_SYNTHS, W_SQR, 2.0f, 0.035f, 0.7f, 1, 0, 0, {62, 0, 12}},
    {"bass", LE_SYNTH_BASS, W_TRI, 2.0f, 0.19f, 0.7f, 1, 0, 0, {35, 65, 18}},
    {"synth-bass", LE_SYNTH_BASS, W_SAW, 1.005f, 0.35f, 2.8f, 1, 0, 0,
     {43, 75, 24}},
    {"sub", LE_SYNTH_BASS, W_SINE, 1.0f, 0.5f, 0.7f, 1, 0, 0, {20, 20, 30}},
    {"strings", LE_SYNTH_STRINGS, W_SAW, 1.008f, 0.4f, 0.7f, 0, 0, 0,
     {42, 55, 28}},
    {"violin", LE_SYNTH_STRINGS, W_SAW, 2.0f, 0.3f, 0.7f, 0, 0, 0, {64, 30, 38}},
    {"cello", LE_SYNTH_STRINGS, W_TRI, 2.0f, 0.4f, 0.7f, 0, 0, 0, {30, 45, 20}},
    {"drums", LE_SYNTH_DRUMS, W_NOISE, 1.0f, 0.0f, 0.7f, 0, 0, 0, {52, 40, 65}},
    {"electronic-drums", LE_SYNTH_DRUMS, W_NOISE, 1.0f, 0.0f, 0.7f, 0, 0, 1,
     {75, 25, 80}},
    {"marimba", LE_SYNTH_PERCUSSION, W_SINE, 4.0f, 0.025f, 0.7f, 1, 0, 0,
     {35, 42, 0}},
    {"vibes", LE_SYNTH_PERCUSSION, W_SINE, 3.0f, 0.065f, 0.7f, 1, 0, 0,
     {50, 80, 35}},
    {"bells", LE_SYNTH_PERCUSSION, W_SINE, 2.76f, 0.025f, 0.7f, 1, 1, 0,
     {80, 90, 0}},
};

#define PCT(key) {key, LE_SYNTH_UNIT_PERCENT, 0.0f, 100.0f, 0}
/* Decay and release: 0.08 .. 2.48 s. */
#define SECS(key) {key, LE_SYNTH_UNIT_SECONDS, 0.08f, 2.48f, 0}
/* Attack: 0.008 .. 0.908 s. */
#define ATTACK(key) {key, LE_SYNTH_UNIT_SECONDS, 0.008f, 0.908f, 0}
/* Cutoff: 180 Hz .. 180 * 70 = 12.6 kHz, exponential. */
#define CUTOFF(key) {key, LE_SYNTH_UNIT_HERTZ, 180.0f, 12600.0f, 1}

static const le_synth_param k_params[LE_SYNTH_FAMILIES][LE_SYNTH_FAMILY_PARAMS] = {
    /* Keys */ {PCT("brightness"), SECS("decay"), PCT("character")},
    /* Organs */ {PCT("harmonics"), PCT("rotary"), SECS("release")},
    /* Synths */ {CUTOFF("cutoff"), ATTACK("attack"), SECS("release")},
    /* Bass */ {CUTOFF("cutoff"), PCT("punch"), SECS("release")},
    /* Strings */ {PCT("brightness"), ATTACK("attack"), PCT("vibrato")},
    /* Drums */ {PCT("tone"), SECS("decay"), PCT("body")},
    /* Percussion */ {PCT("hardness"), SECS("decay"), PCT("tremolo")},
};

const le_synth_patch* le_synth_patch_at(int32_t index) {
  if (index < 0 || index >= LE_SYNTH_PATCHES) return NULL;
  return &k_patches[index];
}

int32_t le_synth_patch_find(const char* id) {
  if (id == NULL) return -1;
  for (int32_t i = 0; i < LE_SYNTH_PATCHES; ++i) {
    if (strcmp(k_patches[i].id, id) == 0) return i;
  }
  return -1;
}

const le_synth_param* le_synth_family_param(int32_t family, int32_t index) {
  if (family < 0 || family >= LE_SYNTH_FAMILIES || index < 0 ||
      index >= LE_SYNTH_FAMILY_PARAMS) {
    return NULL;
  }
  return &k_params[family][index];
}

float le_synth_param_value(const le_synth_param* p, float v) {
  if (v < 0.0f) v = 0.0f;
  if (v > 100.0f) v = 100.0f;
  if (p->exponential) return p->at_min * powf(p->at_max / p->at_min, v / 100.0f);
  return p->at_min + (p->at_max - p->at_min) * v / 100.0f;
}

/* ---- public catalogue reads (segno_engine_api.h) ---- */

LE_EXPORT int32_t le_synth_patch_count(void) { return LE_SYNTH_PATCHES; }

LE_EXPORT int32_t le_synth_patch_info(int32_t index, le_synth_patch_desc* out) {
  const le_synth_patch* p = le_synth_patch_at(index);
  if (out == NULL || p == NULL) return LE_ERR_INVALID;
  memset(out, 0, sizeof(*out));
  strncpy(out->id, p->id, LE_SYNTH_ID_CHARS - 1);
  out->family = p->family;
  for (int i = 0; i < LE_SYNTH_FAMILY_PARAMS; ++i) out->defaults[i] = p->defaults[i];
  return LE_OK;
}

LE_EXPORT int32_t le_synth_param_info(int32_t family, int32_t param,
                                      le_synth_param_desc* out) {
  const le_synth_param* p = le_synth_family_param(family, param);
  if (out == NULL || p == NULL) return LE_ERR_INVALID;
  memset(out, 0, sizeof(*out));
  strncpy(out->key, p->key, LE_SYNTH_KEY_CHARS - 1);
  out->unit = p->unit;
  out->at_min = p->at_min;
  out->at_max = p->at_max;
  out->exponential = p->exponential;
  return LE_OK;
}
