# Architecture review: pending session recovery

Scope: the authorized local design slice only. Reviewed `session-recovery-model.js`,
`session-recovery-study.js`/CSS, the recovery additions to `session-library-study.js`,
the main page's assets, files/device callbacks and wheel support, the model/browser
tests and shared-behavior proposal. The unrelated dirty design tree, production
Flutter/native code, Pen and actual audio/filesystem recovery are excluded.

Applied `workflow-agents/references/architecture-review-agent.md` and the common
build review-agent instructions. The repo identifies Flutter/Bloc as its
production stack. This slice extends the established JavaScript prototype;
requiring a production Bloc migration would exceed its scope. No pre-slice
session-library baseline was supplied, so existing host behavior is traced as an
integration dependency, not claimed as a complete newly reviewed diff.

## Layer separation and state ownership

No dependency-direction violation found. The recovery model is independent of
DOM, persistence and the UI. It clones the supplied snapshot and replaces only
the affected audio descriptors/IDs. The recovery study owns the pending session
and candidate UI. Session Library owns target identity checks and transition
guards; the host retains persistence and publication ownership.

The final Open rechecks candidate descriptors, missing dependencies, interface
readiness, the original saved entry and capture/transfer gates. The host writes
the assembled session/library state before replacing the live rig. Failed
persistence returns an error and leaves pending repair available. Cancel clears
the pending state and returns to the Library load control. Existing physical
audio-device configuration and global audio catalogue are retained by the host's
session commit; this slice does not implement the unresolved broader ownership
proposal. The intentional Audio setup excursion preserves the repair draft.

## Resolved finding: pending recovery lifetime

Location: `docs/design/session-library-study.js:43` and `:211`.

The initial reviewed revision left recovery active after successful ordinary
`transition`/New Loop. Reopening Library displayed its old target over the new
current session. The public-API reproduction below established that defect.

Verified through the actual public study APIs using the existing VM host seam:

```text
review('session-recovery')
leave()
newLoop(true)
action('session:library')
```

Observed:

```json
{"newLoopSucceeded":true,"current":"session-3","pending":"session-2","bodyStillRecovery":true}
```

The focused re-review verifies its correction. `recovery.discard()` clears the
draft, original entry, tracked replacements, picker, error and scroll state.
`leave(next)` preserves that state only for Audio setup, and the main `go(next)`
passes the destination. Successful unrelated session transitions, direct Library
entry and `reveal` retire pending recovery. A failed commit still retains it.
The new public-API regression verifies New Loop changes the current session to
`session-3` with `recovery.draft === null`; the Audio setup excursion retains the
draft, while an ordinary exit discards it. No remaining finding on this path.

The final re-review also inspected `model.valid` and both pre-inspection load
guards. Malformed prepared lists, track-import containers and invalid descriptors
produce a controlled error before dependency inspection or publication. Tests
mutate/remove the actual saved entry while repair is pending and prove the live
session remains unchanged. A disappearing replacement is shown under its current
identity and can be repaired again; its updated descriptor is still revalidated
before Open.

## Validation and limits

Independently executed:

```text
node --test docs/design/session-recovery-model.test.cjs docs/design/session-recovery-study.test.cjs docs/design/media-parity-study.test.cjs
```

Final result: **36 passed, 0 failed**. The new suite covers the formerly missing
New Loop sequence, ordinary exit, device-excursion retention, stale source and
candidate changes. The expanded browser test includes Stage/Library exit and a
complete encoder repair/Open journey. Its Chrome/Firefox execution remains
author/coordinator evidence, not a separate browser run claimed here.

The model compares simulated duration/format and stable IDs. It cannot prove
decoded file compatibility, sample timing, usable media, hardware capabilities,
or recovery of all history dependencies. The proposal leaves clock, partial-take,
active-Clear and physical ownership choices explicitly unimplemented. Those
limits are not production architecture findings in this design slice.

## Reviewed hashes

The SHA-256 table below identifies the exact source snapshot. Later changes need
a focused recheck. No PR head, merge gate or production completeness is certified.

| File | SHA-256 |
|---|---|
| `docs/design/session-recovery-model.js` | `57dd6e7a2bc971daf0851eb54c29debd93c6ec3ad3a09feb4120407fe4685250` |
| `docs/design/session-recovery-study.js` | `35381a51085faf131c3d9382b4f24b7b81d62f4aa97096c674730f5788bdcb93` |
| `docs/design/session-recovery-study.css` | `9a33e7c77b602741b0a1ce285b6842181a62401ce1f2df3745b1ded8a0b7e6d2` |
| `docs/design/session-library-study.js` | `90834527f21568c17a3949796e3b45051feec67abb1f4cdabcad00bf1e51fffb` |
| `docs/design/fx-ux-prototype.html` | `4cb77e7aa11ed4b2de0f3f18ef96428b0d1581654002a2ff109c565f6b1c667d` |
| `docs/design/media-parity-study.test.cjs` | `fb72e88c26e22bde1def41dbd59cac62d0ae146be351e52b9d9e3e3b2beb2be8` |
| `docs/design/session-recovery-model.test.cjs` | `4bce8025738a006e9dbdf3ad6fb17cc93b533cce7ecd3f725fa7a31ad662d9a8` |
| `docs/design/session-recovery-study.test.cjs` | `59461775911185d19ad36ddb4ce120187de1c4690ec308e9c0ac54d68560d1ea` |
| `docs/design/verify_session_recovery.cjs` | `b6264f000fc19c3cc8d39bcf835088a244e6722b9ff40cb5ab50a3366378dfd5` |
| `docs/design/2026-09-08-shared-behavior-proposal.md` | `bd44a4d8f9e354502107e7d905b969a7a234e6e781dfb4a250853d0ef0024eb0` |

## Verdict

No remaining actionable architecture finding at the recorded hashes. The
lifecycle defect is resolved; no layer or dependency violation found.
