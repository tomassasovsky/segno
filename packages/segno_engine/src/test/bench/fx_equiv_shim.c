/*
 * fx_equiv_shim.c — one effect kind's chain, as bench_fx_equiv drives it
 * (#1755).
 *
 * Compiled into each of the two libraries bench_fx_equiv.sh builds, the
 * reference engine's and the working tree's, against that tree's own
 * headers, so the harness never depends on either tree's structures. It runs
 * slot 0 of a standalone le_fx_state the way a monitored input's chain runs:
 * the denormals flushed at each block, the state clocked by the engine's
 * frame count, the settings handed in once a block, a fixed tempo for the
 * kinds that lock to the beat.
 */
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "engine_fx.h"

typedef struct eqv {
  le_fx_state* fx;
  le_fx_tempo tempo;
  int32_t sr;
  uint32_t clock;
  int32_t types[LE_FX_MAX];
  float params[LE_FX_MAX][LE_FX_PARAMS];
} eqv;

/* A chain of one [type] at [sr], its rings a second long as the engine
 * makes them; NULL when the kind refuses. [bpm] sets the tempo. */
void* eqv_new(int32_t type, int32_t sr, double bpm) {
  eqv* h = (eqv*)calloc(1, sizeof(eqv));
  if (h == NULL) return NULL;
  h->fx = (le_fx_state*)calloc(1, sizeof(le_fx_state));
  if (h->fx == NULL) {
    free(h);
    return NULL;
  }
  h->sr = sr;
  for (int s = 0; s < LE_FX_MAX; ++s) {
    le_fx_enable_seed_settled(h->fx, s);
    h->types[s] = LE_FX_NONE;
  }
  h->types[0] = type;
  h->fx->hop_seed = le_fx_monitor_hop_seed(0);
  h->tempo.anchor_clock = 0u;
  h->tempo.anchor_beat = 0.0;
  h->tempo.qpf = (float)(bpm / 60.0 / (double)sr);
  h->tempo.num = 4;
  h->tempo.den = 4;
  h->fx->tempo = &h->tempo;
  h->fx->clocked = 1;
  le_fx_entry_reset(h->fx, 0, type);
  if (le_fx_prepare(h->fx, 0, type, sr) != LE_OK) {
    le_fx_state_free_buffers(h->fx);
    free(h->fx);
    free(h);
    return NULL;
  }
  return h;
}

/* One block of [n] frames at settings [p] (LE_FX_PARAMS of them), from
 * [in_l]/[in_r] into [out_l]/[out_r]. */
void eqv_block(void* hv, const float* p, const float* in_l, const float* in_r,
               float* out_l, float* out_r, int32_t n) {
  eqv* h = (eqv*)hv;
  le_flush_denormals();
  memcpy(h->params[0], p, sizeof(float) * LE_FX_PARAMS);
  for (int32_t i = 0; i < n; ++i) {
    h->fx->clock = h->clock++;
    float l = in_l[i];
    float r = in_r[i];
    fx_apply_chain(h->fx, h->sr, h->sr, &l, &r, 1, h->types, h->params, NULL);
    out_l[i] = l;
    out_r[i] = r;
  }
}

/* A new tempo of [bpm] from the next frame, the beat carrying on. */
void eqv_tempo(void* hv, double bpm) {
  eqv* h = (eqv*)hv;
  h->tempo.anchor_beat += (double)(h->clock - h->tempo.anchor_clock) *
                          (double)h->tempo.qpf;
  h->tempo.anchor_clock = h->clock;
  h->tempo.qpf = (float)(bpm / 60.0 / (double)h->sr);
}

void eqv_free(void* hv) {
  eqv* h = (eqv*)hv;
  if (h == NULL) return;
  le_fx_state_free_buffers(h->fx);
  free(h->fx);
  free(h);
}

/* The settings count of [type] and its defaults, for the harness. */
int32_t eqv_width(int32_t type) { return le_fx_param_width(type); }
int32_t eqv_params(void) { return LE_FX_PARAMS; }
void eqv_defaults(int32_t type, float* out) { le_fx_defaults(type, out); }
