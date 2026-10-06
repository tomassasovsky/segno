#include "engine_read_head.h"
#include "../stretch/le_stretch.h" /* Transpose's source renders (#1179) */
#include "engine_cache.h" /* LE_CACHE_SOURCE_SEED / _FOLD_MS: the same render */
#include "engine_fade.h"
/*
 * perf_render.c — see perf_render.h.
 *
 * CONTROL-THREAD OWNERSHIP for le_perf_render_begin/poll/track_status/cancel
 * (the only callers touching `engine->perf.render`). Everything between
 * begin and done/cancel runs on the dedicated render worker thread this file
 * spawns; the worker never touches the audio callback, the command ring, or
 * any live engine state — it reads exclusively from the capture directory on
 * disk (see perf_render.h), so a render has no live-engine dependency at all
 * beyond the `engine*` handle used to reach `engine->perf.render` from the
 * control-thread API calls.
 *
 * Dry pass (part 7): a per-track stem is reconstructed as unity-gain loop
 * content — volume/mute are NOT baked into the stem's samples. They remain
 * expressed only in the arm/disarm snapshots + events.log, for the `.als`
 * generator (parts 9-10) to turn into mixer/track-activator automation on
 * top of this stem, the same way a real DAW workflow bounces a dry stem once
 * and then automates its fader rather than destructively baking gain changes
 * into the audio.
 *
 * Wet pass + master reconstruction (part 8): mirrors what the live engine's
 * mix_tracks_frame/master_bus_frame (engine_process.c) actually computed —
 * lane-0 volume/mute gate the dry content *before* the logged FX chain (the
 * live mix order: `wl = audible ? loopsample*vol : 0`, then fx_apply_chain),
 * summed across channels, then the master gain + feed-forward limiter. This
 * uses the engine's OWN fx_apply_chain/le_fx_prepare/le_fx_entry_reset
 * (engine_fx.h) rather than reimplementing per-effect DSP — a fresh, heap-
 * owned `le_fx_state` per channel, never touching any live engine state, so
 * the no-live-engine-dependency guarantee above still holds. A hosted
 * LE_FX_PLUGIN slot's `fx->plugin[slot]` stays NULL on this fresh state, so
 * fx_apply_chain already renders it as dry passthrough with no special-
 * casing here (fx_plugin_process's own documented NULL behavior) — the
 * chain data recorded in the manifest (already carrying each plugin entry's
 * `type`/`plugin` fields, part 6) is what part 10's `.als` generator reads to
 * surface the passthrough.
 */
#include "perf_render.h"

#include <errno.h>
#include <limits.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "engine_fx.h"       /* fx_apply_chain, le_fx_prepare, le_fx_entry_reset,
                              * le_fx_free_octaver — reused verbatim for the wet
                              * pass, not reimplemented */
#include "engine_private.h" /* le_engine, le_perf_capture, LE_MAX_TRACKS */
#include "json_read.h"
#include "segno_engine_api.h" /* le_command_code, le_command, LE_MAX_LANES */
#include "perf_log_ring.h"    /* le_perf_log_code */

#if defined(_WIN32)
#include <direct.h> /* _mkdir */
#include <windows.h>
#else
#include <pthread.h>
#include <sys/stat.h> /* mkdir */
#endif

/* ---- tuning ---- */
#define LE_PR_PATH_MAX 960
#define LE_PR_FULL_PATH_MAX (LE_PR_PATH_MAX + 64)
#define LE_PR_EVENTS_ENTRY_BYTES 28 /* matches perf_drain.c's on-disk layout,
                                    * docs/design/performance-event-log-format.md */
#define LE_PR_MAX_SEGMENTS 4096 /* per-track content-source transitions; a
                                * scripted-storm session could retire many
                                * layers, but a single performance realistically
                                * never approaches this */

/* ---- portable thread shim (mirrors perf_drain.c's own; duplicated per
 * translation unit rather than shared, matching this codebase's existing
 * one-file-branch-by-platform convention for background threads). ---- */
#if defined(_WIN32)
typedef HANDLE le_pr_thread_t;
static void le_pr_worker_main(void* arg);
static DWORD WINAPI le_pr_win_trampoline(LPVOID arg) {
  le_pr_worker_main(arg);
  return 0;
}
static int le_pr_thread_start(le_pr_thread_t* out, void* arg) {
  *out = CreateThread(NULL, 0, le_pr_win_trampoline, arg, 0, NULL);
  return *out != NULL;
}
static void le_pr_thread_join(le_pr_thread_t th) {
  WaitForSingleObject(th, INFINITE);
  CloseHandle(th);
}
static int le_pr_mkdir_one(const char* path) {
  if (path[0] == '\0') return 1;
  if (_mkdir(path) == 0) return 1;
  return errno == EEXIST;
}
#else
typedef pthread_t le_pr_thread_t;
static void le_pr_worker_main(void* arg);
static void* le_pr_posix_trampoline(void* arg) {
  le_pr_worker_main(arg);
  return NULL;
}
static int le_pr_thread_start(le_pr_thread_t* out, void* arg) {
  return pthread_create(out, NULL, le_pr_posix_trampoline, arg) == 0;
}
static void le_pr_thread_join(le_pr_thread_t th) { pthread_join(th, NULL); }
static int le_pr_mkdir_one(const char* path) {
  if (path[0] == '\0') return 1;
  if (mkdir(path, 0755) == 0) return 1;
  return errno == EEXIST;
}
#endif

static int le_pr_mkdir_recursive(const char* path) {
  char buf[LE_PR_PATH_MAX];
  snprintf(buf, sizeof(buf), "%s", path);
  size_t len = strlen(buf);
  while (len > 0 && (buf[len - 1] == '/' || buf[len - 1] == '\\')) {
    buf[--len] = '\0';
  }
  for (size_t i = 1; i < len; ++i) {
    if (buf[i] == '/' || buf[i] == '\\') {
      const char sep = buf[i];
      buf[i] = '\0';
      if (!le_pr_mkdir_one(buf)) return 0;
      buf[i] = sep;
    }
  }
  return le_pr_mkdir_one(buf);
}

/* ---- render session ---- */

typedef struct le_pr_track_result {
  _Atomic int32_t channel;
  _Atomic int32_t succeeded;
} le_pr_track_result;

struct le_perf_render {
  le_engine* engine;
  le_pr_thread_t thread;

  _Atomic int running; /* cleared by le_perf_render_cancel to end the loop
                        * early, between tracks */
  _Atomic int done;
  _Atomic int progress_pct;
  _Atomic int track_count; /* number of valid entries in results[] so far */
  _Atomic int32_t result;  /* terminal LE_* status, valid once done == 1 */

  le_pr_track_result results[LE_MAX_TRACKS];

  char capture_dir[LE_PR_PATH_MAX];
};

/* ---- minimal fixed-format WAV reader (this project's own WavCodec output
 * only: a 44-byte header, format code 3 = IEEE float, fmt chunk size 16, no
 * extra chunks before `data` — see packages/wav_codec/lib/src/wav.dart. Not a
 * general WAV parser. ---- */
static float* le_pr_read_wav_mono(const char* path, int32_t* out_frames) {
  *out_frames = 0;
  FILE* f = fopen(path, "rb");
  if (f == NULL) return NULL;
  unsigned char header[44];
  if (fread(header, 1, sizeof(header), f) != sizeof(header) ||
      memcmp(header, "RIFF", 4) != 0 || memcmp(header + 8, "WAVE", 4) != 0 ||
      memcmp(header + 12, "fmt ", 4) != 0 || memcmp(header + 36, "data", 4) != 0) {
    fclose(f);
    return NULL;
  }
  const uint16_t format = (uint16_t)(header[20] | (header[21] << 8));
  const uint16_t channels = (uint16_t)(header[22] | (header[23] << 8));
  const uint32_t data_bytes = (uint32_t)header[40] | ((uint32_t)header[41] << 8) |
                             ((uint32_t)header[42] << 16) |
                             ((uint32_t)header[43] << 24);
  if (format != 3 || channels == 0 || data_bytes == 0) {
    fclose(f);
    return NULL;
  }
  const int32_t total_samples = (int32_t)(data_bytes / sizeof(float));
  const int32_t frames = total_samples / channels;
  float* mono = (float*)malloc((size_t)frames * sizeof(float));
  if (mono == NULL) {
    fclose(f);
    return NULL;
  }
  /* This part renders lane-0 stems only (matching this codebase's existing
   * lane-0 export precedent elsewhere, e.g. session_repository); a mono
   * source reads straight through, a multi-channel one reads channel 0. */
  float* scratch = (float*)malloc((size_t)channels * sizeof(float));
  if (scratch == NULL) {
    free(mono);
    fclose(f);
    return NULL;
  }
  int ok = 1;
  for (int32_t i = 0; i < frames && ok; ++i) {
    if (fread(scratch, sizeof(float), (size_t)channels, f) !=
        (size_t)channels) {
      ok = 0;
      break;
    }
    mono[i] = scratch[0];
  }
  free(scratch);
  fclose(f);
  if (!ok) {
    free(mono);
    return NULL;
  }
  *out_frames = frames;
  return mono;
}

/* Reads a retired-layer raw PCM file (part 5: interleaved by lane, no
 * header) and returns lane 0's samples only, matching the lane-0-stem scope
 * above. */
static float* le_pr_read_layer_lane0(const char* path, int32_t frame_count,
                                     int32_t lane_count) {
  if (frame_count <= 0 || lane_count <= 0 || lane_count > LE_MAX_LANES ||
      (size_t)frame_count > SIZE_MAX / (sizeof(float) * (size_t)lane_count)) return NULL;
  FILE* f = fopen(path, "rb");
  if (f == NULL) return NULL;
  float* interleaved =
      (float*)malloc((size_t)frame_count * (size_t)lane_count * sizeof(float));
  if (interleaved == NULL) {
    fclose(f);
    return NULL;
  }
  const size_t want = (size_t)frame_count * (size_t)lane_count;
  const size_t got = fread(interleaved, sizeof(float), want, f);
  const int complete = got == want && fgetc(f) == EOF && !ferror(f);
  fclose(f);
  if (!complete) {
    free(interleaved);
    return NULL;
  }
  float* mono = (float*)malloc((size_t)frame_count * sizeof(float));
  if (mono == NULL) {
    free(interleaved);
    return NULL;
  }
  for (int32_t i = 0; i < frame_count; ++i) {
    mono[i] = interleaved[(size_t)i * (size_t)lane_count];
  }
  free(interleaved);
  return mono;
}

/* Encodes `samples` as a 32-bit float mono WAV at `sample_rate`, mirroring
 * wav_codec's own format (this codebase's only WAV writer besides that Dart
 * package — duplicated here so the native renderer needs no Dart round-trip
 * to produce its stems). */
static int le_pr_write_wav(const char* path, const float* samples,
                                int32_t frame_count, int32_t sample_rate, uint16_t channels) {
  FILE* f = fopen(path, "wb");
  if (f == NULL) return 0;
  const uint32_t data_bytes = (uint32_t)frame_count * channels * (uint32_t)sizeof(float);
  unsigned char header[44] = {0};
  memcpy(header + 0, "RIFF", 4);
  const uint32_t riff_size = 36 + data_bytes;
  memcpy(header + 4, &riff_size, 4);
  memcpy(header + 8, "WAVE", 4);
  memcpy(header + 12, "fmt ", 4);
  const uint32_t fmt_size = 16;
  memcpy(header + 16, &fmt_size, 4);
  const uint16_t format_code = 3; /* IEEE float */
  memcpy(header + 20, &format_code, 2);
  memcpy(header + 22, &channels, 2);
  const uint32_t sr = (uint32_t)sample_rate;
  memcpy(header + 24, &sr, 4);
  const uint32_t byte_rate = sr * channels * (uint32_t)sizeof(float);
  memcpy(header + 28, &byte_rate, 4);
  const uint16_t block_align = (uint16_t)(channels * sizeof(float));
  memcpy(header + 32, &block_align, 2);
  const uint16_t bits_per_sample = 32;
  memcpy(header + 34, &bits_per_sample, 2);
  memcpy(header + 36, "data", 4);
  memcpy(header + 40, &data_bytes, 4);

  int ok = fwrite(header, 1, sizeof(header), f) == sizeof(header);
  if (ok && frame_count > 0) {
    ok = fwrite(samples, sizeof(float), (size_t)frame_count * channels, f) ==
        (size_t)frame_count * channels;
  }
  fclose(f);
  return ok;
}

