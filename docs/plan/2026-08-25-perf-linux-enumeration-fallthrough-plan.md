# perf: Linux device enumeration — fix the miniaudio fall-through, not the appliance (#649)

**Status:** Definition for plan-gate sign-off · **Date:** 2026-08-25 · **Type:** perf (engine platform seam + Dart poll)

> Tracking: #649 (`stage:brainstorm`). Verified against `master` @ `61609b35`;
> numbers are the issue's Pi 4B bench (`src/test/bench/bench_devices.c`).

## Current state (verified)

`AudioSetupCubit` polls `refreshDevices()` on a 1 Hz timer
(`lib/audio_setup/cubit/audio_setup_cubit.dart:97`), synchronously on the UI
isolate, through `LooperRepository.enumerateDevices` →
`le_enumerate_playback_devices` + `le_enumerate_capture_devices`. On Linux the
route is a three-way branch:

| Config | Path | Measured per tick |
|---|---|---|
| `SEGNO_ALSA_ONLY=1` (appliance) | `le_alsa_enumerate_cards` — `/proc/asound/cards`, one entry per real card (`engine_linux.c:514`) | **0.146 ms** |
| JACK/PipeWire present | `le_jack_enumerate_devices` (`engine_linux.c:580`) | fine |
| **no JACK, no ALSA_ONLY** | seam returns 0 → miniaudio in `enumerate_devices` (`engine_devices.c:296`) | **950 ms, steady state** |

The 950 ms decomposes as: miniaudio's ALSA enumeration surfaces the whole PCM
hint namespace (24 "devices": `dmix`, `dsnoop`, rate converters, OSS…), and
`device_info_copy` asks `ma_context_get_device_info` per device for channel
counts (~38 ms each on ALSA) — with **most queries failing**, because plugin
pseudo-devices cannot answer.

### A premise to kill: "the memo cache is broken"

It is not, and "fix the cache" is the wrong project. The channel-count memo
(`device_channels`, `engine_devices.c:188`) deliberately refuses to cache a
failure — commit `8e490e13` — because a cached failure would pin a real
device at UNKNOWN forever. The rule is right; ALSA's hint clutter is what
turns it pathological: the majority of enumerated "devices" fail permanently,
are never memoised, and are re-queried at ~38 ms each on every tick,
indefinitely. The 950 ms is the *steady state*. Any fix that starts from
"make the cache remember failures" is trading a per-tick cost for a
pin-at-UNKNOWN bug on the next flaky-but-real device.

### The constraint everyone trips over: id ↔ backend consistency

Enumerated ids must resolve against the backend the device will actually
*open* on (`le_resolve_device_id` does a `strcmp` against the open context's
own enumeration, `engine_devices.c:345`; the comment at
`enumerate_devices:300` exists because ALSA ids can never match a JACK port
prefix). `le_platform_backends` opens JACK → PulseAudio → ALSA
(`engine_linux.c:687`). So the *only* configuration whose device opens on the
ALSA backend without `SEGNO_ALSA_ONLY` is one with **neither libjack nor
libpulse** — and that is exactly the configuration whose enumeration falls
through to miniaudio-ALSA and costs 950 ms. The fix and the constraint pick
out the same case; this is what makes the recommended change safe.

## Decisions for the owner

