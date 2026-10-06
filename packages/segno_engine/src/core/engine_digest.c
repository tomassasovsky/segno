/*
 * engine_digest.c — SHA-256, file-range digests and directory sync (#1198).
 *
 * THREAD OWNERSHIP: none. Nothing here touches an engine: every function is
 * a question about bytes or about a path, so the Dart side may call the
 * public ones from a background isolate without an engine handle, and the
 * performance drain may hash on its own thread.
 *
 * Why these live in the engine: recorded audio is identified by the SHA-256
 * of its samples (plan docs/plan/2026-10-06-feat-recording-recovery-plan.md,
 * D6), the drain must hash the parts it writes without reading them back, and
 * Dart has no way to fsync a directory, which the atomic publication of a
 * bundle needs after its rename (D5). One implementation serves all three.
 *
 * The SHA-256 compression function is written directly from FIPS 180-4
 * (sections 4.1.2, 4.2.2, 5.3.3 and 6.2) and is checked against the
 * standard's own test vectors in test_engine_core.c.
 */
#include "engine_digest.h"

#include <errno.h>
#include <stdio.h>
#include <string.h>

#include "segno_engine_api.h"

#if defined(_WIN32)
#include <windows.h>
#else
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
#endif

/* ---- SHA-256 (FIPS 180-4) ---- */

static const uint32_t le_sha256_k[64] = {
    0x428a2f98u, 0x71374491u, 0xb5c0fbcfu, 0xe9b5dba5u, 0x3956c25bu,
    0x59f111f1u, 0x923f82a4u, 0xab1c5ed5u, 0xd807aa98u, 0x12835b01u,
    0x243185beu, 0x550c7dc3u, 0x72be5d74u, 0x80deb1feu, 0x9bdc06a7u,
    0xc19bf174u, 0xe49b69c1u, 0xefbe4786u, 0x0fc19dc6u, 0x240ca1ccu,
    0x2de92c6fu, 0x4a7484aau, 0x5cb0a9dcu, 0x76f988dau, 0x983e5152u,
    0xa831c66du, 0xb00327c8u, 0xbf597fc7u, 0xc6e00bf3u, 0xd5a79147u,
    0x06ca6351u, 0x14292967u, 0x27b70a85u, 0x2e1b2138u, 0x4d2c6dfcu,
    0x53380d13u, 0x650a7354u, 0x766a0abbu, 0x81c2c92eu, 0x92722c85u,
    0xa2bfe8a1u, 0xa81a664bu, 0xc24b8b70u, 0xc76c51a3u, 0xd192e819u,
    0xd6990624u, 0xf40e3585u, 0x106aa070u, 0x19a4c116u, 0x1e376c08u,
    0x2748774cu, 0x34b0bcb5u, 0x391c0cb3u, 0x4ed8aa4au, 0x5b9cca4fu,
    0x682e6ff3u, 0x748f82eeu, 0x78a5636fu, 0x84c87814u, 0x8cc70208u,
    0x90befffau, 0xa4506cebu, 0xbef9a3f7u, 0xc67178f2u};

static uint32_t le_rotr32(uint32_t x, unsigned n) {
  return (x >> n) | (x << (32u - n));
}

