# Vendored third-party code

## `asiosdk/` — Steinberg ASIO SDK

- **Version:** ASIO SDK 2.3.3 (`asiosdk_2.3.3_2019-06-14`), vendored verbatim.
- **License:** governed by the Steinberg ASIO SDK Licensing Agreement, kept
  intact at
  [`asiosdk/Steinberg ASIO 2.3.3 Licensing Agreement V2.0.3 - 2023.pdf`](asiosdk/).
  This repository is licensed GPL-3.0-or-later; the SDK is redistributed under
  that agreement.
- **Why vendored:** ASIO is the only Windows path to a pro interface's full
  channel count, and is built **by default** on Windows. Vendoring makes the
  Windows build reproducible (no user-supplied SDK step). See
  [docs/WINDOWS_ASIO.md](../../../docs/WINDOWS_ASIO.md).
- **Used by:** `packages/segno_engine/src/CMakeLists.txt` compiles
  `common/asio.cpp`, `host/asiodrivers.cpp`, and `host/pc/asiolist.cpp` from
  here when `SEGNO_ENABLE_ASIO` is on (the Windows default).

Do not edit the SDK sources in place — they are an upstream drop. To upgrade,
replace the folder with a newer SDK release and update the version above.

## `vst3sdk/` — Steinberg VST3 SDK (plugin-hosting subset)

- **Version:** VST3 SDK `v3.8.0_build_66` (Oct 2025), assembled from the
  upstream modular repos at that tag:
  - [`pluginterfaces/`](vst3sdk/pluginterfaces/) — `steinbergmedia/vst3_pluginterfaces`
  - [`base/`](vst3sdk/base/) — `steinbergmedia/vst3_base`
  - [`public.sdk/source/`](vst3sdk/public.sdk/) — `steinbergmedia/vst3_public_sdk`
    (the `samples/` tree and VSTGUI are **not** vendored — Segno hosts plugins'
    own native editor windows via `IPlugView`, so VSTGUI is not needed).
- **License:** **MIT.** Each subtree keeps its upstream `LICENSE.txt`
  ([pluginterfaces](vst3sdk/pluginterfaces/LICENSE.txt),
  [base](vst3sdk/base/LICENSE.txt),
  [public.sdk](vst3sdk/public.sdk/LICENSE.txt)). VST3 relicensed to MIT with
  VST 3.8.
- **Why vendored:** makes the plugin-hosting build reproducible (no
  user-supplied SDK step), mirroring the ASIO approach above.

## `rnnoise/` — Xiph RNNoise (recurrent-neural-net noise suppression)

