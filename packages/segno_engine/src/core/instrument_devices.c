/*
 * instrument_devices.c — the instrument device table (instrument_devices.h).
 */
#include "instrument_devices.h"

#include "analog_voice.h"
#include "collision_voice.h"
#include "drift_voice.h"
#include "electric_voice.h"
#include "meld_voice.h"
#include "operator_voice.h"
#include "tension_voice.h"
#include "segno_engine_api.h"

/* The table's functions for device type T with prefix P: each casts the
 * instance and calls P's own. */
#define LE_DEVICE_FUNCTIONS(T, P)                                                    \
  static int32_t P##_init_v(void* d, int32_t sr) { return P##_init((T*)d, sr); }     \
  static void P##_set_values_v(void* d, const float* v) { P##_set_values((T*)d, v); } \
  static int32_t P##_note_on_v(void* d, uint32_t o, int32_t n, int32_t v, int c) {   \
    return P##_note_on((T*)d, o, n, v, c);                                           \
  }                                                                                  \
  static void P##_note_off_v(void* d, uint32_t o) { P##_note_off((T*)d, o); }        \
  static int32_t P##_sustain_v(void* d, uint32_t o, int on) {                        \
    return P##_sustain((T*)d, o, on);                                                \
  }                                                                                  \
  static void P##_expression_v(void* d, int32_t k, float v) {                        \
    P##_expression((T*)d, k, v);                                                     \
  }                                                                                  \
  static void P##_release_matching_v(void* d, uint32_t m, uint32_t v) {              \
    P##_release_matching((T*)d, m, v);                                               \
  }                                                                                  \
  static int32_t P##_held_v(const void* d, uint32_t o) {                             \
    return P##_held((const T*)d, o);                                                 \
  }                                                                                  \
  static void P##_cut_v(void* d) { P##_cut((T*)d); }                                 \
  static void P##_set_voice_limit_v(void* d, int32_t l) {                            \
    P##_set_voice_limit((T*)d, l);                                                   \
  }                                                                                  \
  static int32_t P##_fade_oldest_v(void* d) { return P##_fade_oldest((T*)d); }       \
  static void P##_set_tempo_v(void* d, float b) { P##_set_tempo((T*)d, b); }         \
  static void P##_render_v(void* d, float* l, float* r, int32_t n) {                 \
    P##_render((T*)d, l, r, n);                                                      \
  }                                                                                  \
  static int32_t P##_active_v(const void* d) { return P##_active((const T*)d); }     \
  static int32_t P##_fading_v(const void* d) { return P##_fading((const T*)d); }     \
  static uint32_t P##_stolen_v(const void* d) { return ((const T*)d)->stolen; }

#define LE_DEVICE_ENTRY(ID, T, P, N)                                                       \
  {ID,                    N,                          sizeof(T),       P##_default,         \
   P##_clamp,             P##_init_v,                 P##_set_values_v, P##_note_on_v,      \
   P##_note_off_v,        P##_sustain_v,              P##_expression_v, P##_release_matching_v, \
   P##_held_v,            P##_cut_v,                  P##_set_voice_limit_v, P##_fade_oldest_v, \
   P##_set_tempo_v,       P##_render_v,               P##_active_v,    P##_fading_v,        \
   P##_stolen_v}

LE_DEVICE_FUNCTIONS(le_drift, le_drift)
LE_DEVICE_FUNCTIONS(le_operator, le_operator)
LE_DEVICE_FUNCTIONS(le_meld, le_meld)
LE_DEVICE_FUNCTIONS(le_analog, le_analog)
LE_DEVICE_FUNCTIONS(le_electric, le_electric)
LE_DEVICE_FUNCTIONS(le_tension, le_tension)
LE_DEVICE_FUNCTIONS(le_collision, le_collision)

const le_inst_device le_inst_devices[LE_INST_DEVICE_COUNT] = {
    LE_DEVICE_ENTRY(LE_INST_DEVICE_DRIFT, le_drift, le_drift, LE_DRIFT_PARAMS),
    LE_DEVICE_ENTRY(LE_INST_DEVICE_OPERATOR, le_operator, le_operator, LE_OPERATOR_PARAMS),
    LE_DEVICE_ENTRY(LE_INST_DEVICE_MELD, le_meld, le_meld, LE_MELD_PARAMS),
    LE_DEVICE_ENTRY(LE_INST_DEVICE_ANALOG, le_analog, le_analog, LE_ANALOG_PARAMS),
    LE_DEVICE_ENTRY(LE_INST_DEVICE_ELECTRIC, le_electric, le_electric, LE_ELECTRIC_PARAMS),
    LE_DEVICE_ENTRY(LE_INST_DEVICE_TENSION, le_tension, le_tension, LE_TENSION_PARAMS),
    LE_DEVICE_ENTRY(LE_INST_DEVICE_COLLISION, le_collision, le_collision, LE_COLLISION_PARAMS),
};

_Static_assert((int)LE_DRIFT_PARAMS <= (int)LE_INST_DEVICE_MAX_PARAMS &&
                   (int)LE_OPERATOR_PARAMS <= (int)LE_INST_DEVICE_MAX_PARAMS &&
                   (int)LE_ANALOG_PARAMS <= (int)LE_INST_DEVICE_MAX_PARAMS &&
                   (int)LE_ELECTRIC_PARAMS <= (int)LE_INST_DEVICE_MAX_PARAMS &&
                   (int)LE_TENSION_PARAMS <= (int)LE_INST_DEVICE_MAX_PARAMS &&
                   (int)LE_COLLISION_PARAMS <= (int)LE_INST_DEVICE_MAX_PARAMS,
               "LE_INST_DEVICE_MAX_PARAMS holds every device's parameters");
_Static_assert(LE_INST_DEVICE_COLLISION - LE_INST_DEVICE_DRIFT + 1 == LE_INST_DEVICE_COUNT,
               "one table entry per device");

const le_inst_device* le_inst_device_find(int32_t id) {
  const int32_t i = id - LE_INST_DEVICE_DRIFT;
  return i >= 0 && i < LE_INST_DEVICE_COUNT ? &le_inst_devices[i] : NULL;
}
