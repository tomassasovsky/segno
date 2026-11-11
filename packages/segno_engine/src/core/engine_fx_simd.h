/*
 * engine_fx_simd.h — four-lane float and integer vectors for the effect
 * kernels (#1755).
 *
 * GCC and clang vector extensions, so one source runs as NEON on the
 * console and as SSE on an x86 host. A kernel uses them where it runs the
 * same arithmetic on several independent lines, lanes or taps at once: each
 * lane does what the scalar code did for its element, in the same order.
 * Where an expression has two products feeding one sum, the compilers
 * need not fuse the same one in vector code as in the scalar (GCC fuses the
 * other in b x - a y), so the product the scalar code rounds on its own is
 * spelled out with LE_ROUNDED. bench_fx_equiv checks every kind is
 * bit-identical.
 * Included by engine_fx.c only.
 */
#ifndef SEGNO_ENGINE_FX_SIMD_H
#define SEGNO_ENGINE_FX_SIMD_H

#include <float.h>
#include <stdint.h>

typedef float le_f4 __attribute__((vector_size(16)));
typedef uint32_t le_u4 __attribute__((vector_size(16)));
typedef double le_d2 __attribute__((vector_size(16)));
typedef double le_d4 __attribute__((vector_size(32))); /* two registers */
/* The same, at any float's alignment: what the loads and stores go
 * through. A vector of floats aliases floats only, so a store through one
 * does not make the compiler reload a kernel's other fields. */
typedef float le_f4_at __attribute__((vector_size(16), aligned(4)));
typedef uint32_t le_u4_at __attribute__((vector_size(16), aligned(4)));

static inline le_f4 le_f4_load(const float* p) { return *(const le_f4_at*)p; }

static inline void le_f4_store(float* p, le_f4 v) { *(le_f4_at*)p = v; }

static inline le_u4 le_u4_load(const uint32_t* p) {
  return *(const le_u4_at*)p;
}

static inline void le_u4_store(uint32_t* p, le_u4 v) { *(le_u4_at*)p = v; }

static inline le_f4 le_f4_set1(float x) { return (le_f4){x, x, x, x}; }

static inline le_u4 le_u4_set1(uint32_t x) { return (le_u4){x, x, x, x}; }

static inline le_d2 le_d2_set1(double x) { return (le_d2){x, x}; }

static inline le_d4 le_d4_set1(double x) { return (le_d4){x, x, x, x}; }

static inline le_d4 le_d4_of(le_f4 v) { return __builtin_convertvector(v, le_d4); }

/* Each lane rounded to float, as a (float) cast rounds it. */
static inline le_f4 le_f4_of(le_d4 v) { return __builtin_convertvector(v, le_f4); }

/* [v] where [m] is all ones, 0 where it is 0. */
static inline le_f4 le_f4_keep(le_f4 v, le_u4 m) {
  return (le_f4)((le_u4)v & m);
}

/* fx_sanitize on each lane: NaN and infinity to 0, and anything under
 * 1e-30 in magnitude (denormals included) to 0. */
static inline le_f4 le_f4_sanitize(le_f4 x) {
  const le_f4 a = (le_f4)((le_u4)x & le_u4_set1(0x7FFFFFFFu));
  const le_u4 keep = (le_u4)(a >= le_f4_set1(1e-30f)) &
                     (le_u4)(a <= le_f4_set1(FLT_MAX));
  return le_f4_keep(x, keep);
}

/* Makes vector [v] opaque to the optimiser, so the multiply that made it is
 * rounded on its own and never fused into a later add. In b x - a y, GCC
 * fuses b x in the scalar code but a y in the vector code; the scalar's
 * choice is spelled out with this on a y (clang fuses b x in both). */
#if defined(__aarch64__)
#define LE_ROUNDED(v) __asm__("" : "+w"(v))
#elif defined(__x86_64__)
#define LE_ROUNDED(v) __asm__("" : "+x"(v))
#else
#define LE_ROUNDED(v) ((void)0)
#endif

#endif /* SEGNO_ENGINE_FX_SIMD_H */