static int le_pr_write_wav_mono(const char* path, const float* samples,
                                int32_t frames, int32_t sr) {
  return le_pr_write_wav(path, samples, frames, sr, 1);
}

/* ---- performance.json access ---- */

typedef struct le_pr_manifest {
  int32_t sample_rate;
  uint64_t capture_frames;
  /* The PERF_ARMED transport fact (#262): the master loop phase at the exact
   * audio-thread frame the capture armed, read from events.log — NOT from the
   * race-stale armSnapshot.clockFrame the control thread sampled before lane
   * capture (that anchor was deleted, no fallback; events.log version 4).
   * `perf_arm_present` is 0 for a pre-4 capture with no such fact, and then the
   * arm image and the no-lock RECORD_END phase both fall to phase 0 — a pre-4
   * capture has no supported anchor. */
  int perf_arm_present;
  int32_t perf_arm_position;   /* master clock.position at the arm frame */
  int32_t perf_arm_master_len; /* master loop length at arm; 0 = no master */
  int32_t perf_arm_iteration;  /* loop_iteration at arm (multi-loop sub-cycle) */
  const le_json_value* arm_tracks;    /* armSnapshot.tracks array, or NULL */
  const le_json_value* disarm_tracks; /* disarmSnapshot.tracks array, or NULL */
  const le_json_value* layers;        /* layers array, or NULL */
  /* Retired images missing from the manifest: dropped once it filled
   * (`layers_dropped`) or refused at staging (`layer_overruns`). Only then
   * does an unlisted retire mean missing material (see the matcher). */
  int layers_dropped;
  /* Required capture policy: both taps follow selected output FX. Follow
   * additionally replays that bus's level/mute; neither includes hardware
   * Mono/Balance, global master gain, or limiter. */
  int32_t arm_follow_output;
  /* armSnapshot.captureBus (default 0) and its outputLevel / outputMuted at
   * arm, the replay's starting point under followOutput. */
  int32_t arm_capture_bus;
  float arm_output_level;
  int32_t arm_output_muted;
  uint32_t capture_mask;
  const le_json_value* arm_output;
  uint32_t output_enabled_mask;
} le_pr_manifest;

/* Loads and validates performance.json. Returns LE_OK, LE_ERR_INVALID for a
 * missing, short, unparseable or invalid manifest, or LE_ERR_DEVICE when the
 * worker cannot allocate. The parser arena is sized from the complete text:
 * every JSON value after the root follows a ':' (object member), a '['
 * (first array element) or a ',' (later element/member), so counting those
 * bytes bounds the node count without a second parser (punctuation inside
 * strings only overestimates). arena->nodes is owned by the caller even on
 * failure. */
static int32_t le_pr_load_manifest(const char* dir, char** out_text,
                                   le_json_arena* arena,
                                   le_json_value** out_root,
                                   le_pr_manifest* out) {
  char path[LE_PR_FULL_PATH_MAX];
  snprintf(path, sizeof(path), "%s/performance.json", dir);
  FILE* f = fopen(path, "rb");
  if (f == NULL) return LE_ERR_INVALID;
  long size = -1;
  if (fseek(f, 0, SEEK_END) == 0) size = ftell(f);
  /* json_read indexes the text with an int: keep it addressable. */
  if (size <= 0 || size >= INT_MAX ||
      fseek(f, 0, SEEK_SET) != 0) {
    fclose(f);
    return LE_ERR_INVALID;
  }
  char* text = (char*)malloc((size_t)size + 1);
  if (text == NULL) {
    fclose(f);
    return LE_ERR_DEVICE;
  }
  const size_t got = fread(text, 1, (size_t)size, f);
  fclose(f);
  if (got != (size_t)size) { /* a short read is not a complete manifest */
    free(text);
    return LE_ERR_INVALID;
  }
  text[got] = '\0';

  size_t nodes = 1;
  for (size_t i = 0; i < got; ++i) {
    nodes += text[i] == ':' || text[i] == ',' || text[i] == '[';
  }
  if (nodes > (size_t)INT_MAX || nodes > SIZE_MAX / sizeof(le_json_value)) {
    free(text);
    return LE_ERR_INVALID;
  }
  arena->nodes = (le_json_value*)malloc(nodes * sizeof(le_json_value));
  arena->capacity = (int)nodes;
  arena->used = 0;
  if (arena->nodes == NULL) {
    free(text);
    return LE_ERR_DEVICE;
  }

  le_json_value* root = le_json_parse(text, arena);
  if (root == NULL) {
    free(text);
    return LE_ERR_INVALID;
  }

  out->sample_rate = (int32_t)le_json_number(le_json_get(root, "sample_rate"), 0);
  out->capture_frames =
      (uint64_t)le_json_number(le_json_get(root, "capture_frames"), 0);
  const le_json_value* arm = le_json_get(root, "armSnapshot");
  const le_json_value* policy = le_json_get(arm, "followOutput");
  if (policy == NULL || policy->type != LE_JSON_BOOL) {
    free(text);
    return LE_ERR_INVALID;
  }
  /* The master phase anchor is NOT read from armSnapshot any more — the
   * PERF_ARMED fact in events.log supplies it (#262). le_pr_fill_perf_armed
   * populates perf_arm_* after the log is loaded. */
  out->arm_tracks = arm != NULL ? le_json_get(arm, "tracks") : NULL;
  const le_json_value* disarm = le_json_get(root, "disarmSnapshot");
  out->disarm_tracks = disarm != NULL ? le_json_get(disarm, "tracks") : NULL;
  out->layers = le_json_get(root, "layers");
  out->layers_dropped =
      le_json_number(le_json_get(root, "layers_dropped"), 0) > 0 ||
      le_json_number(le_json_get(root, "layer_overruns"), 0) > 0;
  out->arm_follow_output = policy->bool_value;
  const le_json_value* bus = le_json_get(arm, "captureBus");
  const double bus_number = le_json_number(bus, 0);
  if (bus != NULL && (bus->type != LE_JSON_NUMBER || !isfinite(bus_number) ||
      bus_number < 0 || bus_number >= LE_MAX_OUTPUT_BUSES ||
      floor(bus_number) != bus_number)) {
    free(text);
    return LE_ERR_INVALID;
  }
  out->arm_capture_bus = (int32_t)bus_number;
  const le_json_value* mask = le_json_get(arm, "captureMask");
  const double mask_number = le_json_number(mask, 0);
  if (mask == NULL || mask->type != LE_JSON_NUMBER || !isfinite(mask_number) ||
      mask_number < 1 || mask_number > UINT32_MAX ||
      floor(mask_number) != mask_number) {
    free(text);
    return LE_ERR_INVALID;
  }
  out->capture_mask = (uint32_t)mask_number;
  const uint32_t selected_pair = 3u << (2 * out->arm_capture_bus);
  if ((out->capture_mask & ~selected_pair) != 0) {
    free(text);
    return LE_ERR_INVALID;
  }
  const le_json_value* level = le_json_get(arm, "outputLevel");
  const double level_number = le_json_number(level, 1);
  const le_json_value* muted = le_json_get(arm, "outputMuted");
  const le_json_value* enabled = le_json_get(arm, "outputEnabledMask");
  const double enabled_number = le_json_number(enabled, UINT32_MAX);
  if ((level != NULL && (level->type != LE_JSON_NUMBER ||
        !isfinite(level_number) || level_number < 0 || level_number > 1)) ||
      (muted != NULL && muted->type != LE_JSON_BOOL) ||
      (enabled != NULL && (enabled->type != LE_JSON_NUMBER ||
        !isfinite(enabled_number) || enabled_number < 0 ||
        enabled_number > UINT32_MAX || floor(enabled_number) != enabled_number))) {
    free(text);
    return LE_ERR_INVALID;
  }
  out->arm_output_level = (float)level_number;
  out->arm_output_muted = le_json_bool(muted, 0);
  out->output_enabled_mask = (uint32_t)enabled_number;
  out->arm_output = arm;
  *out_text = text;
  *out_root = root;
  return LE_OK;
}

/* Finds channel `channel`'s track entry within a `tracks` array (either
 * armSnapshot's or disarmSnapshot's), or NULL if the channel is absent. The
 * wet pass needs the track-level `volume`/`muted` fields this returns
 * directly, alongside the lane-0 lookup below (which shares this scan). */
static const le_json_value* le_pr_find_track(const le_json_value* tracks,
                                             int32_t channel) {
  if (tracks == NULL) return NULL;
  const int n = le_json_length(tracks);
  for (int i = 0; i < n; ++i) {
    const le_json_value* track = le_json_at(tracks, i);
    if ((int32_t)le_json_number(le_json_get(track, "channel"), -1) == channel) {
      return track;
    }
  }
  return NULL;
}

/* Finds channel `channel`'s lane-0 entry within a `tracks` array, or NULL if
 * the channel is absent or has no lane 0. */
static const le_json_value* le_pr_find_lane0(const le_json_value* tracks,
                                             int32_t channel) {
  const le_json_value* track = le_pr_find_track(tracks, channel);
  if (track == NULL) return NULL;
  const le_json_value* lanes = le_json_get(track, "lanes");
  const int lane_n = le_json_length(lanes);
  for (int l = 0; l < lane_n; ++l) {
    const le_json_value* lane = le_json_at(lanes, l);
    if ((int32_t)le_json_number(le_json_get(lane, "lane"), -1) == 0) {
      return lane;
    }
  }
  return NULL;
}

typedef struct le_pr_log_entry {
  uint64_t frame;
  int ordinal; /* file order preserves same-frame callback command ordering */
  le_log_command cmd;
} le_pr_log_entry;

/* Snapshot material and callback-confirmed restored material both own stems,
 * including a restore that was cleared again before the disarm snapshot. */
static int le_pr_collect_channels(const le_pr_manifest* m,
                                  const le_pr_log_entry* log, int log_count,
                                  int32_t* out, int cap) {
  int n = 0;
  for (int pass = 0; pass < 2; ++pass) {
    const le_json_value* tracks = pass == 0 ? m->arm_tracks : m->disarm_tracks;
    const int count = le_json_length(tracks);
    for (int i = 0; i < count && n < cap; ++i) {
      const le_json_value* track = le_json_at(tracks, i);
      char state[16];
      if (pass == 0 && le_json_string(le_json_get(track, "state"), state, sizeof(state)) &&
          strcmp(state, "empty") == 0) continue; /* metadata, until an applied source */
      const int32_t channel =
          (int32_t)le_json_number(le_json_get(track, "channel"), -1);
      if (channel < 0 || channel >= LE_MAX_TRACKS) continue;
      int seen = 0;
      for (int k = 0; k < n; ++k) {
        if (out[k] == channel) {
          seen = 1;
          break;
        }
      }
      if (!seen) out[n++] = channel;
    }
  }
  for (int i = 0; i < log_count && n < cap; ++i) {
    if (log[i].cmd.code != LE_PLOG_SOURCE_APPLIED &&
        log[i].cmd.code != LE_PLOG_SOURCE_TRANSPORT) continue;
    const int32_t channel = log[i].cmd.restore_log.channel;
    if (channel < 0 || channel >= LE_MAX_TRACKS) continue;
    int seen = 0;
    for (int k = 0; k < n; ++k) if (out[k] == channel) seen = 1;
    if (!seen) out[n++] = channel;
  }
  return n;
}

/* ---- events.log access ---- */



static int le_pr_frame_cmp(const void* a, const void* b) {
  const le_pr_log_entry* ea = (const le_pr_log_entry*)a;
  const le_pr_log_entry* eb = (const le_pr_log_entry*)b;
  if (ea->frame < eb->frame) return -1;
  if (ea->frame > eb->frame) return 1;
  return (ea->ordinal > eb->ordinal) - (ea->ordinal < eb->ordinal);
}

/* Loads and frame-sorts every entry in events.log. Returns the entry count
 * (0 if the file is missing/empty/unreadable — a render with no log is
 * still valid, it just has no stitching transitions beyond the snapshots
 * themselves) and sets *out_entries (caller frees). */
