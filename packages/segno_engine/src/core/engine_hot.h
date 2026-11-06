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
 * LE_AUDIO_HOT puts a function in one ELF section, .text.hot.segno_audio,
 * on its own cache line. GNU ld's default script gathers .text.hot.* input
 * sections into one run at the start of .text (after only the cold, exit
 * and startup sections), in link order, each object's in the order its
 * compiler emitted them. So the hot code is contiguous, every hot function
 * starts on a line, and code added elsewhere moves the run only by whole
 * lines (through the cold sections ahead of it), never inside it. The
 * appliance's library (CMake, clang, GNU ld on Ubuntu 24.04:
 * deploy/rpi/build) and the GCC benches and tests link this way; lld and
 * mold need -z keep-text-section-prefix for it, which src/CMakeLists.txt
 * passes when it finds them.
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
#define LE_AUDIO_HOT __attribute__((section(".text.hot.segno_audio"), aligned(64)))
#define LE_AUDIO_HOT_PINNED 1
#else
#define LE_AUDIO_HOT
#endif

#endif /* LE_ENGINE_HOT_H */
