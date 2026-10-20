/* perf_checkpoint.h — durable two-slot checkpoints of a performance take
 * (#1198 D4, #727). Included only by perf_drain.c, which owns the thread and
 * publishes the progress this module writes down.
 *
 * A checkpoint says how much of the take is safely on the device. Writing
 * one: fdatasync every file the progress names (parts, events.log, layer
 * files), sync the take directory, then rewrite one of two fixed slot files,
 * `checkpoint-a.json` / `checkpoint-b.json`, in place (truncate, write,
 * fsync), alternating. A slot ends with `"checksum": "<hex>"`, the SHA-256 of
 * every byte before the `"checksum"` key; a reader takes the valid slot with
 * the higher `sequence`, so a torn slot leaves the other standing. Never a
 * rename: FAT and exFAT do not make a rename over a file atomic. */
#ifndef SEGNO_PERF_CHECKPOINT_H
#define SEGNO_PERF_CHECKPOINT_H

#include <stddef.h>
#include <stdint.h>

#include "engine_digest.h"    /* LE_SHA256_BYTES */
#include "segno_engine_api.h" /* LE_MAX_MONITORED_INPUTS */

#ifdef __cplusplus
extern "C" {
#endif

#define LE_PCP_MAX_STREAMS (1 + LE_MAX_MONITORED_INPUTS)
#define LE_PCP_PATH_MAX 1024

/* A sealed part, in the order the drain sealed it. The drain appends these
 * and never changes one it has published. */
typedef struct le_perf_sealed_part {
  int32_t stream;
  int32_t index;
  uint64_t frames;
  uint64_t overs;
  uint8_t sha256[LE_SHA256_BYTES];
} le_perf_sealed_part;

/* One stream as of the last flush: its open part, if any (open_index 0
 * means none, every part sealed). */
typedef struct le_pcp_stream {
  int32_t stream;
  int32_t channels;
  int32_t open_index;
  uint64_t open_frames;
  uint64_t open_overs;
} le_pcp_stream;

/* What the drain has flushed to the OS, published after each cycle. */
typedef struct le_pcp_progress {
  int32_t stream_count;
  le_pcp_stream streams[LE_PCP_MAX_STREAMS];
  int32_t sealed_count; /* entries of the take's sealed list now final */
  int32_t layer_count;  /* layer files written */
  uint64_t events_bytes;
  uint64_t frames; /* whole frames every stream holds */
  uint64_t overs;
} le_pcp_progress;

/* The fixed facts of a take, and the drain's append-only lists. */
typedef struct le_pcp_take {
  const char* capture_dir;
  const char* mirror_dir; /* NULL or "" for none */
  const uint8_t* take_id; /* 16 bytes */
  int64_t volume_generation;
  int32_t sample_rate;
  const char* boot_id;
  const le_perf_sealed_part* sealed;
  const char* layer_names; /* the first layer's file name */
  size_t layer_stride;     /* bytes from one layer's name to the next */
} le_pcp_take;

/* The writer's own state, one per take. */
typedef struct le_pcp_writer {
  uint64_t sequence;  /* of the last slot written */
  int next_slot;      /* 0 = a, 1 = b */
  int32_t synced_sealed;
  int32_t synced_layers;
  int slot_created[2];
  char* buf;
  size_t cap;
} le_pcp_writer;

/* `master-NNN.wav` for stream 0, `input-<n>-NNN.wav` for stream 1 + n. */
void le_perf_part_filename(int32_t stream, int32_t index, char* out,
                           size_t cap);

/* This boot's id (Linux /proc/sys/kernel/random/boot_id, macOS
 * kern.bootsessionuuid), or "" where the platform has none. */
void le_pcp_read_boot_id(char* out, size_t cap);

/* Allocates the slot buffer. Returns 0 on allocation failure. */
int le_pcp_writer_init(le_pcp_writer* w);
void le_pcp_writer_free(le_pcp_writer* w);

/* Writes one checkpoint of `progress`: the syncs, then the next slot in
 * capture_dir and, with a mirror, the same slot there. Advances to the other
 * slot only once the take's own slot is written, so a failure never touches
 * the slot that stands. Returns 1 when every step succeeded. */
int le_pcp_write(le_pcp_writer* w, const le_pcp_take* take,
                 const le_pcp_progress* progress);

#ifdef __cplusplus
}
#endif

#endif /* SEGNO_PERF_CHECKPOINT_H */