static int le_pr_load_log(const char* dir, le_pr_log_entry** out_entries) {
  *out_entries = NULL;
  char path[LE_PR_FULL_PATH_MAX];
  snprintf(path, sizeof(path), "%s/events.log", dir);
  FILE* f = fopen(path, "rb");
  if (f == NULL) return 0;

  unsigned char header[12];
  if (fread(header, 1, sizeof(header), f) != sizeof(header) ||
      memcmp(header, "PLEV", 4) != 0) {
    fclose(f);
    return 0;
  }

  fseek(f, 0, SEEK_END);
  const long size = ftell(f);
  fseek(f, sizeof(header), SEEK_SET);
  if (size < (long)sizeof(header)) {
    fclose(f);
    return 0;
  }
  const long body_bytes = size - (long)sizeof(header);
  const int max_entries = (int)(body_bytes / LE_PR_EVENTS_ENTRY_BYTES);
  if (max_entries <= 0) {
    fclose(f);
    return 0;
  }

  le_pr_log_entry* entries =
      (le_pr_log_entry*)malloc((size_t)max_entries * sizeof(le_pr_log_entry));
  if (entries == NULL) {
    fclose(f);
    return 0;
  }

  int n = 0;
  unsigned char raw[LE_PR_EVENTS_ENTRY_BYTES];
  while (n < max_entries &&
        fread(raw, 1, LE_PR_EVENTS_ENTRY_BYTES, f) == LE_PR_EVENTS_ENTRY_BYTES) {
    le_pr_log_entry* e = &entries[n++];
    e->ordinal = n - 1;
    memcpy(&e->frame, raw, 8);
    memcpy(&e->cmd.code, raw + 8, 4);
    /* The 16-byte union payload, copied as a block rather than per-arm: every
     * arm is plain 4-byte-aligned int32_t/float/uint32_t fields with no
     * internal padding (see docs/design/performance-event-log-format.md), so
     * this is equivalent to memcpy-ing whichever specific arm the entry's
     * `code` actually uses. */
    memcpy(((unsigned char*)&e->cmd) + 4, raw + 12, 16);
  }
  fclose(f);

  qsort(entries, (size_t)n, sizeof(le_pr_log_entry), le_pr_frame_cmp);
  *out_entries = entries;
  return n;
}

/* Populates the manifest's perf_arm_* master-phase anchor from the single
 * LE_PLOG_PERF_ARMED fact in the log (#262, events.log version 4). Leaves
 * perf_arm_present at 0 for a pre-4 capture with no such fact — the arm image
 * and no-lock RECORD_END phase then fall to phase 0 (a pre-4 capture has no
 * supported anchor; the old race-stale armSnapshot.clockFrame was deleted with
 * no fallback, AGENTS.md). Exactly one fact is expected, but the first wins
 * defensively. */
static void le_pr_fill_perf_armed(const le_pr_log_entry* log, int log_count,
                                  le_pr_manifest* m) {
  m->perf_arm_present = 0;
  m->perf_arm_position = 0;
  m->perf_arm_master_len = 0;
  m->perf_arm_iteration = 0;
  for (int i = 0; i < log_count; ++i) {
    if (log[i].cmd.code == LE_PLOG_PERF_ARMED) {
      m->perf_arm_present = 1;
      m->perf_arm_position = log[i].cmd.perf_arm.position;
      m->perf_arm_master_len = log[i].cmd.perf_arm.master_len;
      m->perf_arm_iteration = log[i].cmd.perf_arm.iteration;
      return;
    }
  }
}

/* Resolve the typed image once. Duplicate or missing identity is corruption,
 * not an invitation to substitute the arm image or a recycled layer slot. */
static float* le_pr_restore_image(const char* dir, const le_pr_manifest* m,
                                  int channel, uint32_t id, int32_t* len) {
  const le_json_value* found = NULL;
  if (!id) return NULL;
  for (int i = 0; i < le_json_length(m->layers); ++i) {
    const le_json_value* v = le_json_at(m->layers, i);
    if (le_json_number(le_json_get(v, "kind"), 0) != 1 ||
        le_json_number(le_json_get(v, "channel"), -1) != channel ||
        le_json_number(le_json_get(v, "restore_id"), 0) != id) continue;
    if (found) return NULL;
    found = v;
  }
  if (!found) return NULL;
  const double frames = le_json_number(le_json_get(found, "frame_count"), 0);
  const double lanes = le_json_number(le_json_get(found, "lane_count"), 0);
  if (frames <= 0 || frames > INT32_MAX || frames != floor(frames) ||
      lanes < 1 || lanes > LE_MAX_LANES || lanes != floor(lanes)) return NULL;
  char filename[64], path[LE_PR_FULL_PATH_MAX];
  if (!le_json_string(le_json_get(found, "filename"), filename, sizeof(filename))) return NULL;
  snprintf(path, sizeof(path), "%s/%s", dir, filename);
  *len = (int32_t)frames;
  return le_pr_read_layer_lane0(path, *len, (int32_t)lanes);
}

/* ---- per-track segment reconstruction ---- */

typedef struct le_pr_segment {
  int owns_image, silent;
  uint64_t start_frame;
  double phase0;     /* loop position (image index) the segment plays from at
                      * start_frame — stems are PHASE-LOCKED to what the
                      * performer heard (#255): a layer image is loop-position-
                      * indexed (buffer index == loop position), and the loop's
                      * phase runs as a continuous counter between the LOGGED
                      * transport facts that reset it (LOOP_LENGTH_LOCKED at a
                      * master finalize), so a segment activating at loop phase
                      * p must keep playing from image[p], not restart at
                      * image[0]. A mid-capture transport hold (nothing playing
                      * or recording) pins the live clock's position to 0, and
                      * that reset is now LOGGED as LE_PLOG_TRANSPORT_HELD
                      * (#262, engine_process.c's all-idle branch) rather than
                      * being an unreconstructable residual — and the multi-loop
                      * sub-cycle the PERF_ARMED fact's iteration field resolves
                      * (#260). */
  float* image;      /* owned; NULL = silence */
  int32_t image_len; /* loop period in frames; meaningless if image is NULL */
  /* Read head (#1162 direction, #1179 rate; engine_read_head.h, the
   * callback's own arithmetic): phase0 is the index read at start_frame, and
   * the index then steps `rate` per frame, forward or reversed. A segment
   * appended by a direction or rate fact also mixes the pre-turn head for
   * turn_frames frames: `turn` is that head, its origin set so it reads the
   * pre-turn index at start_frame. Direction is inherited by every later
   * segment of the same material (a new take and an emptying read forward);
   * the rate is the global Speed's, inherited throughout. */
  int reversed;
  double rate;
  int32_t turn_frames;
  int32_t turn_into0; /* frames of the window already mixed at start_frame */
  le_read_head turn;
  /* Transpose (#1179 Part 3a, LE_PLOG_TRANSPOSE): `src` is the source the
   * head reads — the image's pitch-shifted render, or NULL for the image
   * itself — owned by the segment that rendered it (`owns_src`) and borrowed
   * by every later one until the next fact, as the callback keeps reading
   * the render it selected until its next verdict. A swap mixes `turn_src`
   * out with the equal-power law (`turn_power`). */
  float* src;
  int owns_src;
  const float* turn_src;
  int turn_power;
  /* The renders' lengths (#1179 Part 4a-ii, LE_PLOG_SOURCE_LEN): a stretch
   * render is not the image's length and is read mapped
   * (le_head_read_scaled); 0 = the image's. */
  int32_t src_len, turn_src_len;
} le_pr_segment;

/* The head segment `seg` reads through, its origin anchored at start_frame. */
static le_read_head le_pr_segment_head(const le_pr_segment* seg) {
  le_read_head h = {seg->reversed, 0.0, seg->rate};
  h.origin = le_head_origin(&h, seg->phase0, 0, seg->image_len);
  return h;
}

/* The image index segment `seg` reads at capture frame `f` (>= start_frame). */
static double le_pr_segment_index(const le_pr_segment* seg, uint64_t f) {
  const le_read_head h = le_pr_segment_head(seg);
  return le_head_index(&h, (int64_t)(f - seg->start_frame), seg->image_len);
}

typedef struct le_pr_track_build {
  le_pr_segment segments[LE_PR_MAX_SEGMENTS];
  int segment_count;
  /* The channel's Speed from its last LE_PLOG_SPEED (#1179) and the span
   * its take plays over from its last LE_PLOG_HEAD_SPAN (Part 4a, 0 = the
   * take's own): a segment reads at le_head_rate of them and its image. */
  int32_t numer, denom, play_len;
  int32_t next_src_len; /* the last LE_PLOG_SOURCE_LEN, for the next 328 */
  int load_failed; /* 1 if a pcmRef/layer file this track's manifest entries
                    * NAME could not actually be read — the per-stem failure
                    * the "partial success" acceptance criterion means. A
                    * genuinely contentless channel (nothing in either
                    * snapshot at all) is NOT a failure — le_pr_collect_
                    * channels never even calls this function for one. */
} le_pr_track_build;

/* The rate a segment over an image of `image_len` frames reads at: the
 * callback's le_track_rate over the logged Speed and span. */
static double le_pr_rate(const le_pr_track_build* b, int32_t image_len) {
  return le_head_rate(b->numer, b->denom, image_len, b->play_len);
}

static void le_pr_append_segment(le_pr_track_build* b, uint64_t start_frame,
                                 double phase0, float* image,
                                 int32_t image_len) {
  if (b->segment_count >= LE_PR_MAX_SEGMENTS) {
    free(image);
    b->load_failed = 1; /* never report a successful truncated reconstruction */
    return;
  }
  /* A later transition can only ever move forward in time; if two events
   * land on the exact same frame, the later one (processed later, since the
   * log is frame-sorted) simply supersedes the earlier by starting at the
   * same instant — le_pr_render_track's lookup (last segment with
   * start_frame <= f) already resolves that correctly without special-casing
   * it here. */
  /* Direction is a property of the material (#1162): a segment inherits the
   * previous one's, and only a direction fact, a new take or an emptying
   * changes it (their call sites set the field after this append). */
  const int reversed =
      b->segment_count > 0 ? b->segments[b->segment_count - 1].reversed : 0;
  float* const src =
      b->segment_count > 0 ? b->segments[b->segment_count - 1].src : NULL;
  const int32_t src_len =
      b->segment_count > 0 ? b->segments[b->segment_count - 1].src_len : 0;
  le_pr_segment* seg = &b->segments[b->segment_count++];
  seg->owns_image = 1;
  seg->silent = 0;
  seg->start_frame = start_frame;
  seg->phase0 = image_len > 0 ? le_head_wrap(phase0, image_len) : 0.0;
  seg->image = image;
  seg->image_len = image_len;
  seg->reversed = reversed;
  seg->rate = le_pr_rate(b, image_len);
  seg->turn_frames = 0;
  seg->turn_into0 = 0;
  seg->turn = (le_read_head){0, 0.0, 1.0};
  seg->src = src;
  seg->owns_src = 0;
  seg->turn_src = NULL;
  seg->turn_power = 0;
  seg->src_len = src_len;
  seg->turn_src_len = 0;
}

/* The loop phase (image index) the CURRENT last segment would play at
 * `frame` — the loop-position counter a new segment activating at `frame`
 * must inherit to stay phase-locked with live playback (#255), stepped in
 * that segment's direction (#1162). A build whose last segment is silence
 * (baseline, or post-CLEAR) has no phase to carry: the next content supplies
 * its own anchor (the arm image's PERF_ARMED phase, or a RECORD_END's track
 * epoch — le_pr_record_end_phase below). */
static double le_pr_build_phase_at(const le_pr_track_build* b,
                                   uint64_t frame) {
  if (b->segment_count == 0) return 0;
  const le_pr_segment* seg = &b->segments[b->segment_count - 1];
  if (seg->image == NULL || seg->image_len <= 0) return 0;
  return le_pr_segment_index(seg, frame);
}

/* The exact index for a fact that logs an integral one (322/323 phases,
 * 324's read_index): at a rate other than 1 the callback's index can be
 * fractional (#1179), so the continuing head's own index is kept when its
 * integral part is the logged one; otherwise, and always at rate 1 (where
 * the two agree exactly), the logged index. */
static double le_pr_anchor(const le_pr_track_build* b, uint64_t frame,
                           int32_t logged) {
  const double c = le_pr_build_phase_at(b, frame);
  return (int32_t)c == logged ? c : (double)logged;
}

/* Re-anchors the material at `index` (exact) with a new head, mixing the
 * pre-change head out over `turn_frames` (a direction or rate fact). A fact on
 * silence has nothing to read: the next content supplies its own anchor. A
 * source swap (`swap`) always starts its own window, as the callback's
 * le_transpose_select does; a head change inside a window carries it. */
