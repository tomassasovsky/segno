# Builds the segno_engine_core native audio engine as a shared library that the
# Flutter FFI plugin bundles. Consumed by the linux/ and windows/ plugin
# CMakeLists via add_subdirectory; macOS/iOS compile these same sources through
# the CocoaPods podspec instead.
#
# Sources are grouped into subdirectories by concern: core/ (the portable engine
# + primitives + the public ABI header), platform/ (the per-OS device seams),
# midi/ (the MIDI input/output seam), and
# miniaudio/ (the vendored backend). Every subdirectory with headers is on the
# include path below, so sources keep using flat `#include "x.h"`.
cmake_minimum_required(VERSION 3.15)
project(segno_engine_core VERSION 0.1.0 LANGUAGES C)

# --- segno_dsp_core: the effects DSP, split out as its own STATIC library so a
# second target (the future VST3 plugin builds, parts 2/3) can link engine_fx.c
# without duplicating the source file. Source reorganization only — no change
# to segno_engine's public behavior, ABI, or output.
#
# Link-seam gotcha: engine_fx.c's LE_FX_PLUGIN row (fx_plugin_process) calls
# le_plugin_slot_process() unconditionally, with no #ifdef guard, so any
# target linking segno_dsp_core has an unresolved symbol unless it also links
# something that defines it. segno_engine gets this for free below (it links
# either host/slot.cpp when SEGNO_ENABLE_PLUGINS is on, or the stub in
# core/plugin_disabled.c when it's off) — parts 2/3 must link the stub too.
add_library(segno_dsp_core STATIC
  core/engine_fx.c
)

# Matches segno_engine's own C_STANDARD/atomics configuration below: this
# static lib ends up embedded in multiple .so/.dll/.dylib outputs, so PIC is
# set explicitly rather than relying on it propagating from consumers.
set_target_properties(segno_dsp_core PROPERTIES
  C_STANDARD 11
  C_STANDARD_REQUIRED ON
  POSITION_INDEPENDENT_CODE ON
)

# engine_fx.c's own includes ("engine_fx.h", "engine_internal.h", "fft.h") are
# flat quote-includes resolved relative to its own directory (core/); the
# exceptions are engine_private.h -> miniaudio.h (one level over, in
# miniaudio/), engine_private.h -> le_midi_clock.h (C1, one level over, in
# midi/ — struct le_engine embeds a le_midi_clock_gen field), and engine_fx.c's
# own `#include "../host/plugin_slot.h"` (resolved relative to the including
# file regardless of -I flags).
#
# PUBLIC (not PRIVATE): a consumer that links segno_dsp_core needs these same
# directories on its own include path to `#include "engine_fx.h"` (the whole
# point of the split — parts 2/3's VST3 targets link segno_dsp_core PRIVATE
# and drive the DSP through engine_fx.h's public seam). PRIVATE here would
# silently fail to propagate through target_link_libraries and break that
# include the moment a consumer target is added.
target_include_directories(segno_dsp_core PUBLIC
  "${CMAKE_CURRENT_SOURCE_DIR}/core"
  "${CMAKE_CURRENT_SOURCE_DIR}/miniaudio"
  "${CMAKE_CURRENT_SOURCE_DIR}/midi"
)

# Verified via `nm -u` on the built object: segno_dsp_core's only unresolved
# symbols are libc/libm (calloc/free/sinf/cosf/tanf/tanhf/atan2f/expf/logf/
# powf, plus the compiler-inserted stack-protector/memcpy-check builtins) and
# le_plugin_slot_process (the link-seam gotcha above). If a future change to
# engine_fx.c (or a header it pulls in) adds a new external dependency, this
# list goes stale — re-run `nm -u` on the object and update both this comment
# and D-LINK's consumer list (parts 2/3) if so.