- **Version:** RNNoise `v0.2` (Apr 2024), vendored from the upstream release
  tarball (`rnnoise-0.2.tar.gz`, the GitHub release asset on
  [xiph/rnnoise](https://github.com/xiph/rnnoise/releases/tag/v0.2)). The
  release ships the trained model weights (`src/rnnoise_data.c`), trained on
  publicly available datasets, so no separate model download step exists.
- **License:** **BSD-3-Clause** ([`rnnoise/COPYING`](rnnoise/COPYING), kept
  intact); the bundled model weights carry the same license. BSD-3-Clause is
  GPLv3-compatible, so this changes nothing about the repository's
  GPL-3.0-or-later posture (see the posture note below) and adds no copyleft
  obligation of its own.
- **Local patch (the one deviation from a verbatim drop):** upstream v0.2 does
  not compile on ARM/NEON — `src/vec_neon.h` includes `os_support.h`, a file
  that does not exist anywhere at that tag
  ([xiph/rnnoise#222](https://github.com/xiph/rnnoise/issues/222)). The
  upstream fix, commit
  [`372f7b4b76`](https://github.com/xiph/rnnoise/commit/372f7b4b76)
  ("Fix compilation errors."), is applied on top; it touches exactly five
  headers (`src/common.h`, `src/vec.h`, `src/vec_avx.h`, `src/vec_neon.h`,
  `src/x86/x86cpu.h`) and the exact diff is kept at
  [`rnnoise/patches/372f7b4b76-fix-compilation-errors.patch`](rnnoise/patches/372f7b4b76-fix-compilation-errors.patch).
  Nothing else is modified. On upgrade, drop the patch if the release includes
  that commit; otherwise re-apply it and update this note.
- **Why vendored:** the offline loop-close restoration pass (#697) denoises
  finalized takes through `rnnoise_process_frame`. Vendoring keeps the build
  reproducible with no system package or model-download step, mirroring the
  SDKs above. Fixed contract worth knowing: RNNoise processes 480-sample
  frames at 48 kHz on 16-bit-scaled floats (the engine test suite asserts the
  frame size so an upgrade cannot silently change it).
- **Used by:** `packages/segno_engine/src/CMakeLists.txt` compiles the ten
  portable TUs from [`rnnoise/src/`](rnnoise/src/) into `segno_engine`
  (upstream `Makefile.am`'s `RNNOISE_SOURCES` minus the `RNN_ENABLE_X86_RTCD`
  block — the x86 SSE4.1/AVX2 run-time-dispatch TUs need configure-style
  compiler probing and the consumer is an offline pass, so the portable paths
  suffice; ARM NEON is compile-time detected and needs no extra TU). The TUs
  are compiled with `-fvisibility=hidden` (as upstream builds them): rnnoise's
  internals are generic unprefixed symbols (`parse_weights`, `linear_init`,
  ...), and exporting them from the shared engine would let a dlopen'd
  VST3/CLAP plugin that dynamically links its own librnnoise (Debian ships
  one) have them interposed — mismatched weight structs, wrong audio, or a
  crash inside the plugin.
  `src/test/run_native_tests.sh` links the same list into the engine test
  suite for the vendor smoke test. The macOS SPM/CocoaPods forwarder TUs land
  with the restore worker (#697 S9), the first macOS consumer.

## `signalsmith-stretch/` — Signalsmith Stretch (pitch-shift and time-stretch)

- **Version:** release tag `1.1.0`, commit `44c8f865af9da8c29cc4a70a2d5a3ec83639c711`
  (2025-01-29) of
  [Signalsmith-Audio/signalsmith-stretch](https://github.com/Signalsmith-Audio/signalsmith-stretch),
  a header-only C++11 library. Kept: `signalsmith-stretch.h`, the bundled
  `dsp/` subset of signalsmith-dsp it depends on, both licenses and READMEs.
  Stripped: `web/` (compiled JS and audio) and `cmd/` (the CLI example).
- **License:** **MIT** ([`signalsmith-stretch/LICENSE.txt`](signalsmith-stretch/LICENSE.txt),
  [`signalsmith-stretch/dsp/LICENSE.txt`](signalsmith-stretch/dsp/LICENSE.txt)),
  GPLv3-compatible; it changes nothing about the repository's
  GPL-3.0-or-later posture.
- **History:** vendored first under the bench harness only (July 2026 spike
  D0, `docs/plan/2026-07-22-time-stretch-spike-findings.md`); moved here into
  the real build by the pitch/time core Part 1 (#1179,
  `docs/plan/2026-10-06-feat-pitch-time-core-plan.md`), which also replaced
  that harness with `src/test/bench/bench_pitch_time.c`.
- **Why vendored:** it is the engine's pitch-preserving processor (Transpose,
  Audio & tempo follow with unchanged pitch, import Adapt). Header-only, so
  vendoring keeps every build self-contained with no package step.
- **Used by:** exactly one translation unit, `src/stretch/le_stretch.cpp`,
  the C ABI shim (`src/stretch/le_stretch.h`) the C engine, the offline
  renderer, the bench and the tests call. It includes the header relatively
  (`../../third_party/signalsmith-stretch/signalsmith-stretch.h`), so no
  include path is added to CMake, the podspec, `Package.swift` or
  `run_native_tests.sh`; those list the shim TU (CMake, compiled as C++17) or
  compile it with `$CXX` and link the C++ runtime. On Linux CMake compiles the
  shim with `-fvisibility=hidden`, for the RNNoise reason above. Determinism
  contract worth knowing: construct with a fixed seed; the native tests assert
  the two preset geometries (cheaper: block 0.1 s / interval 0.04 s; default:
  0.12 s / 0.03 s) so an upgrade cannot change them silently.

## `clap/` — CLAP plugin ABI (header-only)

- **Version:** CLAP `1.2.9`, headers only ([`clap/include/`](clap/include/)).
- **License:** **MIT** ([`clap/LICENSE`](clap/LICENSE)).
- **Why vendored:** CLAP is a header-only C ABI; vendoring keeps the build
  self-contained.

### License posture for plugin hosting (D-LICENSE)

Both the VST3 SDK (MIT, 3.8+) and CLAP (MIT) are permissively licensed, so they
are **clean for the engine core** and add no copyleft obligation of their own.
(The repository as a whole is GPL-3.0-or-later — see the root `LICENSE` — so the
combined binary stays GPLv3 regardless of platform; MIT inputs are compatible
with that and do not change it.)

They **do not change** the existing platform license posture:

- **Windows is already GPL-3.0-or-later** via the vendored Steinberg ASIO SDK
  above (built by default on Windows). Adding MIT VST3/CLAP does **not** worsen
  that — MIT is compatible with GPLv3.
- **macOS/Linux** ship the miniaudio backend (ASIO off), so the engine there
  carries only MIT third-party code for plugin hosting.

The vendored VST3/CLAP SDKs are compiled into the engine only when
`SEGNO_ENABLE_PLUGINS` is defined — ON by default for the macOS SPM/CocoaPods
builds and for the **Windows** CMake build (part 8: `LoadLibrary`-based scan +
host with an HWND editor window). It stays OFF for the **Linux** CMake build
until the X11 port (part 9). The `SEGNO_ENABLE_PLUGINS` env override disables it
for a non-plugin Windows build. The MIT VST3/CLAP code does not change the
Windows GPLv3 posture (already GPLv3 via the ASIO SDK above).

Do not edit the vendored sources in place — they are upstream drops (plus, for
`rnnoise/`, the one documented patch above). To upgrade, replace the folder(s)
with a newer release, re-apply any still-needed documented patches, and update
the version(s) above.

## License notices in the app

Flutter's license collector only reads Dart packages' `LICENSE` files, so none
of the code above reaches the app's open source notices on its own. The
engine package declares each license file as an asset (`pubspec.yaml`) and
`registerVendoredLicenses` (`lib/src/vendored_licenses.dart`) adds them to
`LicenseRegistry`; `runSegno` calls it once at startup. Vendoring a new
library means adding its license file to both lists; the app test
`test/app/vendored_licenses_test.dart` compares every registered entry with
the file on disk. The ASIO SDK is not listed: it is compiled only into the
Windows build, and what its agreement asks of a distribution is a separate
question (follow-up on #1179).

## Vendored code that does **not** live here: `src/miniaudio/`

miniaudio predates this directory and still sits at
[`../src/miniaudio/`](../src/miniaudio/). It is vendored the same way, but it is
**not a verbatim drop** — it carries local patches marked `SEGNO PATCH`, most of
which no test can catch if an upgrade reverts them. Its version, license, and
full patch index (including which patches ARE gated by a test, and under what
conditions) are recorded in
[`../src/miniaudio/README.md`](../src/miniaudio/README.md). Read that before
taking a newer miniaudio.
