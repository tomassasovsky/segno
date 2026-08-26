# feat: crash durability for a capture bundle — sync the pair, off the drain cycle (#727)

**Status:** Definition for plan-gate sign-off · **Date:** 2026-08-25 · **Type:** feature (engine drain + salvage contract)

> Tracking: #727 (`stage:brainstorm`, split out of #722 / PR #726 where a
> half-measure was written and deliberately reverted). Verified against
> `master` @ `61609b35`.

## Current state (verified)

The drain thread (`packages/segno_engine/src/core/perf_drain.c`) writes three
kinds of file every `LE_PD_FLUSH_MS` (250 ms) cycle, and **nothing in the
module syncs any of them** (stated at `perf_drain.c:485,640,759,834,1364`):

- `master.pcm` / `input-N.pcm`, `events.log` — long-lived streams, `fflush`ed
  per cycle (stdio → page cache, no further).
- `performance.json` — rebuilt each cycle through `le_pd_fd_write_all`
  (`perf_drain.c:511`, raw fd, EINTR-retried) into a temp file and `rename`d
  over the old one: **atomicity of the directory entry, zero durability**.

This is *consistent by accident*: a power cut truncates the sidecar's view and
the PCM bytes by roughly the same page-cache window. The revert of #726's
sidecar-only `fsync` is documented in the file itself (`perf_drain.c:489-505`)
and its three findings are this design's constraints, not open questions:

1. **Sync the pair or nothing.** A durable `capture_frames = N` over
   page-cache-only PCM makes #679's boot salvage and `daw_export` lay out an
   arrangement that runs past the audio.
2. **Nothing that can stall sits inside the 250 ms cycle.** On ext4
   `data=ordered`, an fsync commits the journal transaction carrying the PCM
   block allocations; the capture rings hold `LE_PERF_CAPTURE_SECONDS` = 2 s
   (`engine_private.h:160`), so an SD garbage-collection stall inside a cycle
   overruns `master_ring` and writes zero-filled silence — the defect class
   #710 just closed, with `a_perf_zero_filled_frames` (`perf_drain.c:1063`)
   as its instrument and `zero_filled_frames` already surfaced in the sidecar.
3. **Transient I/O errors must not end a take.** #726's `fsync`/`close`
   checks turned one transient `EIO` into `stopped_early: disk_full` on a
   healthy disk, mid-performance.

### A premise to kill: "sync at disarm is enough"

Disarm-only durability protects against nothing that matters here. An app
crash without power loss keeps the page cache — the kernel writes it back and
today's salvage already recovers the take. The scenario this issue exists for
is the appliance's **normal end of session: the power cord**. Disarm-only
means a 40-minute set that ends in a yanked plug is entirely at the mercy of
background writeback timing. The durability point has to advance *during* the
take.

## Decisions for the owner

**D1 — how much tail is a power cut allowed to cost?** This is policy, not
engineering, and it must land in `docs/design/performance-manifest-format.md`
next to the `.boot-recovery` / `.recovered-at` contract rather than stay
implicit. Recommended: **a bounded window of 10 s** (configurable constant),
plus a full barrier at disarm/finalize. 250 ms-grade durability is what
constraint 2 forbids; "whole take at risk" is what the premise-kill above
rejects; 10 s of lost tail from a mid-song power cut is musically survivable
and keeps sync traffic to ~6 barriers a minute.

**D2 — the mechanism.** Recommended: a **dedicated sync thread** owning a
sync epoch every N s: `sync_file_range(..., SYNC_FILE_RANGE_WRITE)` on each
PCM stream to *initiate* writeback early and keep the eventual barrier cheap,
then `fdatasync` each PCM fd + `events.log`, then publish the durable point
(D3). Rationale against the alternatives the issue lists:

- *Lower-cadence sync from the drain thread itself* — still puts a
  stall-capable call inside the cycle once every N s; constraint 2 is about
  the worst cycle, not the average one. Rejected.
- *`sync_file_range` alone* — bounds writeback but is explicitly not a
  durability barrier (no metadata, no device cache flush); it is the warm-up,
  not the answer.
- *Disarm-only* — rejected above.

The sync thread never touches the rings and runs at normal priority (like the
drain thread, `perf_drain.c:247`, and for the same reason: lateness is
invisible). The drain thread's only new obligation is publishing "flushed
through byte X / frame F" per stream after each cycle's `fflush` — the sync
thread barriers *up to* a point the drain has already flushed, so the two
threads share a couple of atomics and the fds, nothing else. `fdatasync`
concurrent with the drain thread's `fwrite` on the same fd is safe; the
stall lands on the sync thread.