add_library(segno_engine SHARED
  # ---- core/: the portable engine (S1 split into per-concern TUs) ----
  core/engine.c              # residual control-thread core + shared helpers
  core/engine_convert.c      # pure sample-format conversion
  # core/engine_fx.c lives in segno_dsp_core above (linked PRIVATE below) so a
  # second target (future VST3 plugin builds) can link it too.
  core/engine_session.c      # session export / import / commit
  core/engine_devices.c      # device discovery, loopback, id resolution, backend
  core/engine_snapshot.c     # published-state snapshots + visualization reads
  core/engine_process.c      # THE audio-thread TU (le_engine_process + transport)
  core/engine_commands.c     # control-thread command producers
  core/engine_cache.c        # Loop-stage wet cache (scheduler + render worker)
  core/engine_cond.c         # per-input conditioning stage (input conditioning)
  # Offline loop-close restoration DSP (#697 S8) — pure TUs, no engine state;
  # consumed by the restore worker (engine_restore.c, S9). NOT matched by
  # run_native_tests.sh's engine*.c glob — they are listed explicitly there;
  # keep the two lists in sync.
  core/restore_declip.c      # de-clip: flat-run detect + spline/Burg-AR repair
  core/restore_halfband.c    # 2:1 half-band resample (RNNoise's 48 k leg)
  # The miniaudio device backend (le_device_backend.h), compiled unconditionally
  # — the only device backend this build ships; another backend slots in behind
  # le_select_backend.
  core/engine_miniaudio.c
  core/lockfree_ring.c
  core/loop_clock.c
  core/tempo_grid.c          # pure-value tempo/bar/subdivision math
  core/audio_ring.c          # float SPSC ring (performance-recording capture)
  core/perf_log_ring.c       # perf event log: SPSC ring of frame-tagged le_command entries
  core/layer_staging_ring.c  # retired-layer PCM staging ring (persist before pool eviction)
  core/perf_drain.c          # perf-capture drain thread: rings -> raw PCM + sidecar
  core/json_read.c           # minimal read-only JSON parser (performance.json)
  core/perf_render.c         # offline renderer: replay capture dir -> dry stems
  # Control-thread plugin-slot lifecycle (load/clear + quiescent handshake).
  # Always compiled; calls le_plugin_slot_create which is the real host on a
  # plugin build and a NULL-returning stub otherwise.
  core/engine_plugin.c
  # le_plugin_* stubs for non-SEGNO_ENABLE_PLUGINS builds (Linux today; macOS
  # compiles the real host). Internally #ifndef-guarded, so it
  # compiles to an empty object when plugins are enabled and
  # host/plugin_scan.cpp + host/slot.cpp provide the real symbols.
  core/plugin_disabled.c
  # ---- platform/: per-OS device seams (engine_platform.h) ----
  # Each is wrapped whole in its OS guard, so the one that doesn't match the
  # build target compiles to a near-empty object — every build lists both.
  # Linux is the appliance; macOS remains only as a development host.
  platform/engine_linux.c
  platform/engine_apple.c
  # ---- midi/: native USB MIDI seam (le_midi_backend.h) ----
  # midi.c is the portable core (ring + parser + FFI surface, no OS MIDI
  # headers); both backend TUs are OS-guarded like the platform seam.
  midi/midi.c
  midi/midi_backend_linux.c
  midi/midi_backend_apple.c
  # le_midi_clock.c (C1, D15) is pure-value tempo/PPQN math, like
  # core/tempo_grid.c above — it lives in midi/ (per the plan's file
  # placement) but is a portable ENGINE dependency (engine_process.c calls
  # le_midi_clock_advance every block), not an OS MIDI backend.
  midi/le_midi_clock.c
  # ---- miniaudio/: the vendored backend ----
  miniaudio/miniaudio_impl.c
)

# C11 gives us <stdatomic.h> for the lock-free ring and snapshot publication.
set_target_properties(segno_engine PROPERTIES
  C_STANDARD 11
  C_STANDARD_REQUIRED ON
  OUTPUT_NAME "segno_engine"
)

# Every subdirectory holding headers is on the include path, so sources keep
# their flat `#include "engine_private.h"` / "miniaudio.h" / "le_midi_backend.h"
# form regardless of which folder they (or the includer) live in.
target_include_directories(segno_engine PRIVATE
  "${CMAKE_CURRENT_SOURCE_DIR}"
  "${CMAKE_CURRENT_SOURCE_DIR}/core"
  "${CMAKE_CURRENT_SOURCE_DIR}/midi"
  "${CMAKE_CURRENT_SOURCE_DIR}/miniaudio"
)

# engine_fx.c's object code now arrives via segno_dsp_core instead of a direct
# compile; PRIVATE keeps the static lib an implementation detail (it does not
# leak into segno_engine's own public link interface).
target_link_libraries(segno_engine PRIVATE segno_dsp_core)

# DART_SHARED_LIB keeps the FFI-exported symbols visible in the stripped release
# library (mirrors the flutter plugin_ffi template contract).
target_compile_definitions(segno_engine PUBLIC DART_SHARED_LIB)

