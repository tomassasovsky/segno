# Shared Click volume: consolidated review

Base: `42e5e849ec21bc5cd6a6feae0251a96923556ba7`.
The [source manifest](source.json) binds 83 intended source, test and render
files with fingerprint
`54e4f2763b5467a67d42a31eb4d0e5eb3d896eeb7362c14b7f414794f12953cd`.
The encrypted design file has a separate [saved binding](design.json).
Unrelated controller analyzer configuration and older raw reviews are excluded.

No unresolved actionable finding remains in this bounded slice. Review roles
were performed sequentially by cross-author reviewers; they are five distinct
perspectives, not five separate people. A separate adversary wrote and ran the
55 independent cases. The coordinator reviewed the combined changes, removed
invariants and cross-file boundaries. See the role reports under `raw/` and the
[bug-focused gate](../../code-review/shared-click-volume/review.md).

## Findings resolved

- Callback enqueue and cached desire were insufficient acceptance. The owner
  now waits for command settlement and a fresh gain readback before publishing;
  timeout or mismatch stops uncertain processing and blocks restart.
- Restart could replay temporary held gain. Accepted Released intent is now a
  separate restart value, also used by durable session capture.
- Shutdown could log a flush error and halt anyway, or accept a new controller
  event after retirement. Explicit flushing/failure phases stop on refusal,
  retire controls before waiting, and offer Retry or Keep playing.
- Session capture could race startup restoration or capture a held level.
  Required shared-owner callbacks enforce Mixer-then-Click ordering and capture
  the durable value without reacquiring the Click queue inside itself.
- Early Click replay projection could overwrite remembered lengths during
  engine startup. Startup admission now avoids projecting the partial rig.
- **M311-A1:** an old scalar failure could replace a new session's confirmed
  1.25 gain with 0.25. Recovery retains its original lifetime, restores only
  that scalar obligation, then separately adopts any current replay recovery.
  The independent original 1.25 expectation now passes unchanged.
- A failed checkpoint read could leave repository recovery without a local
  recovery object, admitting new writes or session capture. One shared guard
  covers both conditions; two independent no-write cases pass.
- **M311-COPY:** recovery text incorrectly claimed audio always stopped.
  English and Spanish now ask the user to retry the Click setting without
  making that false claim about a replacement session.

Fixture repairs preserve existing musical assertions. Import ordering and
line wrapping are the only source changes after the final ordinary aggregate;
final static checks and cross-author inspection cover them. Earlier failed
attempts remain evidence, not hidden retries. No compatibility layer, new
native API, controller interpreter or alternate Click storage blob was added.

The [verification](verification.md) distinguishes native, ordinary, UI and
historical sensitivity evidence. Hardware and the known M5 live-owner load
problem are not cleared. Review evidence applies only to these exact blobs;
CI and the human merge gate remain separate.
