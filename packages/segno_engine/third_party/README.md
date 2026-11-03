# Vendored third-party code

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
  user-supplied SDK step).

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
  shim with `-fvisibility=hidden`: Signalsmith is a common plugin dependency,
  so default-visibility exports could be interposed by a dlopen'd plugin's
  own copy, or interpose it. Determinism
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

The vendored VST3/CLAP SDKs are compiled into the engine only when
`SEGNO_ENABLE_PLUGINS` is defined: on for the macOS SPM and CocoaPods builds,
off for the Linux CMake build that the appliance uses. Third-party plugins are
rarely built for aarch64 Linux, so the appliance does not host them. The
`SEGNO_ENABLE_PLUGINS` environment variable overrides the CMake option.

Do not edit the vendored sources in place — they are upstream drops. To
upgrade, replace the folder(s) with a newer release and update the version(s)
above.

## License notices in the app

Flutter's license collector only reads Dart packages' `LICENSE` files, so none
of the code above reaches the app's open source notices on its own. The
engine package declares each license file as an asset (`pubspec.yaml`) and
`registerVendoredLicenses` (`lib/src/vendored_licenses.dart`) adds them to
`LicenseRegistry`; `runSegno` calls it once at startup. Vendoring a new
library means adding its license file to both lists; the app test
`test/app/vendored_licenses_test.dart` compares every registered entry with
the file on disk.

## Vendored code that does **not** live here: `src/miniaudio/`

miniaudio predates this directory and still sits at
[`../src/miniaudio/`](../src/miniaudio/). It is vendored the same way, but it is
**not a verbatim drop** — it carries local patches marked `SEGNO PATCH`, most of
which no test can catch if an upgrade reverts them. Its version, license, and
full patch index (including which patches ARE gated by a test, and under what
conditions) are recorded in
[`../src/miniaudio/README.md`](../src/miniaudio/README.md). Read that before
taking a newer miniaudio.