if(UNIX AND NOT APPLE)
  # miniaudio dlopen()s ALSA/PulseAudio/JACK at runtime; we only need libc bits.
  find_package(Threads REQUIRED)
  target_link_libraries(segno_engine PRIVATE Threads::Threads ${CMAKE_DL_LIBS} m)
  # The ALSA-sequencer MIDI backend (midi_backend_linux.c) links libasound
  # directly (unlike miniaudio, which dlopen()s it). Needs libasound2-dev.
  find_package(ALSA REQUIRED)
  target_link_libraries(segno_engine PRIVATE ALSA::ALSA)
endif()

# The CocoaPods (macOS/iOS) build compiles these sources via the podspec, not
# CMake, and links CoreMIDI there. This APPLE branch only matters if the engine
# is ever built through CMake on Apple (e.g. the native test harness).
if(APPLE)
  target_link_libraries(segno_engine PRIVATE "-framework CoreMIDI"
    "-framework CoreFoundation")
endif()

# --- RNNoise (vendored, BSD-3-Clause) ---------------------------------------
#
# Xiph RNNoise v0.2, vendored under third_party/rnnoise (see
# third_party/README.md for version/license/patch provenance). It backs the
# offline loop-close restoration pass (issue #697): the restore worker (S9)
# denoises finalized takes through rnnoise_process_frame. Compiled
# unconditionally — it is small, portable C with no OS dependency, and unlike
# the plugin SDK it has no per-platform reason to be optional.
#
# Source list = upstream Makefile.am's RNNOISE_SOURCES *without* the
# RNN_ENABLE_X86_RTCD block (src/x86/*.c): the run-time SSE4.1/AVX2 dispatch
# needs configure-style compiler probing this build does not do, and the
# consumer is an offline (non-RT) pass, so the portable C paths are fast
# enough. NEON on ARM comes for free via vec_neon.h (compile-time detected).
# Keep run_native_tests.sh's rnnoise list in sync with this one.
get_filename_component(SEGNO_RNNOISE_DIR
  "${CMAKE_CURRENT_SOURCE_DIR}/../third_party/rnnoise" ABSOLUTE)
if(NOT EXISTS "${SEGNO_RNNOISE_DIR}")
  message(FATAL_ERROR
    "The vendored RNNoise sources are missing at ${SEGNO_RNNOISE_DIR} "
    "(a broken or partial checkout?). Restore them. See third_party/README.md.")
endif()
target_sources(segno_engine PRIVATE
  "${SEGNO_RNNOISE_DIR}/src/denoise.c"
  "${SEGNO_RNNOISE_DIR}/src/rnn.c"
  "${SEGNO_RNNOISE_DIR}/src/pitch.c"
  "${SEGNO_RNNOISE_DIR}/src/kiss_fft.c"
  "${SEGNO_RNNOISE_DIR}/src/celt_lpc.c"
  "${SEGNO_RNNOISE_DIR}/src/nnet.c"
  "${SEGNO_RNNOISE_DIR}/src/nnet_default.c"
  "${SEGNO_RNNOISE_DIR}/src/parse_lpcnet_weights.c"
  "${SEGNO_RNNOISE_DIR}/src/rnnoise_data.c"
  "${SEGNO_RNNOISE_DIR}/src/rnnoise_tables.c"
)
# The public header dir plus the vendored src dir: on x86 hosts vec.h pulls
# vec_avx.h, which includes src/x86/x86cpu.h, whose `#include "common.h"`
# resolves against src/x86/ and misses the header one level up (upstream
# builds with src/ on the path for the same reason). Listed after the
# engine's own dirs so engine headers win any future clash.
# Otherwise the rnnoise TUs resolve their internal headers relative to their
# own directory (quote-includes).
target_include_directories(segno_engine PRIVATE
  "${SEGNO_RNNOISE_DIR}/include"
  "${SEGNO_RNNOISE_DIR}/src"
)
# Compile the vendored TUs with hidden visibility (upstream builds with
# -fvisibility=hidden too): with default visibility the shared segno_engine
# would export rnnoise's generic unprefixed internals (parse_weights,
# linear_init, compute_glu, ...), and a dlopen'd VST3/CLAP plugin dynamically
# linked against its own librnnoise (Debian ships one) could have them
# interposed — mismatched weight structs, wrong audio, or a crash inside the
# plugin. Scoped to these sources only, so the FFI-visible le_* API keeps its
# LE_EXPORT default visibility.
set_source_files_properties(
  "${SEGNO_RNNOISE_DIR}/src/denoise.c"
  "${SEGNO_RNNOISE_DIR}/src/rnn.c"
  "${SEGNO_RNNOISE_DIR}/src/pitch.c"
  "${SEGNO_RNNOISE_DIR}/src/kiss_fft.c"
  "${SEGNO_RNNOISE_DIR}/src/celt_lpc.c"
  "${SEGNO_RNNOISE_DIR}/src/nnet.c"
  "${SEGNO_RNNOISE_DIR}/src/nnet_default.c"
  "${SEGNO_RNNOISE_DIR}/src/parse_lpcnet_weights.c"
  "${SEGNO_RNNOISE_DIR}/src/rnnoise_data.c"
  "${SEGNO_RNNOISE_DIR}/src/rnnoise_tables.c"
  PROPERTIES COMPILE_OPTIONS "-fvisibility=hidden")

