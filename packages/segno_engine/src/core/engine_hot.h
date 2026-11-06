/*
 * engine_hot.h — where the audio callback's hot code lives (#1718).
 *
 * The callback's frame loop spends nearly all its time in a handful of
 * out-of-line functions: le_engine_process, mix_tracks_frame, the read
 * heads, the chain driver and the per-block snapshots. Their speed depends
 * on where they land: GCC and clang align a function or a loop only when the
 * padding is short, so code linked anywhere before them moves their loops
 * across fetch and cache-line boundaries. On CI's arm64 bench the 64-lane
 * mixer measured from 24.2 % to 25.2 % of its budget with the same
 * instructions, depending only on what was linked ahead of it.
 *
 * LE_AUDIO_HOT_AT(n) puts a function in one ELF section,
 * .text.hot.segno_audio, at a fixed place on a cache line of its own: its
 * entry 4 * n bytes into a 64-byte line (aligned(64), then n NOPs ahead of
 * the entry with patchable_function_entry). GNU ld's default script gathers
 * .text.hot.* input sections into one run at the start of .text (after only
 * the cold, exit and startup sections), in link order, each object's in the
 * order its compiler emitted them. So the hot code is contiguous, every hot
 * function sits at the same offset in its line on every build, and code
 * added elsewhere moves the run only by whole lines, never inside it. The
 * appliance's library (CMake, clang, GNU ld on Ubuntu 24.04:
 * deploy/rpi/build) and the GCC benches and tests link this way; lld and
 * mold need -z keep-text-section-prefix for it, which src/CMakeLists.txt
 * passes when it finds them.
 *
 * The offsets are the ones the trunk's linker happened to give these
 * functions when CI's arm64 bench measured the 64-lane mixer at 24.2 % of
 * its budget (mix_tracks_frame 0x10, le_head_read 0x34, ...): a line-aligned
 * entry for every function measured 25.0 %, so where in its line a loop
 * starts matters, and these keep the measured one.
 *
 * Only translation units that define LE_AUDIO_TU before their first include
 * pin their functions (engine_process.c, engine_fx.c), so the read heads'
 * copies in other units (the renderer, the cache) stay out of the section
 * and cannot move what is in it; each of those units checks that it did
 * (LE_AUDIO_HOT_PINNED). A no-op on Mach-O (the macOS development build) and
 * MSVC.
 */
#ifndef LE_ENGINE_HOT_H
#define LE_ENGINE_HOT_H

#if defined(LE_AUDIO_TU) && defined(__ELF__) && \
    (defined(__GNUC__) || defined(__clang__))
#define LE_AUDIO_HOT_AT(n)                                       \
  __attribute__((section(".text.hot.segno_audio"), aligned(64), \
                 patchable_function_entry((n), (n))))
#define LE_AUDIO_HOT_PINNED 1
#else
#define LE_AUDIO_HOT_AT(n)
#endif

#endif /* LE_ENGINE_HOT_H */