static void le_sha256_compress(uint32_t state[8], const uint8_t block[64]) {
  uint32_t w[64];
  for (int t = 0; t < 16; ++t) {
    w[t] = ((uint32_t)block[4 * t] << 24) | ((uint32_t)block[4 * t + 1] << 16) |
           ((uint32_t)block[4 * t + 2] << 8) | (uint32_t)block[4 * t + 3];
  }
  for (int t = 16; t < 64; ++t) {
    const uint32_t s0 =
        le_rotr32(w[t - 15], 7) ^ le_rotr32(w[t - 15], 18) ^ (w[t - 15] >> 3);
    const uint32_t s1 =
        le_rotr32(w[t - 2], 17) ^ le_rotr32(w[t - 2], 19) ^ (w[t - 2] >> 10);
    w[t] = w[t - 16] + s0 + w[t - 7] + s1;
  }
  uint32_t a = state[0], b = state[1], c = state[2], d = state[3];
  uint32_t e = state[4], f = state[5], g = state[6], h = state[7];
  for (int t = 0; t < 64; ++t) {
    const uint32_t big_s1 = le_rotr32(e, 6) ^ le_rotr32(e, 11) ^ le_rotr32(e, 25);
    const uint32_t ch = (e & f) ^ (~e & g);
    const uint32_t t1 = h + big_s1 + ch + le_sha256_k[t] + w[t];
    const uint32_t big_s0 = le_rotr32(a, 2) ^ le_rotr32(a, 13) ^ le_rotr32(a, 22);
    const uint32_t maj = (a & b) ^ (a & c) ^ (b & c);
    const uint32_t t2 = big_s0 + maj;
    h = g;
    g = f;
    f = e;
    e = d + t1;
    d = c;
    c = b;
    b = a;
    a = t1 + t2;
  }
  state[0] += a;
  state[1] += b;
  state[2] += c;
  state[3] += d;
  state[4] += e;
  state[5] += f;
  state[6] += g;
  state[7] += h;
}

void le_sha256_init(le_sha256_ctx* ctx) {
  static const uint32_t initial[8] = {0x6a09e667u, 0xbb67ae85u, 0x3c6ef372u,
                                      0xa54ff53au, 0x510e527fu, 0x9b05688cu,
                                      0x1f83d9abu, 0x5be0cd19u};
  memcpy(ctx->state, initial, sizeof(initial));
  ctx->total_bytes = 0;
  ctx->block_len = 0;
}

void le_sha256_update(le_sha256_ctx* ctx, const void* data, size_t len) {
  const uint8_t* p = (const uint8_t*)data;
  ctx->total_bytes += (uint64_t)len;
  if (ctx->block_len > 0) {
    const size_t take = 64 - ctx->block_len < len ? 64 - ctx->block_len : len;
    memcpy(ctx->block + ctx->block_len, p, take);
    ctx->block_len += take;
    p += take;
    len -= take;
    if (ctx->block_len < 64) return;
    le_sha256_compress(ctx->state, ctx->block);
    ctx->block_len = 0;
  }
  while (len >= 64) {
    le_sha256_compress(ctx->state, p);
    p += 64;
    len -= 64;
  }
  if (len > 0) {
    memcpy(ctx->block, p, len);
    ctx->block_len = len;
  }
}

void le_sha256_final(le_sha256_ctx* ctx, uint8_t out[LE_SHA256_BYTES]) {
  const uint64_t bit_len = ctx->total_bytes * 8u;
  /* Padding (5.1.1): one 0x80 byte, zeros to 56 mod 64, the 64-bit length. */
  ctx->block[ctx->block_len++] = 0x80;
  if (ctx->block_len > 56) {
    memset(ctx->block + ctx->block_len, 0, 64 - ctx->block_len);
    le_sha256_compress(ctx->state, ctx->block);
    ctx->block_len = 0;
  }
  memset(ctx->block + ctx->block_len, 0, 56 - ctx->block_len);
  for (int i = 0; i < 8; ++i) {
    ctx->block[56 + i] = (uint8_t)(bit_len >> (56 - 8 * i));
  }
  le_sha256_compress(ctx->state, ctx->block);
  for (int i = 0; i < 8; ++i) {
    out[4 * i] = (uint8_t)(ctx->state[i] >> 24);
    out[4 * i + 1] = (uint8_t)(ctx->state[i] >> 16);
    out[4 * i + 2] = (uint8_t)(ctx->state[i] >> 8);
    out[4 * i + 3] = (uint8_t)ctx->state[i];
  }
}

/* ---- public, engine-free entry points ---- */

int32_t le_digest_bytes(const void* data, uint64_t length, uint8_t* out) {
  if (out == NULL || (data == NULL && length > 0)) return LE_ERR_INVALID;
  if ((uint64_t)(size_t)length != length) return LE_ERR_INVALID;
  le_sha256_ctx ctx;
  le_sha256_init(&ctx);
  if (length > 0) le_sha256_update(&ctx, data, (size_t)length);
  le_sha256_final(&ctx, out);
  return LE_OK;
}

#if defined(_WIN32)
/* `path` is UTF-8 from Dart; the W entry points read it correctly whatever the
 * active ANSI code page is (the same reasoning as le_volume_space). */
