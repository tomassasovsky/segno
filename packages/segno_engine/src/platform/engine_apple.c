/*
 * engine_apple.c — Apple (macOS / future iOS) implementation of the engine
 * platform seam (engine_platform.h).
 *
 * The only Apple-specific capability is reading per-channel Core Audio hardware
 * labels to exclude loopback inputs (le_platform_excluded_input_mask); the other
 * four seam hooks are no-ops. The whole file is wrapped in `#if defined(__APPLE__)`
 * so it compiles to a near-empty object on Linux/Windows — a dummy typedef in the
 * `#else` keeps the translation unit non-empty (an entirely #if'd-out TU is UB in
 * ISO C and warns under -Wempty-translation-unit / -pedantic).
 */
#if defined(__APPLE__)

#include <stdint.h>
#include <string.h>

/* Core Audio is used only to read per-channel hardware labels for loopback
 * exclusion. The frameworks are already linked by the macOS build. */
#include <CoreAudio/CoreAudio.h>
#include <CoreFoundation/CoreFoundation.h>

#include "engine_internal.h"  /* le_label_is_loopback */
#include "engine_platform.h"  /* the seam; le_engine / le_config / LE_MAX_CHANNELS
                               * arrive via engine_private.h + segno_engine_api.h */

/* Resolves the AudioDeviceID for `uid` (a Core Audio device UID string), or the
 * default input device when `uid` is NULL/empty. Returns kAudioObjectUnknown on
 * failure. */
static AudioObjectID le_macos_input_device(const char* uid) {
  if (uid != NULL && uid[0] != '\0') {
    CFStringRef cf = CFStringCreateWithCString(NULL, uid, kCFStringEncodingUTF8);
    if (cf == NULL) return kAudioObjectUnknown;
    AudioObjectID dev = kAudioObjectUnknown;
    AudioValueTranslation t = {&cf, sizeof(cf), &dev, sizeof(dev)};
    UInt32 size = sizeof(t);
    AudioObjectPropertyAddress addr = {
        kAudioHardwarePropertyDeviceForUID, kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain};
    const OSStatus st = AudioObjectGetPropertyData(
        kAudioObjectSystemObject, &addr, 0, NULL, &size, &t);
    CFRelease(cf);
    if (st == noErr && dev != kAudioObjectUnknown) return dev;
  }
  AudioObjectID dev = kAudioObjectUnknown;
  UInt32 size = sizeof(dev);
  AudioObjectPropertyAddress addr = {kAudioHardwarePropertyDefaultInputDevice,
                                     kAudioObjectPropertyScopeGlobal,
                                     kAudioObjectPropertyElementMain};
  if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &addr, 0, NULL, &size,
                                 &dev) != noErr) {
    return kAudioObjectUnknown;
  }
  return dev;
}

/* Builds a bitmask of input channels (0..channel_count-1) whose Core Audio
 * element name matches "loopback". Channels with no label are treated as
 * not-loopback. */
static uint32_t le_macos_excluded_mask(const char* uid, int channel_count) {
  const AudioObjectID dev = le_macos_input_device(uid);
  if (dev == kAudioObjectUnknown) return 0;
  uint32_t mask = 0;
  const int n = channel_count < LE_MAX_CHANNELS ? channel_count : LE_MAX_CHANNELS;
  for (int c = 0; c < n; ++c) {
    AudioObjectPropertyAddress addr = {kAudioObjectPropertyElementName,
                                       kAudioObjectPropertyScopeInput,
                                       (AudioObjectPropertyElement)(c + 1)};
    CFStringRef name = NULL;
    UInt32 size = sizeof(name);
    if (AudioObjectGetPropertyData(dev, &addr, 0, NULL, &size, &name) != noErr ||
        name == NULL) {
      continue;
    }
    char buf[256];
    if (CFStringGetCString(name, buf, sizeof(buf), kCFStringEncodingUTF8) &&
        le_label_is_loopback(buf)) {
      mask |= (1u << c);
    }
    CFRelease(name);
  }
  return mask;
}

/* ---- platform seam ---- */

uint32_t le_platform_excluded_input_mask(const char* uid, int channel_count) {
  return le_macos_excluded_mask(uid, channel_count);
}

void le_platform_device_id_to_str(const ma_device_id* id, char* out,
                                  size_t cap) {
  /* Core Audio device ids are NUL-terminated char strings. */
  if (cap == 0) return;
  strncpy(out, (const char*)id, cap - 1);
  out[cap - 1] = '\0';
}

void le_platform_backends(const ma_backend** out_list, ma_uint32* out_count) {
  /* macOS keeps miniaudio's default backend priority. */
  *out_list = NULL;
  *out_count = 0;
}

void le_platform_probe_backends(const ma_backend** out_list,
                                ma_uint32* out_count) {
  /* macOS has no backend to exclude from a probe — Core Audio is the only one. */
  *out_list = NULL;
  *out_count = 0;
}

void le_platform_set_alsa_only_for_test(int state) {
  /* No ALSA-only pin on macOS; the probe list is unconditional. */
  (void)state;
}

void le_platform_set_enum_libs_for_test(int jack_present, int pulse_present) {
  /* No libjack/libpulse probes on macOS; enumeration never routes on them. */
  (void)jack_present;
  (void)pulse_present;
}

int le_platform_enumerate_devices(le_device_info* out, int32_t max,
                                  int32_t* count, int capture) {
  /* Defer to miniaudio's Core Audio enumeration (already the right list). */
  (void)out;
  (void)max;
  (void)count;
  (void)capture;
  return 0;
}

void le_platform_before_context_init(const le_config* config) { (void)config; }

void le_platform_after_device_start(le_engine* engine, const le_config* config) {
  (void)engine;
  (void)config;
}

void le_platform_after_device_open(le_engine* engine) { (void)engine; }

/* The private wait-on-address calls libc++ builds std::atomic::wait on. */
extern int __ulock_wait(uint32_t operation, void* addr, uint64_t value,
                        uint32_t timeout_us);
extern int __ulock_wake(uint32_t operation, void* addr, uint64_t wake_value);
#define LE_UL_COMPARE_AND_WAIT 1u
#define LE_ULF_WAKE_ALL 0x00000100u

int le_platform_rt_audio(void) { return 0; }

int le_platform_fx_worker_setup(int32_t core, int rt) {
  (void)rt;
  /* No way to pin a thread to a core here; the desktop never asks. */
  return core < 0;
}

void le_platform_fx_wait(_Atomic uint32_t* word, uint32_t seen) {
  (void)__ulock_wait(LE_UL_COMPARE_AND_WAIT, (void*)word, seen, 0);
}

void le_platform_fx_wake(_Atomic uint32_t* word, int n) {
  if (n <= 0) return;
  (void)__ulock_wake(LE_UL_COMPARE_AND_WAIT | LE_ULF_WAKE_ALL, (void*)word, 0);
}

void le_platform_on_engine_teardown(void) {}

/* macOS is a development host: no PREEMPT_RT kernel to defend, and no fork
 * shield or memory lock to apply (rt_alloc.c maps buffers the same way). */
void le_platform_watch_forks(void) {}

unsigned le_platform_fork_count(void) { return 0; }

void le_platform_prefault_audio_code(void) {}

#else
typedef int segno_engine_apple_tu_unused; /* keep the TU non-empty off Apple */
#endif
