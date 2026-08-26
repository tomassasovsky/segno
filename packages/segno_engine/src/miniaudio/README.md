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

The 21 markers split 10 / 4 / 7 across the three clusters below. If you are
auditing by hand, that split is the number to check against — a cluster that
comes up short is a patch that did not survive.

### 1. ALSA duplex hardening (appliance) — 10 markers

One `ma_bool8` state field (`segnoCaptureFlushPending`) added to the ALSA device
struct, plus nine code sites across `ma_device_init_by_type__alsa`,
`ma_device_start__alsa`, `ma_device_wait__alsa`, `ma_device_read__alsa` and
`ma_device_write__alsa` (two markers each in `read`/`write`, for the arm/flush
and the two xrun retries). Together they make the direct-ALSA appliance path
survive a real USB interface:

- a one-shot flush of the startup capture backlog on the first read;
- waiting on ALSA's own `snd_pcm_wait()` rather than the cached poll descriptors;
- a direction-dependent readiness threshold;
- xrun recovery that **retries** instead of tearing down the data loop, on both
  the capture (overrun) and playback (underrun) sides;
- self-healing a playback stream that has slipped behind the hardware pointer;
- a playback `start_threshold` of **half the ring**, floored at the two periods
  full-duplex needs, instead of upstream's fixed two periods (#809) — so a
  caller asking for more `periods` gets a deeper cushion on the playback side
  and not only on the capture side.

That last one is the only marker in this cluster outside the data loop: it sits
in `ma_device_init_by_type__alsa`, in the `sw_params` block. It couples to the
slip-resync above — a resync restarts through that threshold, so raising it
lengthens each resync's silent gap — and the two carry cross-references to each
other. Note it is a no-op below 5 periods, where the two-period floor still
wins, so a `periods=2` host cannot tell whether it survived an upgrade.

**Covered by tests?** Not directly — this is ALSA device behaviour that needs
real hardware. It is bench-verified on the appliance. For the start threshold
that is the whole story: it lives inside a vendored 90k-line header, in a
function that only runs against a real ALSA device, so nothing on this repo's
macOS test host can reach it. **This registry is its coverage** — the marker
count below is the only thing that fails when a re-vendor drops it.

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

### 3. Backend-dropout hook (#722) — 7 markers

A typedef + `extern` declaration next to `ma_device_notification_proc`, the one
global definition at the top of the implementation section (outside every
backend guard, so it links on platforms with no ALSA), and five sites inside
`ma_device_read__alsa` / `ma_device_write__alsa`: the two per-call `reported`
latches and the three points that call out.

miniaudio's public API exposes **no** underrun/overrun signal. The ALSA data
loop knows about every one — it recovers from each `-EPIPE` itself — but the
only trace is an `ma_log` DEBUG line, and matching log strings is not an
instrument. Without this hook `le_snapshot.xrun_count` is permanently `0` on
Linux and macOS, which is the blind spot #722 exists to close. The three call
sites are the two `-EPIPE` recoveries of cluster 1 and its slipped-playback
resync — that last one because the stock stream raises **no** XRUN for a slip at
all (`stop_threshold` sits at the ring boundary, so an underrun just loops) yet
the drop+prepare is audible.

The `kind` integers `0/1/2` are pinned: `le_xrun_kind` in `segno_engine_api.h`
mirrors them one-for-one.

**Two rules that are easy to get wrong when re-applying:**

- **Install once, never retract.** The pointer is process-global; devices are
  not. Nulling it on device close needs a refcount, and a refcount whose pointer
  write sits outside the atomic RMW interleaves into `refs == 1, hook == NULL`,
  after which the surviving engine counts nothing for its whole session — the
  exact permanent-zero symptom the patch removes. `engine_miniaudio.c` installs
  it on first open and leaves it, and argues that out at length; there is no
  refcount there, whatever an older draft of the in-file comment implied.
- **One call per physical dropout.** Both `-EPIPE` branches sit inside a retry
  loop that `continue`s when recover/start loses its race, so a wedged device
  re-enters them repeatedly. Each read/write call reports at most once, via a
  local `segnoXrunReported` latch — otherwise one stuck stream manufactures
  thousands of counted xruns and thousands of cross-TU calls from the real-time
  thread.

All of this is compiled out by `-DLE_CALLBACK_TELEMETRY=0`, which
`miniaudio_impl.c` pulls in through `engine_telemetry_gate.h` **before**
including `miniaudio.h`.

**Covered by tests?** The hook's *call sites* are ALSA data-loop behaviour and
need real hardware, like cluster 1. Everything downstream of the hook is
covered in `src/test/test_engine_core.c` (`test_backend_xrun_kinds_tally_and_
reset` and the `test_cb_timing_*` suite), and the gate-off build is built AND
run by the `native-tests-telemetry-off` CI job, so the `#if` branches here
cannot rot silently.

## Not upstream's, not ours either

`#if 0` blocks (the disabled `ma_device_uninit` stop, the AVX helpers, the MMAP
path, …) are **upstream** miniaudio, not Segno patches — do not "restore" them.
`engine_miniaudio.c` documents the one that matters: because `ma_device_uninit`
does not stop a *running* data loop, the backend must call `ma_device_stop`
first.

## Auditing an upgrade

```sh
grep -c "SEGNO PATCH" packages/segno_engine/src/miniaudio/miniaudio.h   # expect 21
```

with 10 in the ALSA cluster, 4 in the Pulse one and 7 in the dropout hook.
