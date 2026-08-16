# `miniaudio/` — vendored miniaudio (the engine's audio device layer)

This directory is a **vendored third-party drop that is NOT verbatim.** It lives
under `src/` rather than `third_party/` for historical reasons (it predates that
directory), so this file carries the record the
[`third_party/README.md`](../../third_party/README.md) convention would
otherwise hold. Read it before upgrading.

- **Version:** miniaudio **0.11.21** (`MA_VERSION_MAJOR/MINOR/REVISION` near the
  top of [`miniaudio.h`](miniaudio.h)), from
  [mackron/miniaudio](https://github.com/mackron/miniaudio).
- **License:** dual **Unlicense (public domain)** / **MIT No Attribution**, at
  your option. The full text is kept intact at the bottom of `miniaudio.h`. Both
  are GPLv3-compatible, so this changes nothing about the repository's
  GPL-3.0-or-later posture.
- **Files:** `miniaudio.h` (the single-header library, patched — see below) and
  `miniaudio_impl.c` (ours, not upstream: the one TU that defines
  `MINIAUDIO_IMPLEMENTATION` and sets the `MA_NO_*` feature cuts).
- **Used by:** `src/CMakeLists.txt` compiles `miniaudio_impl.c` into
  `segno_engine`; `src/core/engine_miniaudio.c` is the device backend built on
  it. miniaudio `dlopen()`s its Linux backends at runtime, so there is no
  ALSA/Pulse/JACK link dependency.

## Local patches

Every deviation from the upstream drop is marked in-source with the string
`SEGNO PATCH`, so `grep -n "SEGNO PATCH" miniaudio.h` is always the
authoritative list. This index says what each cluster is FOR — grep tells you
where they are, this tells you why they must survive an upgrade.

**On upgrade: re-apply every cluster below, or prove upstream fixed it.** A
plain drop-in replacement silently reverts all of them.

### 1. ALSA duplex data-loop hardening (appliance)

Nine sites across `ma_device_start__alsa`, `ma_device_wait__alsa`,
`ma_device_read__alsa`, `ma_device_write__alsa`, plus one `ma_bool8` state field
(`segnoCaptureFlushPending`) added to the ALSA device struct. Together they make
the direct-ALSA appliance path survive a real USB interface:

- a one-shot flush of the startup capture backlog on the first read;
- waiting on ALSA's own `snd_pcm_wait()` rather than the cached poll descriptors;
- a direction-dependent readiness threshold;
- xrun recovery that **retries** instead of tearing down the data loop, on both
  the capture (overrun) and playback (underrun) sides;
- self-healing a playback stream that has slipped behind the hardware pointer.

**Covered by tests?** Not directly — this is device-loop behaviour that needs
real hardware. It is bench-verified on the appliance.

### 2. PulseAudio failure-path `pa_context` leak (#721)

`ma_init_pa_mainloop_and_pa_context__pulse` — both post-creation failure paths
freed the mainloop but never `pa_context_unref`'d the context. libpulse backs a
`pa_context`'s mempool with a `memfd_create("pulseaudio", …)` segment, so each
failed connection attempt permanently held one descriptor
(`/memfd:pulseaudio (deleted)`). On a host with no PulseAudio server, anything
probing on a timer walks the process into its `RLIMIT_NOFILE`. The patch adds
the missing `pa_context_unref` (and `pa_context_disconnect` where a connect was
actually issued), matching the success teardown in `ma_context_uninit__pulse`.

**Covered by tests?** Yes — `test_probing_leaks_no_fds` in
`src/test/test_engine_core.c` counts `/proc/self/fd` across 64 rounds of
probing and fails if it grows. It runs **unpinned** for exactly this reason: the
appliance's ALSA-only pin means PulseAudio is never reached, so a pinned test
would stay green with this patch reverted. The `native-tests` jobs install
`libpulse0` and run no PulseAudio server, which is the leaking condition.

Two limits worth knowing, because they decide whether the gate is real on a
given machine:

- on a host with **no libpulse installed**, miniaudio skips the backend and the
  test cannot fail — this is why CI installs it explicitly;
- on a host with a **running** PulseAudio/PipeWire-pulse server the connect
  succeeds, no failure path is taken, and the test again cannot fail. A
  developer's desktop is usually in this state; CI is not.

After any upgrade, check by hand as well:

```sh
grep -c "SEGNO PATCH" packages/segno_engine/src/miniaudio/miniaudio.h   # expect 13
```

and confirm `pa_context_unref` appears on both failure paths of
`ma_init_pa_mainloop_and_pa_context__pulse`.
