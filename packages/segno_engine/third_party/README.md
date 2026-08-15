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
  suffice; ARM NEON is compile-time detected and needs no extra TU).
  `src/test/run_native_tests.sh` links the same list into the engine test
  suite for the vendor smoke test. The macOS SPM/CocoaPods forwarder TUs land
  with the restore worker (#697 S9), the first macOS consumer.

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