static int le_digest_widen(const char* path, WCHAR* wide, int cap) {
  return MultiByteToWideChar(CP_UTF8, 0, path, -1, wide, cap) > 0;
}
#endif

#define LE_DIGEST_READ_CHUNK 65536

int32_t le_digest_file(const char* path, uint64_t offset, uint64_t length,
                       uint8_t* out) {
  if (path == NULL || path[0] == '\0' || out == NULL) return LE_ERR_INVALID;
  uint64_t size = 0;
  FILE* f = NULL;
#if defined(_WIN32)
  WCHAR wide[1024];
  if (!le_digest_widen(path, wide, (int)(sizeof(wide) / sizeof(wide[0])))) {
    return LE_ERR_INVALID;
  }
  f = _wfopen(wide, L"rb");
  if (f == NULL) return LE_ERR_DEVICE;
  if (_fseeki64(f, 0, SEEK_END) != 0) goto fail;
  const __int64 end = _ftelli64(f);
  if (end < 0) goto fail;
  size = (uint64_t)end;
#else
  f = fopen(path, "rb");
  if (f == NULL) return LE_ERR_DEVICE;
  struct stat st;
  if (fstat(fileno(f), &st) != 0 || !S_ISREG(st.st_mode)) goto fail;
  size = (uint64_t)st.st_size;
#endif
  if (offset > size) goto fail;
  /* UINT64_MAX reads to the end; any other length must lie inside the file —
   * a file shorter than the range it is supposed to hold is damaged, and a
   * digest of whatever happens to be there would be a lie about it. */
  const uint64_t available = size - offset;
  if (length == UINT64_MAX) {
    length = available;
  } else if (length > available) {
    goto fail;
  }
#if defined(_WIN32)
  if (_fseeki64(f, (__int64)offset, SEEK_SET) != 0) goto fail;
#else
  if (fseeko(f, (off_t)offset, SEEK_SET) != 0) goto fail;
#endif
  {
    le_sha256_ctx ctx;
    le_sha256_init(&ctx);
    uint8_t buf[LE_DIGEST_READ_CHUNK];
    uint64_t left = length;
    while (left > 0) {
      const size_t want =
          left < (uint64_t)sizeof(buf) ? (size_t)left : sizeof(buf);
      const size_t got = fread(buf, 1, want, f);
      if (got != want) goto fail; /* shrank underneath us, or a read error */
      le_sha256_update(&ctx, buf, got);
      left -= got;
    }
    le_sha256_final(&ctx, out);
  }
  fclose(f);
  return LE_OK;
fail:
  fclose(f);
  return LE_ERR_DEVICE;
}

int32_t le_fs_sync_dir(const char* path) {
  if (path == NULL || path[0] == '\0') return LE_ERR_INVALID;
#if defined(_WIN32)
  /* NTFS journals a rename as part of the operation; there is no directory
   * handle to flush the way POSIX needs one. Answer only whether the
   * directory exists, so callers see the same failure for a missing path on
   * every platform. */
  WCHAR wide[1024];
  if (!le_digest_widen(path, wide, (int)(sizeof(wide) / sizeof(wide[0])))) {
    return LE_ERR_INVALID;
  }
  const DWORD attrs = GetFileAttributesW(wide);
  if (attrs == INVALID_FILE_ATTRIBUTES || !(attrs & FILE_ATTRIBUTE_DIRECTORY)) {
    return LE_ERR_DEVICE;
  }
  return LE_OK;
#else
  /* A rename is durable only once the directory that holds the new entry is
   * synced; fsync on the file itself does not cover its name. */
#if defined(O_DIRECTORY)
  const int flags = O_RDONLY | O_DIRECTORY | O_CLOEXEC;
#else
  const int flags = O_RDONLY | O_CLOEXEC;
#endif
  const int fd = open(path, flags);
  if (fd < 0) return LE_ERR_DEVICE;
  int rc;
  do {
    rc = fsync(fd);
  } while (rc != 0 && errno == EINTR);
  close(fd);
  return rc == 0 ? LE_OK : LE_ERR_DEVICE;
#endif
}
