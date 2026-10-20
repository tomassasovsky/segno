#ifndef SEGNO_TEST_PICO_SHA256_H
#define SEGNO_TEST_PICO_SHA256_H

// pico_sha256's interface over a plain software SHA-256 (FIPS 180-4), so the
// ring updater's digest check runs on the host. The hardware block has one
// user at a time; the fake enforces start/finish/cleanup pairing.
#include <cassert>
#include <cstddef>
#include <cstdint>
#include <cstring>

#ifndef PICO_OK
#define PICO_OK 0
#endif
#define SHA256_BIG_ENDIAN 1

typedef struct { uint8_t bytes[32]; } sha256_result_t;
typedef struct {
  uint32_t h[8];
  uint8_t block[64];
  size_t used;
  uint64_t total;
  bool locked;
} pico_sha256_state_t;

namespace fake_sha256 {
inline bool busy = false;
inline uint32_t rotr(uint32_t x, int n) { return x >> n | x << (32 - n); }
inline void compress(uint32_t h[8], const uint8_t *p) {
  static const uint32_t k[64] = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
  };
  uint32_t w[64];
  for (int i = 0; i < 16; ++i) w[i] = (uint32_t)p[4 * i] << 24 | p[4 * i + 1] << 16 | p[4 * i + 2] << 8 | p[4 * i + 3];
  for (int i = 16; i < 64; ++i) {
    const uint32_t s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3);
    const uint32_t s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10);
    w[i] = w[i - 16] + s0 + w[i - 7] + s1;
  }
  uint32_t a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7];
  for (int i = 0; i < 64; ++i) {
    const uint32_t t1 = hh + (rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)) + ((e & f) ^ (~e & g)) + k[i] + w[i];
    const uint32_t t2 = (rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)) + ((a & b) ^ (a & c) ^ (b & c));
    hh = g; g = f; f = e; e = d + t1; d = c; c = b; b = a; a = t1 + t2;
  }
  h[0] += a; h[1] += b; h[2] += c; h[3] += d; h[4] += e; h[5] += f; h[6] += g; h[7] += hh;
}
}  // namespace fake_sha256

inline int pico_sha256_try_start(pico_sha256_state_t *s, int endian, bool use_dma) {
  assert(endian == SHA256_BIG_ENDIAN && !use_dma);
  if (fake_sha256::busy) return -1;
  fake_sha256::busy = true;
  static const uint32_t init[8] = {0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
                                   0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19};
  memcpy(s->h, init, sizeof(init));
  s->used = 0;
  s->total = 0;
  s->locked = true;
  return PICO_OK;
}

inline void pico_sha256_update(pico_sha256_state_t *s, const uint8_t *data, size_t n) {
  assert(s->locked);
  s->total += n;
  while (n--) {
    s->block[s->used++] = *data++;
    if (s->used == 64) { fake_sha256::compress(s->h, s->block); s->used = 0; }
  }
}

inline void pico_sha256_update_blocking(pico_sha256_state_t *s, const uint8_t *data, size_t n) {
  pico_sha256_update(s, data, n);
}

inline void pico_sha256_cleanup(pico_sha256_state_t *s) {
  if (s->locked) fake_sha256::busy = false;
  s->locked = false;
}

inline void pico_sha256_finish(pico_sha256_state_t *s, sha256_result_t *out) {
  assert(s->locked);
  const uint64_t bits = s->total * 8;
  const uint8_t one = 0x80, zero = 0;
  const uint64_t total = s->total;
  pico_sha256_update(s, &one, 1);
  while (s->used != 56) pico_sha256_update(s, &zero, 1);
  for (int i = 7; i >= 0; --i) { const uint8_t b = (uint8_t)(bits >> (8 * i)); pico_sha256_update(s, &b, 1); }
  s->total = total;
  for (int i = 0; i < 8; ++i)
    for (int j = 0; j < 4; ++j) out->bytes[4 * i + j] = (uint8_t)(s->h[i] >> (24 - 8 * j));
  pico_sha256_cleanup(s);
}

#endif