static void le_pr_reanchor(le_pr_track_build* b, uint64_t frame, int reversed,
                           double index, int32_t turn_frames, int swap) {
  if (b->segment_count == 0) return;
  const le_pr_segment* last = &b->segments[b->segment_count - 1];
  if (last->image == NULL || last->image_len <= 0) return;
  double old_index = le_pr_build_phase_at(b, frame);
  le_read_head old = {last->reversed, 0.0, last->rate};
  const int silent = last->silent;
  float* image = last->image;
  const int32_t image_len = last->image_len;
  /* A change inside a window still mixing (the callback's le_turn_begin)
   * keeps that window and the head it fades out. */
  const int64_t into0 =
      (int64_t)(frame - last->start_frame) + last->turn_into0;
  const int carry = !swap && turn_frames > 0 && last->turn_frames > 0 &&
                    into0 < last->turn_frames;
  const float* carried_src = last->turn_src;
  const int32_t carried_src_len = last->turn_src_len;
  const int carried_power = last->turn_power;
  if (carry) {
    old = last->turn;
    old_index = le_head_index(&last->turn,
                              (int64_t)(frame - last->start_frame), image_len);
    turn_frames = last->turn_frames;
  }
  old.origin = le_head_origin(&old, old_index, 0, image_len);
  /* The image stays owned by the segment that loaded it: hand the append no
   * image, so a full segment table frees nothing here, and borrow it after,
   * as the restored-image path does. */
  le_pr_append_segment(b, frame, 0, NULL, 0);
  if (b->load_failed) return;
  le_pr_segment* seg = &b->segments[b->segment_count - 1];
  seg->owns_image = 0;
  seg->image = image;
  seg->image_len = image_len;
  seg->rate = le_pr_rate(b, image_len);
  seg->phase0 = le_head_wrap(index, image_len);
  seg->silent = silent;
  seg->reversed = reversed;
  seg->turn_frames = turn_frames;
  seg->turn_into0 = carry ? (int32_t)into0 : 0;
  seg->turn = old;
  /* the old head reads the source it read (a carried window's own) */
  seg->turn_src = carry ? carried_src : seg->src;
  seg->turn_src_len = carry ? carried_src_len : seg->src_len;
  seg->turn_power = carry ? carried_power : 0;
}

/* A direction fact (LE_PLOG_REVERSE, #1162) on this channel. A toggle or
 * install re-anchors the material at the exact index the callback logged and
 * carries the turn the callback mixed, so the stem reproduces the live turn
 * sample-exactly; a reset (read_index < 0) returns a reversed track to
 * forward from its continuation phase. A fact on silence has nothing to
 * read and is ignored: the next content supplies its own direction. */
static void le_pr_apply_direction(le_pr_track_build* b, uint64_t frame,
                                  int reversed, int32_t read_index,
                                  int32_t turn_frames) {
  if (b->segment_count == 0) return;
  const le_pr_segment* last = &b->segments[b->segment_count - 1];
  if (last->image == NULL || last->image_len <= 0) return;
  if (read_index < 0) {
    if (!last->reversed) return;
    le_pr_reanchor(b, frame, 0, le_pr_build_phase_at(b, frame), 0, 0);
    return;
  }
  le_pr_reanchor(b, frame, reversed, le_pr_anchor(b, frame, read_index),
                 turn_frames, 0);
}

/* A sounding-pitch fact (LE_PLOG_TRANSPOSE, #1179 Part 3a): the material
 * re-anchors at the logged index and reads a render of its image through the
 * same function, preset, seed and cyclic padding as the cache worker (or the
 * image itself at 0), the old source mixed out with the equal-power law.
 * Returns 0 when the render fails, which fails the stem. */
static int le_pr_apply_transpose(le_pr_track_build* b, uint64_t frame,
                                 const le_log_command* cmd,
                                 int32_t sample_rate) {
  if (b->segment_count == 0) return 1;
  const le_pr_segment* last = &b->segments[b->segment_count - 1];
  if (last->image == NULL || last->image_len <= 0) return 1;
  float* rendered = NULL;
  const int32_t st = cmd->transpose_log.effective;
  const int32_t out_len =
      b->next_src_len > 0 ? b->next_src_len : last->image_len;
  b->next_src_len = 0;
  if (st != 0 || out_len != last->image_len) {
    rendered = (float*)malloc((size_t)out_len * sizeof(float));
    if (rendered == NULL ||
        le_stretch_render_loop(last->image, last->image_len,
                               out_len, sample_rate,
                               (float)st, 8000.0f / (float)sample_rate, 1,
                               LE_CACHE_SOURCE_SEED,
                               sample_rate * LE_CACHE_SOURCE_FOLD_MS / 1000,
                               rendered) != LE_STRETCH_OK) {
      free(rendered);
      return 0;
    }
  }
  const uint64_t q = (uint64_t)cmd->transpose_log.index_lo |
                     ((uint64_t)cmd->transpose_log.index_hi << 32);
  le_pr_reanchor(b, frame, last->reversed, le_head_index_from_q32(q),
                 cmd->transpose_log.turn_frames, 1);
  if (b->load_failed) {
    free(rendered);
    return 1;
  }
  le_pr_segment* seg = &b->segments[b->segment_count - 1];
  seg->src = rendered;
  seg->owns_src = rendered != NULL;
  seg->src_len = rendered != NULL ? out_len : 0;
  seg->turn_power = 1;
  return 1;
}

/* A rate fact (LE_PLOG_SPEED, #1179) on this channel: later segments read at
 * the new rate, and content re-anchors at the exact Q32.32 index the
 * callback logged, mixing the old head out over its turn window. */
static void le_pr_apply_speed(le_pr_track_build* b, uint64_t frame,
                              const le_log_command* cmd) {
  b->numer = cmd->speed_log.numer;
  b->denom = cmd->speed_log.denom;
  if (b->segment_count == 0) return;
  const le_pr_segment* last = &b->segments[b->segment_count - 1];
  const uint64_t q = (uint64_t)cmd->speed_log.index_lo |
                     ((uint64_t)cmd->speed_log.index_hi << 32);
  le_pr_reanchor(b, frame, last->reversed, le_head_index_from_q32(q),
                 cmd->speed_log.turn_frames, 0);
}

/* A span fact (LE_PLOG_HEAD_SPAN, #1179 Part 4a) on this channel: later
 * segments read at speed * image length / span, and content re-anchors at
 * the exact index the callback logged, a window still mixing carried. */
static void le_pr_apply_span(le_pr_track_build* b, uint64_t frame,
                             const le_log_command* cmd) {
  b->play_len = cmd->span_log.play_len;
  if (b->segment_count == 0) return;
  const le_pr_segment* last = &b->segments[b->segment_count - 1];
  const uint64_t q = (uint64_t)cmd->span_log.index_lo |
                     ((uint64_t)cmd->span_log.index_hi << 32);
  le_pr_reanchor(b, frame, last->reversed, le_head_index_from_q32(q),
                 cmd->span_log.turn_frames, 0);
}

/* The latest LE_PLOG_LOOP_LENGTH_LOCKED at or before `frame` (INCLUSIVE, so
 * a same-frame tie with the finalize that pushed the lock resolves correctly
 * regardless of how qsort ordered it). The lock is pushed at the exact frame
 * the master loop length is (re)established AND the loop clock's position
 * resets to 0 (finalize_master -> le_loop_clock_set_length,
 * engine_process.c); its arg_i carries the locked base length. */
static int le_pr_find_lock(const le_pr_log_entry* log, int log_count,
                           uint64_t frame, uint64_t* out_frame,
                           int32_t* out_base, int32_t* out_pos) {
  int found = 0;
  for (int i = 0; i < log_count && log[i].frame <= frame; ++i) {
    if (log[i].cmd.code == LE_PLOG_LOOP_LENGTH_LOCKED) {
      *out_frame = log[i].frame;
      *out_base = log[i].cmd.arg_i;
      *out_pos = 0;
      found = 1;
    } else if (log[i].cmd.code == LE_PLOG_RETIME) {
      /* A retime (#1179 Part 4a) re-lengths the running clock, which goes
       * on from the logged position instead of the top. */
      *out_frame = log[i].frame;
      *out_base = log[i].cmd.retime_log.length;
      *out_pos = log[i].cmd.retime_log.position;
      found = 2;
    }
  }
  return found;
}

/* This channel's latest LE_PLOG_RECORD_START at or before `end_frame` — the
 * frame its finalized take actually began capturing (engine_process.c logs
 * it at the exact press/trigger frame). Falls back to `end_frame` itself
 * when none is logged (a defensive degenerate: zero-length take epoch). */
static uint64_t le_pr_find_record_start(const le_pr_log_entry* log,
                                        int log_count, int32_t channel,
                                        uint64_t end_frame) {
  uint64_t start = end_frame;
  for (int i = 0; i < log_count && log[i].frame <= end_frame; ++i) {
    if (log[i].cmd.code == LE_PLOG_RECORD_START &&
        log[i].cmd.arg_i == channel) {
      start = log[i].frame;
    }
  }
  return start;
}

/* The loop phase a RECORD_END segment (channel's fresh take finalized at
 * `end_frame`, image length `image_len` frames) starts playing from — the
 * TRACK's epoch, anchored at its own RECORD_START (#255 re-review):
 *
 *   phase0 = (master_pos_at(start_frame) + (end_frame - start_frame))
 *            % image_len
 *
 * A fresh take's buffer is written phase-locked from the master position at
 * the RECORD_START frame (`record_pos` seeds to `clock.position`,
 * engine_process.c) and the write head then runs CONTINUOUSLY to the
 * finalize; live playback likewise indexes ((loop_iteration - start_iter) %
 * k) * base + position with start_iter fixed at the record start. For a
 * multi-loop take (k > 1, image_len == k * base) the track's epoch and the
 * master lock's epoch agree modulo base but diverge in the sub-cycle
 * whenever start_iter % k != 0 — so the master position at the START is
 * computed modulo the locked BASE length (the lock's own arg_i, never
 * image_len), and only the start->end run is reduced modulo image_len.
 *
 * The exception is a take the master lock landed INSIDE of (lock_frame >=
 * start_frame): that take (re)defined the master, and the lock IS the clock
 * reset — finalize_master logs it at the same frame as the RECORD_END
 * (phase 0), and a crossfade-deferred finalize (finalize_master_xfade)
 * resets the clock at the lock frame too, F captured seam frames after the
 * press — so the anchor there is the lock, never the record start. A
 * hand-off lock landing exactly ON this take's RECORD_START yields the same
 * answer either way (the position was 0 right there).
 *
 * With no lock inside the capture at all, the master was locked before arm
 * and the PERF_ARMED fact (perf_arm_position/perf_arm_master_len) anchors
 * capture frame 0 instead — the exact frame the master phase held when
 * LE_CMD_PERF_ARM applied, logged by the audio thread (#262), not the
 * race-stale armSnapshot.clockFrame that anchor used to read. */
static uint64_t le_pr_record_end_phase(const le_pr_manifest* m,
                                       const le_pr_log_entry* log,
                                       int log_count, int32_t channel,
                                       uint64_t end_frame, int32_t image_len) {
  if (image_len <= 0) return 0;
  const uint64_t start_frame =
      le_pr_find_record_start(log, log_count, channel, end_frame);
  uint64_t lock_frame = 0;
  int32_t lock_base = 0, lock_pos = 0;
  const int has_lock = le_pr_find_lock(log, log_count, end_frame, &lock_frame,
                                       &lock_base, &lock_pos);
  /* A retime never lands inside a capture (the callback refuses it then). */
  if (has_lock == 1 && lock_frame >= start_frame) {
    return (end_frame - lock_frame) % (uint64_t)image_len;
  }
  uint64_t start_pos = 0;
  if (has_lock && lock_base > 0) {
    start_pos = ((uint64_t)lock_pos + (start_frame - lock_frame)) %
                (uint64_t)lock_base;
  } else if (!has_lock && m->perf_arm_present && m->perf_arm_master_len > 0) {
    start_pos = ((uint64_t)m->perf_arm_position + start_frame) %
                (uint64_t)m->perf_arm_master_len;
  }
  return (start_pos + (end_frame - start_frame)) % (uint64_t)image_len;
}

/* Renders channel `channel`'s full-length dry stem into a freshly malloc'd
 * buffer of `capture_frames` samples (caller frees), or NULL with
 * `*out_failed` set if a pcmRef/layer file this channel's manifest entries
 * actually name could not be read (the per-stem "partial success" failure
 * this part's acceptance criteria describe) or the stem buffer itself could
 * not be allocated. Channels can come from either snapshot or an applied restoration fact. */