**D1 — the fix: extend the platform seam, don't touch the memo (recommended).**
In `le_platform_enumerate_devices` (`engine_linux.c:672`), when
`le_jack_enumerate_devices` declines *because libjack is absent* (as opposed
to "JACK up but no hardware ports") **and libpulse is also absent** (a
`dlopen("libpulse.so.0")` probe mirroring the backend-priority logic), fall
to `le_alsa_enumerate_cards` — the function the appliance already uses, which
reads `/proc/asound/cards` in microseconds, produces ids (`":<card>,<dev>"`)
that are *by construction* the tokens miniaudio's simplified ALSA enumeration
yields for the same hardware (its own header comment, `engine_linux.c:506`),
filters the hint clutter that should never have been in the picker, and gets
channel counts from `/proc` (`le_alsa_channels_cached`) instead of 38 ms
probes. When Pulse *is* present, keep the miniaudio fall-through: the probe
context and the open backend are both Pulse, ids match, and Pulse enumeration
does not have the hint-clutter pathology. The final miniaudio backstop stays
pinned regardless — the appliance relies on it once per direction per poll
when its interface is unplugged (`enumerate_devices:306`, "It must stay
pinned").

This closes the measured case (~950 ms → ~0.15 ms), removes the clutter from
the picker on pure-ALSA desktops, and changes nothing on the appliance, on
JACK/PipeWire desktops, or off Linux.

**D2 — negative-cache TTL: take it as defense-in-depth, or skip it?**
A failed query could be remembered for a TTL (re-asked every
`LE_CHANNEL_CACHE_TTL` sightings, like the existing per-entry trust
countdown) instead of every sighting — keeping the "never *permanently* pin
UNKNOWN" rule while capping the steady-state cost of any future path that
enumerates unanswerable devices (D1 makes the known one unreachable).
Recommendation: **take it** — it is a ~15-line change inside
`device_channels` using machinery that already exists, and it converts the
next clutter-shaped surprise from "950 ms per tick forever" into "expensive
once per TTL window". Skip only if the owner wants this issue absolutely
minimal.

**D3 — move enumeration off the UI isolate: here or separately?**
Even healthy paths block the UI isolate every second (84 ms for miniaudio's
lean list; single-digit ms elsewhere). `le_enumerate_*_devices` takes no
engine handle, so an isolate *can* run it — but the channel memo and the ALSA
probe memo are unlocked statics documented as control-thread-only
(`engine_devices.c:198`), so moving the poll to a worker isolate moves those
statics onto a different thread and every other enumeration caller
(`le_find_loopback`, resolve-on-open) must be audited or the tables locked.
Recommendation: **separate issue**. It is a cross-platform UX improvement,
not part of the Linux pathology, and bundling a threading-model change into a
perf fix is how a P3 grows a race. This plan's D1 makes the Linux poll
cheaper than macOS's, which removes the urgency.

## Implementation outline

- **PR 1 — the seam fix** (`autonomy:merge-gate`; picker behaviour across odd
  Linux configs is judgment): the libjack-absent + libpulse-absent probe and the
  `le_alsa_enumerate_cards` fallback in `le_platform_enumerate_devices`,
  distinguishing "no libjack" from "JACK present, zero ports" (today both
  return 0 from `le_jack_enumerate_devices`; the fallback applies only to the
  first). The existing `le_platform_set_alsa_only_for_test` override pattern
  gets a sibling for forcing the probe result so the branch is testable on
  any box.
- **PR 2 — negative TTL** (`autonomy:auto`, if D2 is taken): failure entries
  in `g_channel_cache` with `channels == 0` and a trust countdown; the
  existing TTL test derives its pass counts from `LE_CHANNEL_CACHE_TTL`
  already (`engine_internal.h`), extend it for the negative case.
- **Follow-up issue** (D3): enumeration off the UI isolate, with the
  static-table thread-confinement question stated in the issue body.

## Verification plan

- Native tests: seam-order test via the force overrides (jack absent + pulse
  absent → cards path; pulse present → miniaudio path; cards empty →
  miniaudio backstop still reached — the pinned appliance case). Negative-TTL
  test per D2.
- Bench, the same instrument that produced the issue's numbers:
  `bench_devices.sh --iters 20` on a JACK-less/Pulse-less Linux box (or the
  appliance with `SEGNO_ALSA_ONLY` unset) — the fall-through tick must drop
  from ~950 ms to sub-millisecond; `SEGNO_ALSA_ONLY=1 … --iters 100` must
  stay at ~0.146 ms.
- Routing proof, not just speed: on the pure-ALSA config, pick each
  enumerated device and confirm the open pins it
  (ids resolving through `le_resolve_device_id` against the ALSA-backend
  context) — the id-consistency constraint is the acceptance test, since a
  fast list that cannot route is a regression.

## Acceptance criteria

- Pure-ALSA Linux (no JACK, no Pulse, no `SEGNO_ALSA_ONLY`): enumeration
  ≤ 5 ms per tick steady-state, picker shows real cards only (with channel
  counts), and every listed device opens when selected.
- Appliance path byte-identical (0.146 ms tick, unplugged-interface
  fall-through preserved); JACK/PipeWire and non-Linux paths untouched.
- No cached failure can outlive its TTL (D2), and no failure is ever cached
  permanently.

## Non-goals

- No change to the memo's never-pin-UNKNOWN rule.
- No UI-isolate move in this issue (D3 spins out separately).
- No attempt to give the *miniaudio* fall-through channel counts cheaply —
  the counts come from `/proc` on the cards path, and the issue's warning
  stands: closing the count gap by querying per enumerated ALSA hint is the
  1007 ms trap.
- No picker redesign; same `le_device_info` surface throughout.