# --- VST3 + CLAP plugin hosting (vendored SDK include roots) ----------------
#
# Plugin hosting (third_party/vst3sdk + third_party/clap, both MIT — see
# third_party/README.md) is macOS-only today: the macOS build (SPM
# Package.swift / CocoaPods podspec) defines SEGNO_ENABLE_PLUGINS and compiles
# the host sources directly. On Linux this is OFF; the engine then links only
# the le_plugin_scan_* stub (core/plugin_scan_disabled.c, above) so FFI
# resolves, and the build stays byte-identical apart from that stub.
#
# The appliance is aarch64 Linux, where third-party plugins are effectively
# unavailable (vendors do not ship arm64 Linux builds), so enabling this here
# would buy nothing today — see the product call on issue #920.
option(SEGNO_ENABLE_PLUGINS "Build VST3/CLAP plugin hosting" OFF)

# The Flutter build drives CMake through the plugin and cannot forward -D cache
# flags, so honor an env override applied after option().
if(DEFINED ENV{SEGNO_ENABLE_PLUGINS} AND NOT "$ENV{SEGNO_ENABLE_PLUGINS}" STREQUAL "")
  set(SEGNO_ENABLE_PLUGINS "$ENV{SEGNO_ENABLE_PLUGINS}")
endif()

# Vendored and used as-is — fixed (non-configurable) paths normalized to an
# absolute location every configure, so they can never go stale.
get_filename_component(SEGNO_VST3_SDK_DIR
  "${CMAKE_CURRENT_SOURCE_DIR}/../third_party/vst3sdk" ABSOLUTE)
get_filename_component(SEGNO_CLAP_DIR
  "${CMAKE_CURRENT_SOURCE_DIR}/../third_party/clap/include" ABSOLUTE)

if(SEGNO_ENABLE_PLUGINS)
  if(NOT EXISTS "${SEGNO_VST3_SDK_DIR}" OR NOT EXISTS "${SEGNO_CLAP_DIR}")
    message(FATAL_ERROR
      "SEGNO_ENABLE_PLUGINS=ON but the vendored VST3/CLAP SDKs are missing under "
      "${CMAKE_CURRENT_SOURCE_DIR}/../third_party (a broken or partial checkout?). "
      "Restore them. See third_party/README.md.")
  endif()
  # The VST3 SDK is C++; CLAP is a C header API consumed from C++.
  enable_language(CXX)
  target_include_directories(segno_engine PRIVATE
    "${SEGNO_VST3_SDK_DIR}"
    "${SEGNO_CLAP_DIR}"
  )
  target_compile_definitions(segno_engine PRIVATE SEGNO_ENABLE_PLUGINS)
  # The scan ABI + thread and the two format backends, plus the three vendored
  # IID translation units the host queryInterface()s against (the same set the
  # macOS podspec compiles via its vst3_*iids.cpp forwarders):
  #   - coreiids.cpp    : pluginterfaces base IIDs (IComponent / scanning).
  #   - commoniids.cpp  : the GUI IIDs (IPlugView / IPlugFrame) the editor needs.
  #   - vstinitiids.cpp : the VST-domain class IIDs (IAudioProcessor / …).
  # The backends' directory walkers + bundle loading are implemented for macOS
  # (part 8); Linux compiles to empty.
  target_sources(segno_engine PRIVATE
    host/plugin_scan.cpp
    host/scan_vst3.cpp
    host/scan_clap.cpp
    host/slot.cpp
    host/host_vst3.cpp
    host/host_clap.cpp
    "${SEGNO_VST3_SDK_DIR}/pluginterfaces/base/coreiids.cpp"
    "${SEGNO_VST3_SDK_DIR}/public.sdk/source/common/commoniids.cpp"
    "${SEGNO_VST3_SDK_DIR}/public.sdk/source/vst/vstinitiids.cpp"
  )
  set_target_properties(segno_engine PROPERTIES CXX_STANDARD 17
    CXX_STANDARD_REQUIRED ON)
endif()
