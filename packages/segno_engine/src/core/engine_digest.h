/*
 * engine_digest.h — streaming SHA-256 for the engine's own writers (#1198).
 *
 * The public, engine-free entry points (le_digest_bytes, le_digest_file,
 * le_fs_sync_dir) are declared in segno_engine_api.h. This header exposes the
 * incremental context so a writer that already holds the bytes (the
 * performance drain, which seals each recorded part with its digest) can hash
 * them as it writes instead of reading the file back.
 *
 * Included only by .c files, never by engine_private.h: a header reachable
 * from engine_private.h reaches every C++ translation unit of the VST3
 * builds (docs/PROGRESS.md, "Adding a header to src/core/"). This one is plain
 * C with no atomics, but keeping it out of that chain means it never has to be.
 */
#ifndef SEGNO_ENGINE_DIGEST_H
#define SEGNO_ENGINE_DIGEST_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define LE_SHA256_BYTES 32

/* SHA-256 (FIPS 180-4) state. Plain data: copy it to take a digest of a
 * prefix without disturbing the running context. */
typedef struct le_sha256_ctx {
  uint32_t state[8];
  uint64_t total_bytes;
  uint8_t block[64];
  size_t block_len;
} le_sha256_ctx;

void le_sha256_init(le_sha256_ctx* ctx);
void le_sha256_update(le_sha256_ctx* ctx, const void* data, size_t len);
/* Writes the 32-byte digest. The context must be re-initialised before reuse. */
void le_sha256_final(le_sha256_ctx* ctx, uint8_t out[LE_SHA256_BYTES]);

#ifdef __cplusplus
}
#endif

#endif /* SEGNO_ENGINE_DIGEST_H */
