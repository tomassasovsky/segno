/*
 * fx_slot.h — one built-in effect on a chain slot of its own, as the
 * plugins (and their null test) run it: the C side of Segno.vst3.
 *
 * The plugin's C++ never includes the engine's private headers (C11
 * atomics that only Clang reads as C++); everything that touches an
 * le_fx_state is here, compiled as C with the effects island.
 *
 * A slot is set up the way the offline render (perf_render.c,
 * le_pr_wet_open and le_pr_arm_slot) sets up a slot that holds an effect at
 * arm, and each frame runs fx_apply_chain on it with the clock set to the
 * engine frame it stands for, so its output is the engine's.
 */
#ifndef SEGNO_VST3_FX_SLOT_H
#define SEGNO_VST3_FX_SLOT_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct segno_fx_slot segno_fx_slot;

/* What a slot starts from. */
typedef struct segno_fx_slot_config {
  int32_t type;     /* le_fx_type */
  int32_t slot;     /* the chain slot it runs on, 0..LE_FX_MAX - 1 */
  int32_t sr;       /* sample rate; also the delay rings' length */
  int32_t hop_seed; /* the owner's octaver hop quarter */
  uint32_t clock;   /* the engine frame of the first frame */
  double beat;      /* the beat at that frame, quarter notes */
  float qpf;        /* quarter notes a frame */
  int32_t num, den; /* time signature */
  int32_t input, output; /* le_fx_chan_in, le_fx_chan_out */
  float placement, level;
  int32_t enabled;
  const float* params; /* [count] settings, the rest at the kind's defaults */
  int32_t count;
} segno_fx_slot_config;

/* A slot of [c], or NULL when the kind is unknown or its buffers cannot be
 * had. Allocates. */
segno_fx_slot* segno_fx_slot_new(const segno_fx_slot_config* c);
void segno_fx_slot_free(segno_fx_slot* s);

/* One frame at engine frame [clock], in place. */
void segno_fx_slot_frame(segno_fx_slot* s, uint32_t clock, float* l, float* r);

void segno_fx_slot_set_param(segno_fx_slot* s, int32_t param, float value);
void segno_fx_slot_set_enabled(segno_fx_slot* s, int32_t enabled);
void segno_fx_slot_set_channels(segno_fx_slot* s, int32_t input, int32_t output,
                                float placement, float level);
/* The tempo from engine frame [clock] on: [beat] there, [qpf] a frame. */
void segno_fx_slot_set_tempo(segno_fx_slot* s, uint32_t clock, double beat,
                             float qpf, int32_t num, int32_t den);
/* The beat the slot's tempo puts engine frame [clock] at. */
double segno_fx_slot_beat_at(const segno_fx_slot* s, uint32_t clock);
/* A new hop seed, the slot's state cleared (a host's new state while it
 * runs). */
void segno_fx_slot_reseed(segno_fx_slot* s, int32_t hop_seed);

/* Frames the kind delays its output by at the slot's rate. */
int32_t segno_fx_slot_latency(const segno_fx_slot* s);

/* The kind's facts, any thread: how many settings it reads (0 for an
 * unknown kind), their defaults (LE_FX_PARAMS floats), whether its tail
 * drains after a bypass (a delay or a reverb), and an engine lane's hop
 * seed. */
int32_t segno_fx_width(int32_t type);
void segno_fx_defaults(int32_t type, float* out);
int32_t segno_fx_drains(int32_t type);
int32_t segno_fx_lane_hop_seed(int32_t track, int32_t lane);

/* Frames [type] delays its output by at [sr] (le_fx_added_latency), from a
 * slot made for the question. Allocates. */
int32_t segno_fx_latency(int32_t type, int32_t sr);

/* Flushes denormals on the calling thread, as the engine's threads do
 * before a chain runs (le_flush_denormals), and returns the floating-point
 * mode it found, which segno_fx_restore_fp_mode puts back: a plugin shares
 * the host's thread, so it leaves the mode as it found it. */
uint64_t segno_fx_flush_denormals(void);
void segno_fx_restore_fp_mode(uint64_t mode);

#ifdef __cplusplus
}
#endif

#endif /* SEGNO_VST3_FX_SLOT_H */
