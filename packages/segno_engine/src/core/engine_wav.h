/* engine_wav.h — the engine's one streaming float WAV writer (#1202, #1198).
 *
 * Layout (the recording/recovery plan's part format): RIFF/WAVE, a 16-byte
 * `fmt ` with tag 3 (IEEE float), 32 bits and block align 4 x channels, an
 * optional caller chunk (a performance part's `sgno` identity), then `data`.
 * The header is written with zero sizes, samples are appended as they come,
 * and le_wav_seal patches the RIFF and `data` sizes, flushes and fsyncs. A
 * file sealed with no extra chunk is byte-identical to wav_codec's
 * encodeFloat32 output (packages/wav_codec/lib/src/wav.dart).
 *
 * Internal to the engine's own TUs (render recipe, performance renderer,
 * capture parts). Deliberately NOT included by engine_private.h, so it never
 * reaches the VST3 C++ translation units. */
#ifndef SEGNO_ENGINE_WAV_H
#define SEGNO_ENGINE_WAV_H

#include <stdint.h>
#include <stdio.h>

typedef struct le_wav_writer {
  FILE* file;
  int32_t channels;
  uint32_t header_bytes; /* bytes before the first sample */
  uint64_t frames;       /* frames appended so far */
  int failed;            /* a write failed; seal reports it */
} le_wav_writer;

/* Creates `path` (truncating) and writes the zero-size header. `chunk_id` is
 * NULL for no extra chunk, else a 4-byte id written with `chunk_bytes` of
 * `chunk` (an even size keeps RIFF word alignment). Returns 1 on success. */
int le_wav_open(le_wav_writer* w, const char* path, int32_t sample_rate,
                int32_t channels, const char* chunk_id, const void* chunk,
                uint32_t chunk_bytes);

/* Appends `frames` interleaved frames. Returns 1 while every write landed. */
int le_wav_append(le_wav_writer* w, const float* samples, uint64_t frames);

/* Credits `frames` more whole frames written to w->file by the caller's own
 * write path. For the capture drain (perf_drain.c), which writes through its
 * write-budget test seam and floors a short write to whole frames itself;
 * le_wav_seal then patches the sizes from the credited count. */
void le_wav_note_frames(le_wav_writer* w, uint64_t frames);

/* Patches the RIFF and data sizes, flushes, optionally fsyncs, and closes.
 * Returns 1 when the whole file (header, samples, sizes) is on disk. A data
 * size beyond 32 bits fails rather than writing a wrapped size. */
int le_wav_seal(le_wav_writer* w, int sync);

/* Closes without sealing (the caller unlinks the partial file). */
void le_wav_abandon(le_wav_writer* w);

/* Replaces `final_path` with `part_path` in one rename, then syncs the
 * containing directory (le_fs_sync_dir, #1198 Part 1) so the new entry is
 * durable. Returns 1 on success. */
int le_wav_publish(const char* part_path, const char* final_path);

/* One-shot helper: writes a whole interleaved buffer as a sealed file. */
int le_wav_write_file(const char* path, const float* samples, uint64_t frames,
                      int32_t sample_rate, int32_t channels);

#endif /* SEGNO_ENGINE_WAV_H */