**D3 — how the sidecar states durability.** Recommended: **two fields**.
`capture_frames` stays what it is — the live view, rewritten every 250 ms for
concurrent readers. A new `durable_frames` (with `durable_at_ms`) is bumped
only by the sync thread, *after* its PCM `fdatasync`s return, by writing the
sidecar through the existing temp+rename path plus `fsync` of the temp file
and the bundle directory. Ordering does the proof: any sidecar version that
carries `durable_frames = M` was created strictly after the PCM was durable
through M, so **whatever sidecar version survives a power cut, its
`durable_frames` never overstates what is durable** — even if that surviving version is a
later, unsynced 250 ms rewrite. Salvage (#679) and `daw_export` clamp to
`min(durable_frames, bytes actually on disk)`; a pre-#727 bundle without the
field keeps today's behaviour. This dodges the alternative — freezing
`capture_frames` at the synced point — which would make the live sidecar lie
to concurrent readers by up to N seconds.

**D4 — error policy.** `EINTR`: retry, everywhere (the `le_pd_fd_write_all`
rule generalized). `ENOSPC`/`EDQUOT` on the sync path: genuine
`stopped_early: disk_full`, as today's write path treats them. Any other
`errno` from `fdatasync` (notably transient `EIO`): log it, count it in a new
sidecar `sync_failures` field, **do not advance `durable_frames`, do not end
the take** — the capture keeps writing and the next epoch retries. If the
failure persists to disarm, the bundle finalizes with `durable_frames` stuck
at the last good barrier, which is exactly the honest claim. This satisfies
constraint 3 while never letting an un-durable byte into the durable claim
(post-fsync-failure page-cache semantics make "retry the same barrier"
unreliable as a *guarantee*, which is precisely why failure must stall the
claim rather than the take).

**D5 — quantify, don't argue.** Whatever N is picked ships only after a bench
run on the real appliance (Pi 5 + NVMe, and the SD-card rig if that config is
still supported): a long take with sync epochs forced while
`a_perf_zero_filled_frames` is watched. The issue sets the bar and this plan
adopts it verbatim: **any design that raises the counter above zero on a
bench take is disqualified.** The alloc-watch/mid-cycle-hook test machinery
(`g_pd_mid_cycle_hook`, `perf_drain.c:616`; the #828 zero-fill forcing test)
is the pattern for the CI-side half.

## Implementation outline

- **PR 1 — engine sync thread** (`autonomy:merge-gate`): the thread, the
  flushed-point handoff, `sync_file_range` + `fdatasync` epochs, D4 error
  policy, `durable_frames`/`durable_at_ms`/`sync_failures` in the sidecar
  writer, full barrier at disarm before `finalized` flips. Native tests via
  fault injection (interpose `fdatasync` like the allocator interposition in
  `test_perf_drain_steady_state_cycle_is_allocation_free`): epoch advances
  the field only on success; EIO stalls the claim and not the take; ENOSPC
  stops with `disk_full`; ordering (no sidecar carrying M exists before the
  PCM sync through M returned).
- **PR 2 — salvage + export consume it** (`autonomy:merge-gate`):
  `PerformanceRepository.runBootRecovery` and `daw_export` clamp to
  `durable_frames` when present; `docs/design/performance-manifest-format.md`
  gains the durability contract (D1's number, D3's fields, D4's policy).
- **PR 3 — bench validation** (`autonomy:blocked-verify`): the D5 run on
  hardware; the bench harness can live with
  `src/test/bench/` alongside `bench_devices`.

## Verification plan

Native fault-injection tests per PR 1; a crash-consistency test that SIGKILLs
a capture mid-take, drops what a power cut would drop (run the writer in a
child, compare against the durable claim rather than the page cache), and
asserts salvage produces an arrangement no longer than every PCM stream;
Dart tests for the clamp; the D5 hardware gate before the feature is called
done.

## Acceptance criteria

- After a simulated power cut at any instant, the salvaged bundle's
  arrangement never references audio past any PCM stream's durable bytes.
- A take loses at most N (default 10) seconds of tail to a power cut, and
  nothing to a mere app crash.
- `a_perf_zero_filled_frames` stays 0 across a bench take on appliance
  hardware with sync epochs active.
- A transient `fdatasync` error never terminates a take; `ENOSPC` still does.
- Atomic-rename behaviour and the 250 ms live sidecar cadence are unchanged;
  pre-#727 bundles remain readable.

## Non-goals

- No change to the rename-based atomicity (correct, stays).
- No WAV finalize changes, no drain-cadence changes, no RT-priority changes.
- No durability for anything outside the capture bundle (session saves have
  their own story).
- No attempt to make `capture_frames` itself durable — that half-measure is
  the reverted #726.
