/* engine_wav.h — the engine's one streaming float WAV writer (#1202, #1198).
 *
 * Layout (the recording/recovery plan's part format): RIFF/WAVE, a 16-byte
 * `fmt ` with tag 3 (IEEE float), 32 bits and block align 4 x channels, an
 * optional caller chunk (a performance part's `sgno` identity), then `data`.
 * The header is written with zero sizes, samples are appended as they come,
 * and le_wav_seal patches the RIFF and `data` sizes, flushes, truncates the
 * file to header plus data, and fsyncs. A
 * file sealed with no extra chunk is byte-identical to wav_codec's
 * encodeFloat32 output (packages/wav_codec/lib/src/wav.dart).
 *
 * Internal to the engine's own TUs (render recipe, performance renderer,
 * capture parts). */
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
 * `chunk`; an odd size is refused (RIFF chunks are word aligned). Returns 1
 * on success. */
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

/* Hands every appended sample to the OS (fflush), leaving the file open and
 * its sizes unpatched. For a stream written in cycles, such as the capture
 * drain, whose checkpoint thread then syncs the file by its own descriptor.
 * Returns 1 while every write landed; a failed flush marks the writer
 * failed, so le_wav_seal reports it too. */
int le_wav_flush(le_wav_writer* w);

/* Patches the RIFF and data sizes, flushes, truncates the file to its header
 * plus data (a torn frame a short write left past the credited frames goes),
 * optionally fsyncs, and closes.
 * Returns 1 when the whole file (header, samples, sizes) is on disk. A data
 * size beyond 32 bits fails rather than writing a wrapped size. */
int le_wav_seal(le_wav_writer* w, int sync);

/* Closes without sealing (the caller unlinks the partial file). */
void le_wav_abandon(le_wav_writer* w);

/* Replaces `final_path` with `part_path` in one rename, then syncs the
 * containing directory (le_fs_sync_dir, #1198 Part 1) so the new entry is
 * durable. Returns 1 when both succeeded, 2 when the file is published but
 * the directory sync failed (the file is in place; its entry may not survive
 * a power cut), 0 when the rename failed (nothing was published). */
int le_wav_publish(const char* part_path, const char* final_path);

/* le_wav_patch_sizes, the repair of a part that was never sealed, is
 * exported: see segno_engine_api.h. */

/* The largest file one WAV may be (#1794): FAT32's largest file, 4 GiB less
 * one byte, which most USB sticks are formatted with. It also keeps the RIFF
 * size (the file less 8 bytes) within 32 bits. */
#define LE_WAV_MAX_FILE_BYTES UINT32_MAX

/* The header of a file this writer seals with no extra chunk: RIFF, `fmt `
 * and the `data` chunk's id and size. */
#define LE_WAV_PLAIN_HEADER_BYTES 44u

/* The most frames a file this writer seals with no extra chunk can hold at
 * `channels` wide, header included, within LE_WAV_MAX_FILE_BYTES. The
 * rendered stems' limit, which a performance take never runs past (#1747,
 * #1767, #1794). */
static inline uint64_t le_wav_max_frames(int32_t channels) {
  const uint64_t width = (uint64_t)(channels > 0 ? channels : 1) * 4u;
  return ((uint64_t)LE_WAV_MAX_FILE_BYTES - LE_WAV_PLAIN_HEADER_BYTES) / width;
}

/* The most frames le_wav_seal accepts in a file with no extra chunk at
 * `channels` wide: its RIFF size (the file less 8 bytes) within 32 bits.
 * One frame past le_wav_max_frames in stereo, two in mono: what a take an
 * earlier build captured to the RIFF limit renders to (#1794). */
static inline uint64_t le_wav_sealable_frames(int32_t channels) {
  const uint64_t width = (uint64_t)(channels > 0 ? channels : 1) * 4u;
  return ((uint64_t)UINT32_MAX - (LE_WAV_PLAIN_HEADER_BYTES - 8u)) / width;
}

#endif /* SEGNO_ENGINE_WAV_H */
