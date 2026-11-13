#include "fx_slot.h"

#include <stdlib.h>
#include <string.h>

#include "engine_fx.h"

struct segno_fx_slot {
  le_fx_state* fx;
  int32_t at; /* the chain slot the kind runs on; those before it are empty */
  le_fx_tempo tempo;
  int32_t sr;
  int32_t types[LE_FX_MAX];
  float params[LE_FX_MAX][LE_FX_PARAMS];
  int32_t enabled[LE_FX_MAX];
};

void segno_fx_slot_set_channels(segno_fx_slot* s, int32_t input, int32_t output,
                                float placement, float level) {
  le_fx_chan* c = &s->fx->chan[s->at];
  c->in_mode = input >= LE_FX_CHAN_IN_STEREO && input <= LE_FX_CHAN_IN_MONO
                   ? input
                   : LE_FX_CHAN_IN_STEREO;
  c->out_mode =
      output == LE_FX_CHAN_OUT_MONO ? LE_FX_CHAN_OUT_MONO : LE_FX_CHAN_OUT_STEREO;
  /* NaN reads as centre, the engine's setters' rule (le_pr_seed_channels). */
  if (!(placement >= -1.0f)) placement = placement < -1.0f ? -1.0f : 0.0f;
  if (placement > 1.0f) placement = 1.0f;
  le_pan_gains(placement, &c->gl, &c->gr);
  if (!(level >= 0.0f)) level = 0.0f;
  if (level > LE_FX_LEVEL_MAX) level = LE_FX_LEVEL_MAX;
  c->level = level;
  c->rack = 0;
  s->fx->chan_any = c->in_mode != LE_FX_CHAN_IN_STEREO ||
                    c->out_mode != LE_FX_CHAN_OUT_STEREO || c->gl != 1.0f ||
                    c->gr != 1.0f || c->level != 1.0f;
}

/* le_pr_arm_slot: the slot's buffers, its reset, and a Pumper or an
 * octaver settled at its settings. */
static int arm_slot(segno_fx_slot* s) {
  const int at = s->at;
  const int32_t type = s->types[at];
  if (le_fx_prepare(s->fx, at, type, s->sr) != LE_OK) return 0;
  le_fx_entry_reset(s->fx, at, type);
  if (type == LE_FX_PUMPER) {
    le_fx_pumper_seed_settled(s->fx, at, s->params[at], s->sr);
  }
  if (le_fx_type_hops(type)) {
    float q[LE_FX_PARAMS];
    le_fx_octaver_settings(type, s->params[at], q);
    le_fx_octaver_seed_settled(s->fx, at, q);
  }
  return 1;
}

segno_fx_slot* segno_fx_slot_new(const segno_fx_slot_config* c) {
  if (segno_fx_width(c->type) <= 0 || c->slot < 0 || c->slot >= LE_FX_MAX) {
    return NULL;
  }
  segno_fx_slot* s = (segno_fx_slot*)calloc(1, sizeof(segno_fx_slot));
  if (s == NULL) return NULL;
  s->fx = (le_fx_state*)calloc(1, sizeof(le_fx_state));
  if (s->fx == NULL) {
    free(s);
    return NULL;
  }
  s->sr = c->sr > 0 ? c->sr : 48000;
  s->at = c->slot;
  /* le_pr_wet_open's order: the hop seed, the clock and the tempo, the
   * enable ramps, the channel handling, then the slot. */
  s->fx->hop_seed = c->hop_seed;
  s->fx->clock = c->clock;
  s->fx->clocked = 1;
  segno_fx_slot_set_tempo(s, c->clock, c->beat, c->qpf, c->num, c->den);
  s->fx->tempo = &s->tempo;
  for (int i = 0; i < LE_FX_MAX; ++i) {
    s->types[i] = LE_FX_NONE;
    s->enabled[i] = 1;
  }
  s->types[s->at] = c->type;
  s->enabled[s->at] = c->enabled != 0;
  le_fx_defaults(c->type, s->params[s->at]);
  const int32_t width = segno_fx_width(c->type);
  for (int32_t p = 0; p < c->count && p < width; ++p) {
    s->params[s->at][p] = c->params[p];
  }
  for (int i = 0; i < LE_FX_MAX; ++i) le_fx_enable_seed_at(s->fx, i, s->enabled[i]);
  segno_fx_slot_set_channels(s, c->input, c->output, c->placement, c->level);
  if (!arm_slot(s)) {
    segno_fx_slot_free(s);
    return NULL;
  }
  return s;
}

void segno_fx_slot_free(segno_fx_slot* s) {
  if (s == NULL) return;
  le_fx_state_free_buffers(s->fx);
  free(s->fx);
  free(s);
}

void segno_fx_slot_frame(segno_fx_slot* s, uint32_t clock, float* l, float* r) {
  s->fx->clock = clock;
  fx_apply_chain(s->fx, s->sr, s->sr, l, r, s->at + 1, s->types,
                 (const float(*)[LE_FX_PARAMS])s->params, s->enabled);
}

void segno_fx_slot_set_param(segno_fx_slot* s, int32_t param, float value) {
  if (param >= 0 && param < segno_fx_width(s->types[s->at])) {
    s->params[s->at][param] = value;
  }
}

void segno_fx_slot_set_enabled(segno_fx_slot* s, int32_t enabled) {
  s->enabled[s->at] = enabled != 0;
}

void segno_fx_slot_set_tempo(segno_fx_slot* s, uint32_t clock, double beat,
                             float qpf, int32_t num, int32_t den) {
  s->tempo.anchor_clock = clock;
  s->tempo.anchor_beat = beat;
  s->tempo.qpf = qpf;
  s->tempo.num = num > 0 ? num : 4;
  s->tempo.den = den > 0 ? den : 4;
}

double segno_fx_slot_beat_at(const segno_fx_slot* s, uint32_t clock) {
  return s->tempo.anchor_beat +
         (double)(uint32_t)(clock - s->tempo.anchor_clock) * (double)s->tempo.qpf;
}

void segno_fx_slot_reseed(segno_fx_slot* s, int32_t hop_seed) {
  s->fx->hop_seed = hop_seed;
  le_fx_entry_clear_rings(s->fx, s->at, s->sr, s->types[s->at]);
  arm_slot(s);
}

int32_t segno_fx_slot_latency(const segno_fx_slot* s) {
  return le_fx_added_latency(s->fx, s->at, s->types[s->at], s->sr);
}

int32_t segno_fx_width(int32_t type) {
  return le_fx_settable_type(type) ? le_fx_param_width(type) : 0;
}

void segno_fx_defaults(int32_t type, float* out) { le_fx_defaults(type, out); }

int32_t segno_fx_drains(int32_t type) {
  return le_fx_type_drains(type) || type == LE_FX_MODE_DELAY;
}

int32_t segno_fx_lane_hop_seed(int32_t track, int32_t lane) {
  return le_fx_lane_hop_seed(track, lane);
}

void segno_fx_flush_denormals(void) { le_flush_denormals(); }
