/*
 * instrument_devices.h — the table of instrument devices an instrument slot
 * can play (LE_INST_DEVICE_*), so the slot code reaches each one through the
 * same functions (SEG-109).
 *
 * Every device keeps one instance per slot in its own array, allocated once
 * (engine_instruments.c), so a slot that changes device lets the old one's
 * voices fade while the new one starts. Each entry wraps the device's own
 * le_<device>_* functions, which all share one shape.
 */
#ifndef SEGNO_INSTRUMENT_DEVICES_H
#define SEGNO_INSTRUMENT_DEVICES_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct le_inst_device {
  int32_t id;     /* LE_INST_DEVICE_* */
  int32_t params; /* its parameter count */
  size_t size;    /* bytes of one instance */
  float (*def)(int32_t param);
  float (*clamp)(int32_t param, float value);
  int32_t (*init)(void* d, int32_t sample_rate);
  void (*set_values)(void* d, const float* values);
  int32_t (*note_on)(void* d, uint32_t origin, int32_t note, int32_t velocity, int chord);
  void (*note_off)(void* d, uint32_t origin);
  int32_t (*sustain)(void* d, uint32_t origin, int on);
  void (*expression)(void* d, int32_t kind, float value);
  void (*release_matching)(void* d, uint32_t mask, uint32_t value);
  int32_t (*held)(const void* d, uint32_t origin);
  void (*cut)(void* d);
  void (*set_voice_limit)(void* d, int32_t limit);
  int32_t (*fade_oldest)(void* d);
  void (*set_tempo)(void* d, float bpm);
  void (*render)(void* d, float* left, float* right, int32_t frames);
  int32_t (*active)(const void* d);
  int32_t (*fading)(const void* d);
  uint32_t (*stolen)(const void* d);
} le_inst_device;

/* The devices; entry i is LE_INST_DEVICE_DRIFT + i. */
#define LE_INST_DEVICE_COUNT 6
extern const le_inst_device le_inst_devices[LE_INST_DEVICE_COUNT];

/* The entry for `id`, or NULL when it names no device. */
const le_inst_device* le_inst_device_find(int32_t id);

#ifdef __cplusplus
}
#endif

#endif /* SEGNO_INSTRUMENT_DEVICES_H */
