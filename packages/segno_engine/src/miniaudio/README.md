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

The 13 markers split 9 / 4 between the two clusters below. If you are auditing
by hand, that split is the number to check against — a cluster that comes up
short is a patch that did not survive.

### 1. ALSA duplex data-loop hardening (appliance) — 9 markers

One `ma_bool8` state field (`segnoCaptureFlushPending`) added to the ALSA device
struct, plus eight code sites across `ma_device_start__alsa`,
`ma_device_wait__alsa`, `ma_device_read__alsa` and `ma_device_write__alsa` (two
markers each in `read`/`write`, for the arm/flush and the two xrun retries).
Together they make the direct-ALSA appliance path survive a real USB interface:

- a one-shot flush of the startup capture backlog on the first read;
- waiting on ALSA's own `snd_pcm_wait()` rather than the cached poll descriptors;
- a direction-dependent readiness threshold;
- xrun recovery that **retries** instead of tearing down the data loop, on both
  the capture (overrun) and playback (underrun) sides;
- self-healing a playback stream that has slipped behind the hardware pointer.

**Covered by tests?** Not directly — this is device-loop behaviour that needs
real hardware. It is bench-verified on the appliance.

### 2. PulseAudio failure-path `pa_context` leak (#721) — 4 markers

One explanatory block plus three calls, all in
`ma_init_pa_mainloop_and_pa_context__pulse`. That function has **two** failure
paths once the `pa_context` exists, and upstream freed the mainloop on both
while never `pa_context_unref`'ing the context. libpulse backs a `pa_context`'s
mempool with a `memfd_create("pulseaudio", …)` segment, so each failed
connection attempt permanently held one descriptor
(`/memfd:pulseaudio (deleted)`). On a host with no PulseAudio server, anything
probing on a timer walks the process into its `RLIMIT_NOFILE`.

The two paths are mutually exclusive on any given host, and each carries its own
patch line — so **check for both**, not just the first:

| path | condition | patch |
|---|---|---|
| `pa_context_connect` returns an error | nothing listening at all | `pa_context_unref` |
| the wait for the connection fails | a server answered, then failed | `pa_context_disconnect` + `pa_context_unref` |

The second needs the disconnect because a connect *was* issued; together they
match the success teardown in `ma_context_uninit__pulse`.

**Covered by tests?** Yes, both paths, in `src/test/test_engine_core.c`:

- `test_probing_leaks_no_fds` counts `/proc/self/fd` across 64 rounds of probing
  with no server present — the synchronous-connect-error path;
- `test_probing_leaks_no_fds_when_the_server_fails_mid_connect` stands up a fake
  PulseAudio server (a unix socket that accepts and immediately closes) and
  points `PULSE_SERVER` at it — the wait-failed path. Removing only that path's
  `pa_context_unref` grows the table by exactly one descriptor per round.

Both run **unpinned** for the same reason: the appliance's ALSA-only pin means
PulseAudio is never reached, so a pinned test would stay green with this whole
cluster reverted. The `native-tests` jobs install `libpulse0`, which is what
makes the first one able to fail at all.

One limit worth knowing: on a host with **no libpulse installed** miniaudio
never loads the backend and both tests skip (loudly). CI installs it explicitly
so that cannot happen there.

After any upgrade, check by hand as well:

```sh
grep -c "SEGNO PATCH" packages/segno_engine/src/miniaudio/miniaudio.h   # expect 13
```

with 9 in the ALSA cluster and 4 in the Pulse one.