static float* le_pr_render_track(const char* dir, const le_pr_manifest* m,
                                 const le_pr_log_entry* log, int log_count,
                                 int32_t channel, int32_t* out_failed) {
  *out_failed = 0;
  le_pr_track_build build = {0};
  build.numer = 1;
  build.denom = 1;
  build.play_len = 0;
  build.next_src_len = 0;
  /* A baseline silence segment at frame 0 always exists first — even a
   * track absent from armSnapshot entirely (recorded fresh later, or
   * mid-overdub/deferred at arm) needs SOMETHING covering [0, first real
   * transition), or the render loop below would find zero segments whose
   * start_frame <= an early frame and underflow the unsigned frame math.
   * A real arm-time image, when present, simply appends its own segment
   * right after this one at the same frame 0 (superseding it immediately —
   * see le_pr_append_segment's "later transition supersedes" note). */
  le_pr_append_segment(&build, 0, 0, NULL, 0);

  /* An arm-image segment anchors at the master loop phase the PERF_ARMED fact
   * recorded (#262): the exact clock.position (within loop_iteration) the
   * audio thread held when LE_CMD_PERF_ARM applied — capture frame 0. For a
   * multi-loop arm image (image_len > master_len) the sub-cycle matters, so
   * the phase is the absolute master frame `iteration * master_len + position`
   * reduced modulo image_len by le_pr_append_segment (#260). This REPLACES the
   * race-stale armSnapshot.clockFrame the control thread sampled before lane
   * capture and manifest I/O — deleted with no fallback (events.log v4). The
   * mid-cycle layer-retire rotation (#255) shared this "segment restarts its
   * image at index 0" root cause. A pre-4 capture has no fact and anchors at
   * phase 0 — unsupported, per the version bump. */
  const le_json_value* arm_lane = le_pr_find_lane0(m->arm_tracks, channel);
  if (arm_lane != NULL &&
      le_json_bool(le_json_get(arm_lane, "deferred"), 0) == 0) {
    const le_json_value* pcm_ref_value = le_json_get(arm_lane, "pcmRef");
    char pcm_ref[128];
    if (pcm_ref_value != NULL) {
      if (le_json_string(pcm_ref_value, pcm_ref, sizeof(pcm_ref))) {
        char path[LE_PR_FULL_PATH_MAX];
        snprintf(path, sizeof(path), "%s/%s", dir, pcm_ref);
        int32_t frames = 0;
        float* image = le_pr_read_wav_mono(path, &frames);
        if (image != NULL) {
          const uint64_t arm_phase =
              m->perf_arm_present
                  ? (uint64_t)m->perf_arm_iteration *
                            (uint64_t)m->perf_arm_master_len +
                        (uint64_t)m->perf_arm_position
                  : 0;
          le_pr_append_segment(&build, 0, arm_phase, image, frames);
        } else {
          build.load_failed = 1;
        }
      } else {
        /* A `pcmRef` key exists but couldn't be extracted (e.g. a value
         * longer than this buffer, or a non-string) — a real data-integrity
         * problem, not "no content here": surface it as a per-stem failure
         * rather than silently treating it as absent. */
        build.load_failed = 1;
      }
    }
  }

  /* The disarm image's anchor, by TAKE IDENTITY (#819): disarmSnapshot's
   * lane-0 image is placed at the RECORD_END whose logged take id matches the
   * settled take id the manifest recorded for this channel (`takeId`). That
   * id crossed the FFI boundary from the engine snapshot (le_track_snapshot.
   * settled_take_id) into performance.json, so the renderer names the exact
   * finalize the image is the result of — no longer inferring it from "the
   * FIRST RECORD_END while the channel is still content-free". That ordinal
   * proxy (deleted here, no fallback) mis-anchored whenever a finalize logged
   * a RECORD_END before content existed (#264) or a clear-then-re-record put
   * the settled take AFTER an earlier END on the same channel. A settled take
   * that predates the capture leaves no matching RECORD_END in this log, so no
   * disarm segment is placed — the arm image already covers it. */
  const le_json_value* disarm_lane =
      le_pr_find_lane0(m->disarm_tracks, channel);
  const int32_t disarm_take_id =
      disarm_lane != NULL
          ? (int32_t)le_json_number(le_json_get(disarm_lane, "takeId"), 0)
          : 0;
  /* Callback-applied source images (322/323, #1143): every 322 switches the
   * channel to the staged image it names (a channel may carry several per
   * capture — Clear Undo, layer Undo/Redo, Redo-from-empty), and each 322's
   * segment owns its own image, so a later 322 or a failure frees only the
   * image it loaded itself. */
  uint32_t restore_id = 0;
  float* restore_image = NULL; /* owned by its initial source segment */
  int32_t restore_len = 0;
  for (int i = 0; i < log_count; ++i) {
    const le_pr_log_entry* e = &log[i];
    if ((e->cmd.code == LE_PLOG_SOURCE_APPLIED || e->cmd.code == LE_PLOG_SOURCE_TRANSPORT) &&
        e->cmd.restore_log.channel == channel) {
      const int initial = e->cmd.code == LE_PLOG_SOURCE_APPLIED;
      const uint32_t id = e->cmd.restore_log.image_id;
      const int32_t state = e->cmd.restore_log.state, phase = e->cmd.restore_log.phase;
      if (initial) {
        restore_image = le_pr_restore_image(dir, m, channel, id, &restore_len);
        restore_id = id;
      }
      if (!restore_image || !id || id != restore_id || phase < 0 || phase >= restore_len ||
          (state != LE_TRACK_PLAYING && state != LE_TRACK_STOPPED)) {
        if (initial) free(restore_image);
        build.load_failed = 1;
        break;
      }
      const double anchor = le_pr_anchor(&build, e->frame, phase);
      le_pr_append_segment(&build, e->frame, anchor,
                           initial ? restore_image : NULL, initial ? restore_len : 0);
      if (build.load_failed) break;
      le_pr_segment* seg = &build.segments[build.segment_count - 1];
      seg->silent = state == LE_TRACK_STOPPED;
      if (!initial) {
        seg->owns_image = 0;
        seg->image = restore_image;
        seg->image_len = restore_len;
        seg->rate = le_pr_rate(&build, restore_len);
        seg->phase0 = anchor;
      }
    } else if (e->cmd.code == LE_PLOG_RECORD_END && e->cmd.take.channel == channel &&
        disarm_lane != NULL && disarm_take_id != 0 &&
        e->cmd.take.take_id == disarm_take_id) {
      restore_id = 0;
      {
        const le_json_value* pcm_ref_value =
            le_json_get(disarm_lane, "pcmRef");
        char pcm_ref[128];
        if (pcm_ref_value != NULL) {
          if (le_json_string(pcm_ref_value, pcm_ref, sizeof(pcm_ref))) {
            char path[LE_PR_FULL_PATH_MAX];
            snprintf(path, sizeof(path), "%s/%s", dir, pcm_ref);
            int32_t frames = 0;
            float* image = le_pr_read_wav_mono(path, &frames);
            if (image != NULL) {
              /* The segment anchors at the TRACK's epoch — the master
               * position at its logged RECORD_START plus the continuous
               * run to this finalize — NOT always 0, and NOT the master
               * lock's epoch mod the image length. Only the DEFINING
               * track's finalize (finalize_master, engine_process.c)
               * resets the loop clock; a track recorded fresh while the
               * master already runs finalizes via finalize_new_track,
               * which never touches the clock, and its buffer was WRITTEN
               * phase-locked from the master position at the record-start
               * press — a multi-loop take (k > 1) additionally cycles
               * relative to its own start iteration, which the RECORD_START
               * anchor captures and a lock-epoch derivation would not.
               * le_pr_record_end_phase (above) holds the full derivation,
               * including the defining-take and pre-arm-lock cases. */
              le_pr_append_segment(
                  &build, e->frame,
                  le_pr_record_end_phase(m, log, log_count, channel, e->frame,
                                         frames),
                  image, frames);
              /* A fresh take reads forward (#1162): its direction reset is
               * logged with the finalize, whichever lands first in the file. */
              if (!build.load_failed) {
                build.segments[build.segment_count - 1].reversed = 0;
              }
            } else {
              build.load_failed = 1;
            }
          } else {
            build.load_failed = 1; /* present but unreadable, see above */
          }
        }
      }
    } else if (e->cmd.code == LE_PLOG_LAYER_RETIRED &&
              e->cmd.evt.channel == channel) {
      restore_id = 0;
      const int layer_n = le_json_length(m->layers);
      /* In a capture whose full manifest dropped images, an unlisted retire
       * fails this stem rather than replaying the stale image. Otherwise the
       * existing tolerance stands: a retire handled at a disarm or Clear edge
       * may be unstaged, and keeps the prior image for that short tail. */
      int listed = 0;
      for (int li = 0; li < layer_n; ++li) {
        const le_json_value* layer = le_json_at(m->layers, li);
        if (le_json_number(le_json_get(layer, "kind"), 0) != 0) continue;
        const int32_t l_channel =
            (int32_t)le_json_number(le_json_get(layer, "channel"), -1);
        const int32_t l_slot =
            (int32_t)le_json_number(le_json_get(layer, "slot"), -1);
        const uint32_t l_gen =
            (uint32_t)le_json_number(le_json_get(layer, "generation"), 0);
        if (l_channel != channel || l_slot != e->cmd.evt.slot ||
            l_gen != e->cmd.evt.generation) {
          continue;
        }
        listed = 1;
        const int32_t frame_count =
            (int32_t)le_json_number(le_json_get(layer, "frame_count"), 0);
        const int32_t lane_count =
            (int32_t)le_json_number(le_json_get(layer, "lane_count"), 1);
        const le_json_value* filename_value = le_json_get(layer, "filename");
        char filename[64];
        if (filename_value == NULL) {
          break; /* no filename to even attempt: not this part's failure to
                  * report (a manifest entry with no filename is a part-5
                  * writer bug, not a stem-render concern) */
        }
        if (le_json_string(filename_value, filename, sizeof(filename))) {
          char path[LE_PR_FULL_PATH_MAX];
          snprintf(path, sizeof(path), "%s/%s", dir, filename);
          float* image = le_pr_read_layer_lane0(path, frame_count, lane_count);
          if (image != NULL) {
            /* The new image becomes active at the LOGGED retire frame
             * itself, not a derived "punch-in" frame one cycle earlier.
             * Deriving punch-in as `retire_frame - frame_count` is only
             * correct for a pass that retires exactly at its own loop-cycle
             * boundary (le_dub_boundary, engine_process.c) — a punch-out
             * mid-cycle instead retires via an asynchronous, chunked
             * live->shadow drain (le_dub_block_update) that can complete
             * many audio callbacks after the true punch-in, so the retire
             * frame has no fixed offset from it in that (very common) case.
             * By construction the retiring shadow is ALWAYS a complete,
             * correct loop image by the time it retires (the drain fills in
             * every position the live overdub didn't touch from the
             * previous image first) — so using the retire frame directly as
             * the switch point is exact where the data actually is
             * sample-accurate, at the cost of not modeling the sub-cycle
             * moment a live listener would have heard the transition
             * (which isn't logged anywhere and can't be reconstructed from
             * this capture).
             *
             * The segment inherits the loop phase the track had reached at
             * the retire frame (#255): a layer image is loop-position-
             * indexed, and live playback simply kept its position counter
             * running when the shadow swapped in — a retire at loop phase p
             * continued from image[p], so restarting the render at image[0]
             * would rotate the stem by p frames relative to what the
             * performer heard for every mid-cycle punch-out. Boundary
             * retires (p == 0) were already exact. */
            le_pr_append_segment(&build, e->frame,
                                 le_pr_build_phase_at(&build, e->frame), image,
                                 frame_count);
          } else {
            build.load_failed = 1;
          }
        } else {
          build.load_failed = 1; /* filename present but unreadable */
        }
        break;
      }
      if (!listed && m->layers_dropped) build.load_failed = 1;
    } else if ((e->cmd.code == LE_CMD_CLEAR || e->cmd.code == LE_CMD_UNDO_TO_EMPTY) &&
               e->cmd.arg_i == channel) {
      /* Both empty the track at their logged frame: exact silence from here
       * (39 is raw-logged from events.log version 6, #1143). Any image source
       * ends with it; the next content supplies its own 322 or RECORD_END. */
      restore_id = 0;
      le_pr_append_segment(&build, e->frame, 0, NULL, 0);
      if (!build.load_failed) {
        build.segments[build.segment_count - 1].reversed = 0; /* #1162 */
      }
    } else if (e->cmd.code == LE_PLOG_SPEED &&
               e->cmd.speed_log.channel == channel) {
      le_pr_apply_speed(&build, e->frame, &e->cmd);
    } else if (e->cmd.code == LE_PLOG_SOURCE_LEN &&
               e->cmd.lanei.channel == channel) {
      build.next_src_len = e->cmd.lanei.value;
    } else if (e->cmd.code == LE_PLOG_HEAD_SPAN &&
               e->cmd.span_log.channel == channel) {
      le_pr_apply_span(&build, e->frame, &e->cmd);
    } else if (e->cmd.code == LE_PLOG_TRANSPOSE &&
               e->cmd.transpose_log.channel == channel) {
      if (!le_pr_apply_transpose(&build, e->frame, &e->cmd, m->sample_rate)) {
        build.load_failed = 1;
      }
    } else if (e->cmd.code == LE_PLOG_REVERSE &&
               e->cmd.reverse_log.channel == channel) {
      le_pr_apply_direction(&build, e->frame, e->cmd.reverse_log.reversed != 0,
                            e->cmd.reverse_log.read_index,
                            e->cmd.reverse_log.turn_frames);
    }
    if (build.load_failed) break;
  }

  if (build.load_failed) {
    *out_failed = 1;
    for (int i = 0; i < build.segment_count; ++i) {
      if (build.segments[i].owns_image) free(build.segments[i].image);
      if (build.segments[i].owns_src) free(build.segments[i].src);
    }
    return NULL;
  }

  float* stem = (float*)calloc((size_t)m->capture_frames, sizeof(float));
  if (stem == NULL) {
    *out_failed = 1;
    for (int i = 0; i < build.segment_count; ++i) {
      if (build.segments[i].owns_image) free(build.segments[i].image);
      if (build.segments[i].owns_src) free(build.segments[i].src);
    }
    return NULL;
  }

  int seg_index = 0;
  for (uint64_t f = 0; f < m->capture_frames; ++f) {
    while (seg_index + 1 < build.segment_count &&
          build.segments[seg_index + 1].start_frame <= f) {
      seg_index++;
    }
    const le_pr_segment* seg = &build.segments[seg_index];
    if (!seg->silent && seg->image != NULL && seg->image_len > 0) {
      /* Phase-locked (#255): the segment's image plays from the loop
       * position it was actually at when the segment activated, not from
       * its own index 0, in its own direction (#1162) — stems reproduce
       * exactly what the performer heard. A direction turn mixes the old
       * head out with the callback's equal-gain law for its window. */
      const le_read_head head = le_pr_segment_head(seg);
      const int64_t into = (int64_t)(f - seg->start_frame);
      const float* rb = seg->src != NULL ? seg->src : seg->image;
      const int32_t rl =
          seg->src != NULL && seg->src_len > 0 ? seg->src_len : seg->image_len;
      stem[f] = le_head_read_scaled(rb, rl, seg->image_len, &head,
                                    le_head_index(&head, into, seg->image_len));
      const int64_t mixed = into + seg->turn_into0;
      if (seg->turn_frames > 0 && mixed < seg->turn_frames) {
        const double old = le_head_index(&seg->turn, into, seg->image_len);
        const float x = le_head_turn_mix((int32_t)mixed, seg->turn_frames,
                                         seg->turn_power);
        const float y =
            seg->turn_power
                ? le_head_turn_mix(seg->turn_frames - (int32_t)mixed,
                                   seg->turn_frames, 1)
                : 1.0f - x;
        const float* ob = seg->turn_src != NULL ? seg->turn_src : seg->image;
        const int32_t ol = seg->turn_src != NULL && seg->turn_src_len > 0
                               ? seg->turn_src_len
                               : seg->image_len;
        stem[f] = stem[f] * x + le_head_read_scaled(ob, ol, seg->image_len,
                                                    &seg->turn, old) * y;
      }
    }
  }

  for (int i = 0; i < build.segment_count; ++i) {
    if (build.segments[i].owns_image) free(build.segments[i].image);
    if (build.segments[i].owns_src) free(build.segments[i].src);
  }
  return stem;
}

