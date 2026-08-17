# Vendored miniaudio — and the patches Segno carries on top

- **Version:** miniaudio `v0.11.21` (2023-11-15), single-header, vendored as
  `miniaudio.h`. Compiled exactly once, by `miniaudio_impl.c`.
- **License:** public domain (Unlicense) or MIT-0, at your option — the license
  statements are kept intact at the end of `miniaudio.h`. Compatible with this
  repository's GPL-3.0-or-later posture and adding no obligation of its own.
- **Why vendored rather than a submodule/package:** it is one header, the build
  has to reach it from six different build descriptions (CMake, the CocoaPods
  podspec forwarders, the SPM target, the native test runner, …), and — the
  reason that actually decides it — **it is patched**. See below.

`miniaudio.h` is **not** a verbatim drop. Every deviation is marked in-file with
a `SEGNO PATCH` comment; `grep -n "SEGNO PATCH" miniaudio.h` is the
authoritative list. This file is the *record*: what each one is for, so a
version bump can re-apply them deliberately instead of rediscovering the bugs.

**Upgrading:** drop in the new upstream header, then walk this table and
re-apply each patch, reading its in-file comment first. Do not diff-apply
blindly — several of these sit inside retry loops whose shape upstream changes.

## The patches

### 1. Backend-dropout hook (`ma_segno_xrun_proc` / `ma_segno_xrun_callback`) — #722

| Site | What |
| --- | --- |
| near `ma_device_notification_proc` | typedef + `extern` declaration, with the full contract |
| top of the implementation section | the one global definition, outside every backend guard so it links where there is no ALSA |
| `ma_device_read__alsa` | reports `kind = 1` (capture overrun) at the `-EPIPE` recovery |
| `ma_device_write__alsa` | reports `kind = 0` (playback underrun) at the `-EPIPE` recovery |
| `ma_device_write__alsa` | reports `kind = 2` (playback resync) at the slipped-playback drop+prepare of patch 4 |

**Why:** miniaudio's public API exposes **no** underrun/overrun signal. The ALSA
data loop knows about every one of them — it recovers from each `-EPIPE`
itself — but the only trace is an `ma_log` DEBUG line, and matching log strings
is not an instrument. Without this hook `le_snapshot.xrun_count` is permanently
`0` on Linux and macOS, which is the blind spot #722 exists to close.

**Two rules that are easy to get wrong when re-applying:**

- **Install once, never retract.** The pointer is process-global; devices are
  not. Nulling it on device close needs a refcount, and a refcount whose pointer
  write sits outside the atomic RMW interleaves into `refs == 1, hook == NULL`,
  after which the surviving engine counts nothing for its whole session — the
  exact permanent-zero symptom the patch removes. `engine_miniaudio.c`
  deliberately installs it on first open and leaves it; there is no refcount
  there, whatever an older draft of the in-file comment implied.
- **One call per physical dropout.** Both `-EPIPE` branches sit inside a retry
  loop that `continue`s when recover/start loses its race, so a wedged device
  re-enters them repeatedly. Each read/write call reports at most once, via a
  local `segnoXrunReported` latch — otherwise one stuck stream manufactures
  thousands of counted xruns and thousands of cross-TU calls from the real-time
  thread.

The `kind` integers `0/1/2` are pinned: `le_xrun_kind` in `segno_engine_api.h`
mirrors them one-for-one. All of this is compiled out by
`-DLE_CALLBACK_TELEMETRY=0`, which `miniaudio_impl.c` pulls in through
`engine_telemetry_gate.h` **before** including this header. CI builds and runs
that configuration (`native-tests-telemetry-off`), so the `#if` branches cannot
rot silently.

### 2. One-shot startup capture flush

`ma_bool8 segnoCaptureFlushPending` on the device + the arm in
`ma_device_start__alsa` + the drain in `ma_device_read__alsa`. The capture
stream accumulates a backlog between `snd_pcm_start` and the first read; without
dropping it once, the whole session runs a fixed extra latency behind.

### 3. ALSA readiness: `snd_pcm_wait` + a direction-dependent threshold

`ma_device_wait__alsa` blocks on ALSA's own `snd_pcm_wait()` (which re-derives
the poll descriptors) rather than a hand-rolled `poll()`, and uses
`snd_pcm_avail` (**not** `_update`) so the count reflects a real hwsync. On the
appliance's card the cached pointer is refreshed by a poll/IRQ that never fires,
so `_update` returns a stale `0` once the startup backlog drains and the stream
wedges. An `XRUN` seen here is deliberately **not** recovered in place —
`snd_pcm_recover()` prepares the stream but does not restart capture.

### 4. Slipped-playback self-resync

In `ma_device_write__alsa`. A playback stream that has slipped behind the
hardware replays stale ring content at a fixed offset — a permanent "robotic"
monitor. The signature is unambiguous (`snd_pcm_avail()` reporting more than a
full buffer of free space). Detect and resync with drop + prepare, so the loop
re-primes on a correct phase. The stock stream raises **no** XRUN for this at
all (the `stop_threshold` sits at the ring boundary, so an underrun just loops),
which is why patch 1 counts it as its own dropout kind.

### 5. `-EPIPE` retry instead of teardown

Both `-EPIPE` branches `continue` the retry loop rather than returning an error
that tears the data loop down, so a recoverable dropout does not end the audio
session.

## Not ours

`#if 0` blocks (the disabled `ma_device_uninit` stop, the AVX helpers, the MMAP
path, …) are **upstream** miniaudio, not Segno patches — do not "restore" them.
`engine_miniaudio.c` documents the one that matters: because `ma_device_uninit`
does not stop a *running* data loop, the backend must call `ma_device_stop`
first.