/* ---- wet pass + master reconstruction (part 8) ---- */

/* Reinterprets `bits` as the `float` it was bit-cast from — the same
 * reinterpretation engine_private.h's `bits_to_f32` performs for every
 * atomic float field in this engine, applied here to a plain log payload
 * (LE_PLOG_SET_LANE_FX_PARAM/_MONITOR_FX_PARAM's `fx.type` field carries a
 * param value this way — see perf_log_ring.h). */
static float le_pr_bits_to_f32(uint32_t bits) {
  float f;
  memcpy(&f, &bits, sizeof(f));
  return f;
}

/* One channel's lane-0 effects chain, mirroring `le_lane`'s
 * a_fx_count/a_fx_type/a_fx_param fields — plus the two enable-flag levels
 * (a_fx_enabled / a_fx_chain_enabled) — closely enough to drive
 * fx_apply_chain directly. The enable bits seed all-1 at arm: the manifest
 * carries no arm-time enabled state until part 3, so a pre-arm disable is
 * invisible to this render (matching the fixed golden-parity protocol, which
 * arms from a default-enabled engine). */
typedef struct le_pr_fx_chain {
  int32_t count;
  int32_t type[LE_FX_MAX];
  float params[LE_FX_MAX][LE_FX_PARAMS];
  int32_t enabled[LE_FX_MAX];
  int32_t chain_enabled;
} le_pr_fx_chain;

static void le_pr_fx_chain_init_empty(le_pr_fx_chain* c) {
  c->count = 0;
  c->chain_enabled = 1;
  for (int i = 0; i < LE_FX_MAX; ++i) {
    c->type[i] = LE_FX_NONE;
    c->enabled[i] = 1;
    for (int p = 0; p < LE_FX_PARAMS; ++p) c->params[i][p] = 0.0f;
  }
}

/* Seeds a chain from a lane's `effects` array (the arm-snapshot's lane-0
 * entry, or NULL for a channel with no arm-time presence — starts empty,
 * exactly like a freshly recorded track's live chain before any FX command
 * has ever touched it). A malformed manifest entry with more than LE_FX_MAX
 * effects is truncated rather than overrunning the fixed arrays. */
static void le_pr_fx_chain_init_from_lane(le_pr_fx_chain* c,
                                          const le_json_value* lane) {
  le_pr_fx_chain_init_empty(c);
  if (lane == NULL) return;
  c->chain_enabled = le_json_bool(le_json_get(lane, "chainEnabled"), 1);
  const le_json_value* effects = le_json_get(lane, "effects");
  const int n = le_json_length(effects);
  c->count = n > LE_FX_MAX ? LE_FX_MAX : n;
  for (int i = 0; i < c->count; ++i) {
    const le_json_value* entry = le_json_at(effects, i);
    c->enabled[i] = le_json_bool(le_json_get(entry, "enabled"), 1);
    c->type[i] =
        (int32_t)le_json_number(le_json_get(entry, "type"), LE_FX_NONE);
    const le_json_value* params = le_json_get(entry, "params");
    for (int p = 0; p < LE_FX_PARAMS; ++p) {
      c->params[i][p] = (float)le_json_number(le_json_at(params, p), 0.0);
    }
  }
}

/* This render's heap le_fx_state teardown is the shared offline-state one
 * (le_fx_state_free_buffers, engine_fx.c) — a future heap-owning effect adds
 * its free there once and this renderer inherits it. */

/* Renders channel `channel`'s wet stem into a freshly malloc'd buffer of
 * `capture_frames` samples (caller frees), or NULL with `*out_failed` set on
 * allocation failure. `dry` is that channel's already-reconstructed dry
 * content (le_pr_render_track's output — same content, not recomputed) at
 * unity gain; this replays the SAME per-frame mix order the live engine's
 * mix_tracks_frame uses: lane-0 volume gates the sample (zeroed while
 * muted), THEN the logged FX chain processes it (continuously, every frame,
 * so delay/reverb tails and LFO phase stay continuous exactly as they do
 * live — only whether the result is later summed into the master differs
 * live, and this render has no separate "audible" gate beyond content
 * presence, see the doc note below). A mono source is fed into both L/R
 * (fx_apply_chain always runs stereo per-channel state); since both start
 * and stay equal by construction (symmetric per-channel state, identical
 * input), only L is kept.
 *
 * Scope note: this reconstructs lane-0 volume/mute and the lane-0 FX chain
 * from events.log (LE_CMD_SET_LANE_FX/_FX_COUNT, LE_PLOG_SET_LANE_FX_PARAM,
 * LE_CMD_SET_LANE_VOLUME/_MUTE, and their track-addressed LE_CMD_SET_VOLUME/
 * _MUTE equivalents, which map to lane 0 — engine_process.c). It does NOT
 * reconstruct the full RECORDING/PLAYING/STOPPED transport state machine: a
 * manual stop-then-resume of an already-recorded track mid-performance is
 * out of scope here (matching this part's fixed golden-parity protocol,
 * which already excludes monitor inputs, plugin slots, and pre-arm FX tails
 * BY CONSTRUCTION rather than widening tolerance) — content presence (from
 * `dry`) is this render's only audibility gate beyond mute. */
static float* le_pr_render_wet_track(const le_pr_manifest* m,
                                     const le_pr_log_entry* log, int log_count,
                                     int32_t channel, const float* dry,
                                     int32_t* out_failed, float* routed) {
  *out_failed = 0;
  const le_json_value* arm_track = le_pr_find_track(m->arm_tracks, channel);
  const le_json_value* arm_lane = le_pr_find_lane0(m->arm_tracks, channel);

  le_pr_fx_chain chain;
  le_pr_fx_chain_init_from_lane(&chain, arm_lane);
  le_fade fade = {1, 1, 0};
  float track_gain = (float)le_json_number(
      arm_track != NULL ? le_json_get(arm_track, "volume") : NULL, 1.0);
  float volume = (float)le_json_number(le_json_get(arm_lane, "volume"), 1.0);
  int muted = le_json_bool(le_json_get(arm_lane, "muted"),
      le_json_bool(le_json_get(arm_track, "muted"), 0));
  float pan = (float)le_json_number(le_json_get(arm_lane, "pan"), 0);
  uint32_t route = (uint32_t)le_json_number(le_json_get(arm_lane, "outputMask"), 1);
  uint32_t output_enabled = m->output_enabled_mask;
  int cut_silenced = 0;
  /* Solo (slice 3) is an audibility gate across EVERY track: while any is
   * soloed only soloed tracks route. Seeded from the arm manifest (a track
   * absent there reads 0) and moved by the logged LE_CMD_SET_TRACK_SOLO of
   * every channel, not only this one. */
  int solo[LE_MAX_TRACKS] = {0};
  for (int32_t t = 0; t < LE_MAX_TRACKS; ++t) {
    const le_json_value* track = le_pr_find_track(m->arm_tracks, t);
    solo[t] = le_json_bool(track != NULL ? le_json_get(track, "solo") : NULL,
                           0);
  }

  le_fx_state* fx = (le_fx_state*)calloc(1, sizeof(le_fx_state));
  if (fx == NULL) {
    *out_failed = 1;
    return NULL;
  }
  /* Seed the enable-crossfade runtime SETTLED at enabled, mirroring
   * le_lane_reset — a calloc'd zero state would fade the whole chain in over
   * the ramp window at frame 0 and break golden parity. */
  for (int s = 0; s < LE_FX_MAX; ++s) le_fx_enable_seed_settled(fx, s);
  /* A prepare failure (OOM on a delay ring / octaver's phase-vocoder heap)
   * is NOT let through as a silent dry-passthrough degradation: fx_delay/
   * fx_octaver already handle a NULL buffer gracefully at the DSP level
   * (matching the live engine's own OOM posture), but this render treats it
   * as a genuine per-stem failure — the same "partial success, not silent
   * drift" posture load_failed already gives pcmRef/layer read failures
   * below — rather than quietly rendering a track's FX chain as if a slot
   * were bypassed. */
  int prepare_failed = 0;
  for (int s = 0; s < chain.count; ++s) {
    if (chain.type[s] != LE_FX_NONE &&
        le_fx_prepare(fx, s, chain.type[s], m->sample_rate) != LE_OK) {
      prepare_failed = 1;
    }
  }

  float* wet = (float*)calloc((size_t)m->capture_frames, sizeof(float));
  if (wet == NULL) {
    le_fx_state_free_buffers(fx);
    free(fx);
    *out_failed = 1;
    return NULL;
  }

  /* Per-slot EFFECTIVE enable bits (D-EFFBITS), exactly as snapshot_lane_fx
   * computes them live. Recomputed only when a replayed log entry lands —
   * the bits cannot change between log entries. */
  int32_t effective[LE_FX_MAX];
  for (int s = 0; s < LE_FX_MAX; ++s) {
    effective[s] = chain.chain_enabled && chain.enabled[s];
  }

  int log_index = 0;
  for (uint64_t f = 0; f < m->capture_frames; ++f) {
    /* Apply every logged mutation for this channel's lane 0 at or before
     * this frame, in log order (already frame-sorted by le_pr_load_log),
     * before rendering it — mirrors mix_tracks_frame's per-frame (not
     * per-block) re-read of lane volume/mute/FX state. */
    while (log_index < log_count && log[log_index].frame <= f) {
      const le_log_command* cmd = &log[log_index].cmd;
      switch (cmd->code) {
        case LE_CMD_SET_LANE_FX:
          if (cmd->fx.channel == channel && cmd->fx.lane == 0 &&
              cmd->fx.index >= 0 && cmd->fx.index < LE_FX_MAX) {
            /* Mirrors le_engine_set_lane_fx's control-side behavior
             * (engine_commands.c: le_fx_prepare_entry), not just the
             * audio-thread ring handler: a REAL type change silently reseeds
             * that slot's default params via a direct atomic write, with NO
             * corresponding events.log entry (defaults are seeded before the
             * LE_CMD_SET_LANE_FX ring command is even posted, and only the
             * type change itself is logged) — replaying just the type swap
             * without also reseeding defaults here would leave this render
             * holding stale params the live engine never actually used past
             * this instant. Guarded on an ACTUAL change, matching
             * le_fx_prepare_entry's own `!= type` check (a reorder back to
             * the same type must not wipe a listener's tweaks). */
            if (chain.type[cmd->fx.index] != cmd->fx.type) {
              le_fx_defaults(cmd->fx.type, chain.params[cmd->fx.index]);
              /* D-ENSEED mirror: an ACTUAL type change also re-seeds the
               * slot's enabled flag to 1 on the control side (silently, like
               * the defaults — no events.log entry of its own). */
              chain.enabled[cmd->fx.index] = 1;
            }
            chain.type[cmd->fx.index] = cmd->fx.type;
            le_fx_entry_reset(fx, cmd->fx.index);
            if (cmd->fx.type != LE_FX_NONE &&
                le_fx_prepare(fx, cmd->fx.index, cmd->fx.type,
                             m->sample_rate) != LE_OK) {
              prepare_failed = 1;
            }
          }
          break;
        case LE_CMD_SET_LANE_FX_COUNT:
          if (cmd->fxcount.channel == channel && cmd->fxcount.lane == 0) {
            int32_t count = cmd->fxcount.count;
            if (count < 0) count = 0;
            if (count > LE_FX_MAX) count = LE_FX_MAX;
            /* D-ENSEED mirror (le_fx_seed_entering_slots): a slot entering
             * the active window re-seeds enabled=1, silently, like the
             * defaults above. */
            for (int32_t s = chain.count; s < count; ++s) {
              chain.enabled[s] = 1;
            }
            chain.count = count;
          }
          break;
        case LE_PLOG_SET_LANE_FX_PARAM:
          if (cmd->fx.channel == channel && cmd->fx.lane == 0) {
            const int32_t index = LE_PLOG_FX_PARAM_INDEX(cmd->fx.index);
            const int32_t param = LE_PLOG_FX_PARAM_PARAM(cmd->fx.index);
            if (index >= 0 && index < LE_FX_MAX && param >= 0 &&
                param < LE_FX_PARAMS) {
              chain.params[index][param] =
                  le_pr_bits_to_f32((uint32_t)cmd->fx.type);
            }
          }
          break;
        case LE_PLOG_SET_LANE_FX_ENABLED:
          if (cmd->fx.channel == channel && cmd->fx.lane == 0 &&
              cmd->fx.index >= 0 && cmd->fx.index < LE_FX_MAX) {
            chain.enabled[cmd->fx.index] = cmd->fx.type != 0;
          }
          break;
        case LE_PLOG_SET_LANE_FX_CHAIN_ENABLED:
          if (cmd->lanef.channel == channel && cmd->lanef.lane == 0) {
            chain.chain_enabled = cmd->lanef.value != 0.0f;
          }
          break;
        case LE_CMD_SET_LANE_PAN:
          if (cmd->lanef.channel == channel && cmd->lanef.lane == 0)
            pan = cmd->lanef.value;
          break;
        case LE_CMD_SET_OUTPUT_MASK:
          if (cmd->trackmask.channel == channel) route = cmd->trackmask.mask;
          break;
        case LE_CMD_SET_LANE_OUTPUT:
          if (cmd->lanei.channel == channel && cmd->lanei.lane == 0) route = (uint32_t)cmd->lanei.value;
          break;
        case LE_CMD_SET_OUTPUT_ENABLED:
          if (cmd->arg_i >= 0 && cmd->arg_i < 32) {
            if (cmd->arg_f != 0) output_enabled |= 1u << cmd->arg_i;
            else output_enabled &= ~(1u << cmd->arg_i);
          }
          break;
        case LE_CMD_PLAY:
          if (cmd->arg_i == channel) cut_silenced = 0;
          break;
        case LE_PLOG_RECORD_START:
          if (cmd->arg_i == channel) cut_silenced = 0;
          break;
        case LE_CMD_CUT_SOUND:
          cut_silenced = 1;
          for (int i = 0; i < LE_FX_MAX; ++i) {
            le_fx_entry_reset(fx, i);
            le_fx_entry_clear_rings(fx, i, m->sample_rate);
          }
          break;
        case LE_CMD_SET_LANE_VOLUME:
          if (cmd->lanef.channel == channel && cmd->lanef.lane == 0) {
            volume = cmd->lanef.value;
          }
          break;
        case LE_PLOG_FADE:
          if (cmd->fade_log.channel == channel)
            fade = (le_fade){cmd->fade_log.amount, cmd->fade_log.target, cmd->fade_log.seconds};
          break;
        case LE_CMD_SET_VOLUME:
          if (cmd->arg_i == channel) track_gain = cmd->arg_f;
          break;
        case LE_CMD_SET_LANE_MUTE:
          if (cmd->lanef.channel == channel && cmd->lanef.lane == 0) {
            muted = cmd->lanef.value != 0.0f;
          }
          break;
        case LE_CMD_SET_MUTE:
          if (cmd->arg_i == channel) muted = cmd->arg_f != 0.0f;
          break;
        case LE_CMD_SET_TRACK_SOLO:
          if (cmd->arg_i >= 0 && cmd->arg_i < LE_MAX_TRACKS) {
            solo[cmd->arg_i] = cmd->arg_f != 0.0f;
          }
          break;
        default:
          break;
      }
      log_index++;
      for (int s = 0; s < LE_FX_MAX; ++s) {
        effective[s] = chain.chain_enabled && chain.enabled[s];
        /* Mirror of the live snapshots' gap rule (snapshot_lane_fx): a slot
         * the chain no longer processes settles at bypass while its
         * effective bit is 0, so a later re-entry goes through the clean
         * settled-edge reset exactly as it does live. */
        if ((s >= chain.count || chain.type[s] == LE_FX_NONE) &&
            !effective[s]) {
          le_fx_enable_force_bypass(fx, s);
        }
      }
    }

    int any_solo = 0;
    for (int32_t t = 0; t < LE_MAX_TRACKS; ++t) any_solo |= solo[t];
    const int audible = !cut_silenced && !muted && (!any_solo || solo[channel]);
    const float in = audible ? dry[f] * volume : 0.0f;
    float l = in;
    float r = in;
    fx_apply_chain(fx, m->sample_rate, m->sample_rate, &l, &r, chain.count,
                   chain.type, chain.params, effective);
    const float gain = track_gain * le_fade_tick(&fade, m->sample_rate);
    l *= gain;
    r *= gain;
    wet[f] = l;
    const float far = fabsf(pan) >= 1 ? 0 : cosf(fabsf(pan) * 1.57079632679f);
    l *= pan > 0 ? far : 1;
    r *= pan < 0 ? far : 1;
    const uint32_t mask = route & output_enabled;
    int count = 0;
    for (int c = 0; c < LE_MAX_CHANNELS; ++c) if (mask & (1u << c)) count++;
    int index = 0;
    for (int c = 0; c < LE_MAX_CHANNELS; ++c) {
      if (!(mask & (1u << c))) continue;
      const float value = count == 1 ? 0.5f * (l + r) : index == 0 ? l : index == 1 ? r : 0.5f * (l + r);
      if (c / 2 == m->arm_capture_bus) routed[2*f + c%2] += value;
      index++;
    }
  }

  le_fx_state_free_buffers(fx);
  free(fx);
  if (prepare_failed) {
    *out_failed = 1;
    free(wet);
    return NULL;
  }
  return wet;
}

/* Replays the master gain + feed-forward limiter over `master` (in place,
 * `capture_frames` samples — already the sum of every channel's wet
 * contribution), mirroring master_bus_frame's mono-channel math exactly
 * (engine_process.c): instant-attack / smooth-release limiter, ~50 ms
 * release toward unity. Uses its own local `lim_gain`, seeded at 1.0 (the
 * golden-parity protocol arms from silence, so the live engine's own
 * lim_gain is 1.0 at that instant too — see engine.c's fresh-state init) —
 * never the live engine's `e->lim_gain`, which the audio thread may still be
 * mutating concurrently after disarm (this render has no live-engine
 * dependency, see the file header). */
static int le_pr_render_master(const le_pr_manifest* m,
                                const le_pr_log_entry* log, int log_count,
                                float* master) {
  le_pr_fx_chain chain;
  le_pr_fx_chain_init_empty(&chain);
  const le_json_value* effects = le_json_get(m->arm_output, "outputEffects");
  chain.count = le_json_length(effects);
  if (chain.count > LE_FX_MAX) return 0;
  chain.chain_enabled = le_json_bool(le_json_get(m->arm_output, "outputChainEnabled"), 1);
  for (int i = 0; i < chain.count; ++i) {
    const le_json_value* entry = le_json_at(effects, i);
    chain.type[i] = (int32_t)le_json_number(le_json_get(entry, "type"), 0);
    chain.enabled[i] = le_json_bool(le_json_get(entry, "enabled"), 1);
    for (int p = 0; p < LE_FX_PARAMS; ++p)
      chain.params[i][p] = (float)le_json_number(le_json_at(le_json_get(entry, "params"), p), 0);
  }
  le_fx_state* fx = calloc(1, sizeof(*fx));
  if (!fx) return 0;
  int ok = 1;
  for (int i = 0; i < LE_FX_MAX; ++i) {
    le_fx_enable_seed_settled(fx, i);
    if (chain.type[i] != LE_FX_NONE &&
        le_fx_prepare(fx, i, chain.type[i], m->sample_rate) != LE_OK) ok = 0;
  }
  float level = m->arm_output_level;
  int muted = m->arm_output_muted;
  int at = 0;
  for (uint64_t f = 0; f < m->capture_frames; ++f) {
    while (at < log_count && log[at].frame <= f) {
      const le_log_command* cmd = &log[at++].cmd;
      if (cmd->code == LE_CMD_SET_OUTPUT_LEVEL && cmd->lanef.channel == m->arm_capture_bus)
        level = cmd->lanef.value;
      else if (cmd->code == LE_CMD_SET_OUTPUT_MUTE && cmd->lanef.channel == m->arm_capture_bus)
        muted = cmd->lanef.value != 0;
      else if (cmd->code == LE_CMD_SET_OUTPUT_FX && cmd->fx.channel == m->arm_capture_bus && cmd->fx.index >= 0 && cmd->fx.index < LE_FX_MAX) {
        int i = cmd->fx.index;
        if (chain.type[i] != cmd->fx.type) {
          le_fx_defaults(cmd->fx.type, chain.params[i]);
          chain.enabled[i] = 1;
        }
        chain.type[i] = cmd->fx.type;
        le_fx_entry_reset(fx, i);
        if (le_fx_prepare(fx, i, chain.type[i], m->sample_rate) != LE_OK) ok = 0;
      } else if (cmd->code == LE_CMD_SET_OUTPUT_FX_COUNT && cmd->fxcount.channel == m->arm_capture_bus) {
        int count = cmd->fxcount.count;
        if (count < 0 || count > LE_FX_MAX) { ok = 0; continue; }
        for (int i = chain.count; i < count; ++i) chain.enabled[i] = 1;
        chain.count = count;
      } else if (cmd->code == LE_PLOG_SET_OUTPUT_FX_PARAM && cmd->fx.channel == m->arm_capture_bus) {
        int i = LE_PLOG_FX_PARAM_INDEX(cmd->fx.index), p = LE_PLOG_FX_PARAM_PARAM(cmd->fx.index);
        if (i >= 0 && i < LE_FX_MAX && p >= 0 && p < LE_FX_PARAMS)
          chain.params[i][p] = le_pr_bits_to_f32((uint32_t)cmd->fx.type);
      } else if (cmd->code == LE_PLOG_SET_OUTPUT_FX_ENABLED && cmd->fx.channel == m->arm_capture_bus && cmd->fx.index >= 0 && cmd->fx.index < LE_FX_MAX)
        chain.enabled[cmd->fx.index] = cmd->fx.type != 0;
      else if (cmd->code == LE_PLOG_SET_OUTPUT_FX_CHAIN_ENABLED && cmd->arg_i == m->arm_capture_bus)
        chain.chain_enabled = cmd->arg_f != 0;
      else if (cmd->code == LE_CMD_CUT_SOUND)
        for (int i = 0; i < LE_FX_MAX; ++i) {
            le_fx_entry_reset(fx, i);
            le_fx_entry_clear_rings(fx, i, m->sample_rate);
          }
    }
    int32_t effective[LE_FX_MAX];
    for (int i = 0; i < LE_FX_MAX; ++i) effective[i] = chain.chain_enabled && chain.enabled[i];
    float l = master[2*f], r = master[2*f+1];
    fx_apply_chain(fx, m->sample_rate, m->sample_rate, &l, &r,
      chain.count, chain.type, chain.params, effective);
    const float gain = m->arm_follow_output ? (muted ? 0 : level) : 1;
    master[2*f] = l * gain; master[2*f+1] = r * gain;
  }
  le_fx_state_free_buffers(fx); free(fx);
  return ok;
}

/* ---- worker thread ---- */

/* Test-only global: forces the dry-stem write for one specific channel below
 * to fail, deterministically simulating a transient I/O error on that one
 * write without touching the filesystem or affecting the wet-stem write, or
 * any other channel's dry write in the same render (engine_internal.h). -1
 * disables it. Relaxed: a lone value a test flips before/after driving a
 * render, not raced against anything else. */
static _Atomic int32_t g_pr_force_dry_write_failure_channel = -1;

void le_perf_render_force_dry_write_failure_for_test(int32_t channel) {
  atomic_store_explicit(&g_pr_force_dry_write_failure_channel, channel,
                        memory_order_relaxed);
}

static void le_pr_worker_main(void* arg) {
  le_perf_render* r = (le_perf_render*)arg;

  char* text = NULL;
  le_json_value* root = NULL;
  le_json_arena arena = {0};
  le_pr_manifest manifest = {0};
  const int32_t status =
      le_pr_load_manifest(r->capture_dir, &text, &arena, &root, &manifest);
  const int loaded = status == LE_OK;

  le_pr_log_entry* log = NULL;
  int log_count = loaded ? le_pr_load_log(r->capture_dir, &log) : 0;
  /* The master-phase anchor comes from the log's PERF_ARMED fact (#262), not
   * the manifest JSON — fill it now that both are loaded. */
  if (loaded) le_pr_fill_perf_armed(log, log_count, &manifest);

  int32_t channels[LE_MAX_TRACKS];
  const int channel_count =
      loaded ? le_pr_collect_channels(&manifest, log, log_count, channels, LE_MAX_TRACKS) : 0;

  /* Master accumulator: the sum of every channel's wet contribution, before
   * the master gain + limiter pass runs over it once, after every channel
   * has been processed (le_pr_render_master, below) — mirrors
   * mix_tracks_frame's additive per-lane sum feeding master_bus_frame. NULL
   * (rather than a zero-length calloc) when there is nothing to render, so
   * the write-out step below can use its presence as the gate. */
  float* master_accum =
      (loaded && channel_count > 0)
          ? (float*)calloc((size_t)manifest.capture_frames * 2, sizeof(float))
          : NULL;

  if (loaded && channel_count > 0) {
    char dry_dir[LE_PR_FULL_PATH_MAX];
    snprintf(dry_dir, sizeof(dry_dir), "%s/stems/dry", r->capture_dir);
    le_pr_mkdir_recursive(dry_dir);
    char wet_dir[LE_PR_FULL_PATH_MAX];
    snprintf(wet_dir, sizeof(wet_dir), "%s/stems/wet", r->capture_dir);
    le_pr_mkdir_recursive(wet_dir);

    for (int i = 0; i < channel_count; ++i) {
      if (!atomic_load_explicit(&r->running, memory_order_acquire)) break;

      const int32_t channel = channels[i];
      int32_t load_failed = 0;
      float* stem = le_pr_render_track(r->capture_dir, &manifest, log, log_count,
                                       channel, &load_failed);
      int ok = 0;
      if (stem != NULL) {
        char dry_path[LE_PR_FULL_PATH_MAX];
        snprintf(dry_path, sizeof(dry_path), "%s/track%d.wav", dry_dir, channel);
        if (atomic_load_explicit(&g_pr_force_dry_write_failure_channel,
                                 memory_order_relaxed) == channel) {
          ok = 0; /* test-only: simulate a dry-write I/O failure on this one
                   * channel without touching the filesystem
                   * (le_perf_render_force_dry_write_failure_for_test,
                   * above). */
        } else {
          ok = le_pr_write_wav_mono(dry_path, stem,
                                    (int32_t)manifest.capture_frames,
                                    manifest.sample_rate);
        }

        int32_t wet_failed = 0;
        float* routed = calloc((size_t)manifest.capture_frames * 2, sizeof(float));
        float* wet = routed ? le_pr_render_wet_track(&manifest, log, log_count, channel,
                                            stem, &wet_failed, routed) : NULL;
        if (wet != NULL) {
          char wet_path[LE_PR_FULL_PATH_MAX];
          snprintf(wet_path, sizeof(wet_path), "%s/track%d.wav", wet_dir, channel);
          const int wet_ok = le_pr_write_wav_mono(
              wet_path, wet, (int32_t)manifest.capture_frames,
              manifest.sample_rate);
          ok = ok && wet_ok;
          /* Either write failing (dry OR wet) leaves this channel out of the
           * master sum below with no separate flag on master.wav itself —
           * the signal is `ok` above, surfaced via this channel's own
           * `le_perf_render_track_status.succeeded == 0`, the same partial-
           * success contract every other per-stem failure in this file
           * already uses; a consumer checking every track's status before
           * trusting master.wav as complete already has everything it needs.
           * Gating on `ok` (not `wet_ok` alone) matters because a dry-write
           * failure must exclude this channel's wet content from master.wav
           * too, even though the wet write itself succeeded — otherwise
           * master.wav would contain audio for a channel the render already
           * reports as failed. */
          if (ok && master_accum != NULL) {
            for (uint64_t f = 0; f < manifest.capture_frames; ++f) {
              master_accum[2*f] += routed[2*f];
              master_accum[2*f+1] += routed[2*f+1];
            }
          }
          free(wet);
        } else {
          ok = 0;
        }
        free(routed);
        free(stem);
      }

      const int index = atomic_load_explicit(&r->track_count, memory_order_relaxed);
      atomic_store_explicit(&r->results[index].channel, channel,
                            memory_order_relaxed);
      atomic_store_explicit(&r->results[index].succeeded, ok ? 1 : 0,
                            memory_order_release);
      atomic_store_explicit(&r->track_count, index + 1, memory_order_release);
      atomic_store_explicit(&r->progress_pct, (int)(((i + 1) * 100) / channel_count),
                            memory_order_relaxed);
    }

    if (master_accum != NULL &&
        atomic_load_explicit(&r->running, memory_order_acquire)) {
      const int master_ok = le_pr_render_master(&manifest, log, log_count, master_accum);
      char master_path[LE_PR_FULL_PATH_MAX];
      snprintf(master_path, sizeof(master_path), "%s/master.wav", wet_dir);
      const uint32_t pair_mask = (manifest.capture_mask >> (2 * manifest.arm_capture_bus)) & 3u;
      const int channels = pair_mask == 3 ? 2 : 1;
      if (channels == 1) {
        const int side = pair_mask == 2 ? 1 : 0;
        for (uint64_t f = 0; f < manifest.capture_frames; ++f)
          master_accum[f] = master_accum[2*f+side];
      }
      if (master_ok) le_pr_write_wav(master_path, master_accum,
                           (int32_t)manifest.capture_frames,
                           manifest.sample_rate, (uint16_t)channels);
      else for (int i = 0; i < channel_count; ++i)
        atomic_store_explicit(&r->results[i].succeeded, 0, memory_order_release);
    }
  }

  free(master_accum);
  free(log);
  free(text);
  free(arena.nodes);

  /* An unusable manifest is a failed render, not a valid empty one: publish
   * the terminal status before `done`, whose release orders it for pollers. */
  atomic_store_explicit(&r->result, status, memory_order_relaxed);
  atomic_store_explicit(&r->progress_pct, 100, memory_order_relaxed);
  atomic_store_explicit(&r->done, 1, memory_order_release);
}

/* ---- public ABI ---- */

int32_t le_perf_render_begin(le_engine* engine, const char* capture_dir) {
  if (engine == NULL || capture_dir == NULL || capture_dir[0] == '\0') {
    return LE_ERR_INVALID;
  }
  if (engine->perf.render != NULL &&
      !atomic_load_explicit(&engine->perf.render->done, memory_order_acquire)) {
    return LE_ERR_ALREADY_RUNNING;
  }
  if (engine->perf.render != NULL) {
    /* A finished-but-unreaped session from a prior render: join and free it
     * before starting a new one (mirrors le_perf_drain's reaping). */
    le_pr_thread_join(engine->perf.render->thread);
    free(engine->perf.render);
    engine->perf.render = NULL;
  }

  le_perf_render* r = (le_perf_render*)calloc(1, sizeof(le_perf_render));
  if (r == NULL) return LE_ERR_DEVICE;
  r->engine = engine;
  snprintf(r->capture_dir, sizeof(r->capture_dir), "%s", capture_dir);
  atomic_store_explicit(&r->running, 1, memory_order_relaxed);
  atomic_store_explicit(&r->done, 0, memory_order_relaxed);
  atomic_store_explicit(&r->progress_pct, 0, memory_order_relaxed);
  atomic_store_explicit(&r->track_count, 0, memory_order_relaxed);

  if (!le_pr_thread_start(&r->thread, r)) {
    free(r);
    return LE_ERR_DEVICE;
  }

  engine->perf.render = r;
  return LE_OK;
}

int32_t le_perf_render_poll(le_engine* engine, int32_t* done,
                            int32_t* progress_pct, int32_t* track_count) {
  if (engine == NULL) return LE_ERR_INVALID;
  le_perf_render* r = engine->perf.render;
  if (r == NULL) {
    if (done != NULL) *done = 1;
    if (progress_pct != NULL) *progress_pct = 100;
    if (track_count != NULL) *track_count = 0;
    return LE_OK;
  }
  const int finished = atomic_load_explicit(&r->done, memory_order_acquire);
  if (done != NULL) *done = finished;
  if (progress_pct != NULL) {
    *progress_pct = atomic_load_explicit(&r->progress_pct, memory_order_relaxed);
  }
  if (track_count != NULL) {
    *track_count = atomic_load_explicit(&r->track_count, memory_order_acquire);
  }
  return finished ? atomic_load_explicit(&r->result, memory_order_relaxed)
                  : LE_OK;
}

int32_t le_perf_render_track_status(le_engine* engine, int32_t index,
                                    int32_t* channel, int32_t* succeeded) {
  if (engine == NULL || index < 0) return LE_ERR_INVALID;
  le_perf_render* r = engine->perf.render;
  if (r == NULL || index >= atomic_load_explicit(&r->track_count,
                                                 memory_order_acquire)) {
    return LE_ERR_INVALID;
  }
  if (channel != NULL) {
    *channel = atomic_load_explicit(&r->results[index].channel,
                                    memory_order_relaxed);
  }
  if (succeeded != NULL) {
    *succeeded = atomic_load_explicit(&r->results[index].succeeded,
                                      memory_order_acquire);
  }
  return LE_OK;
}

int32_t le_perf_render_cancel(le_engine* engine) {
  if (engine == NULL) return LE_ERR_INVALID;
  le_perf_render* r = engine->perf.render;
  if (r == NULL) return LE_OK;
  atomic_store_explicit(&r->running, 0, memory_order_release);
  le_pr_thread_join(r->thread);
  free(r);
  engine->perf.render = NULL;
  return LE_OK;
}
