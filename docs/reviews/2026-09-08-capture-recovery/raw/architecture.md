# Architecture review: capture and grouped recovery

Final source and documentation reconciliation is complete with no unresolved
actionable findings. This report identifies the source hashes actually reviewed
and does not certify later changes, a PR, native audio, hardware or the unrelated
working tree.

Scope is the named local JavaScript prototype delta against the supplied
`/tmp/segno-capture-recovery-before` files: transport, host publication, harness
and Stage projection. It also covers the new recovery tests and review fixtures,
and the narrow `length-performance-study.js` integration with `editLength`.
No baseline was supplied for that length file; its recovery-related call seam and
behavior were inspected directly. The architecture role and shared review-agent
instructions were followed; this reviewer made no implementation edits.

## Layer separation and state ownership

Violations found: zero. The transport owns its capture/pending maps, journal and
phase. The host owns rig projection and persistence. The required
`publish(changes, journal)` adapter writes a complete candidate before replacing
live content. The model consumes capture and history only after that succeeds.
The host builds the candidate through the same changed-field projection used
for the live rig, preserving later mixer and FX changes outside the content edit.

Song/Band section selection now happens in the candidate, including other tracks
that need to stop and their phase resets. Publication therefore contains the
final playback state; it no longer relies on a second save after an implicit
stop. Recovery refuses to stop another active overdub. The audio-ready guard
runs before publication when any resulting track would play.

Sparse sound regions are separate from loop duration. Multiply repeats and
Divide clips those regions together with the length edit; an empty region list
remains visible silence. Recovery reuses the single chronological journal.
`canRecover` loads persisted history after reset rather than relying on a prior
screen read. Stage receives copied timing descriptors and draws symbolic contours.

This follows the existing JS study boundary. There are no added packages,
dependency cycles or reverse production-layer imports. These synchronous cloned
objects are not real-time callbacks or native atomic filesystem operations.

## Resolved findings and independent reproductions

**Compatible Sync/Band Clear recovery.** Previously a 16-beat primary plus a
compatible fixed second recording cleared at three captured beats produced an
unrecoverable incompatible before-state. Both modes now retain the already
chosen compatible window, with only the captured three-beat region containing
sound. Clear preflights its recoverable before-state before publishing. This
extension remains an explicit prototype proposal; it does not resize finished or
imported audio, infer a first take's duration or settle Auto Sync/Band behavior.

**Offline Redo.** Direct publication previously bypassed the host's guarded
playback callback. The current preflight rejects recovery that would play while
audio is unavailable. The reproduction retains empty content, stopped playback
and the Redo entry until reconnect.

**Section publication ordering.** Song record Track 1, Undo, record Track 2,
then Redo Track 1 previously published both sections playing and stopped Track 2
only afterward. An instrumented publication adapter now observes exactly
`[true,false,false,false]`, identical to final live state. A failed publication
leaves the prior content, playback and journal intact. A competing active
overdub is rejected without discarding its capture or history.

The stopped-primary Multi case was independently reproduced: partial Redo starts
the restored 16-beat track at origin with its four-beat region, leaves the primary
stopped and never resumes recording.

## Verification and limits

Independently executed against this reviewed implementation:

- `node --test docs/design/verify_capture_recovery.cjs`: 21 passed, including the added Song/Band publication-candidate regressions.
- `node docs/design/verify_stage_transport.cjs`: transport and grouped recovery checks passed.
- `node docs/design/verify_audio_state_reconciliation.cjs`: 10 contracts passed.
- Focused publication-state, failed-publication, active-overdub and stopped-primary reproductions described above.
- Syntax checks for the nine named JS/CJS implementation/test files and the main inline script.

The browser test source was inspected: it uses the normal storage-enabled URL,
failed-write/retry journeys, reload, later Mixer/FX edits, grouped-history guards
and the shared small-display contour. The test author reports successful Chrome and Firefox execution against the
matching final source, along with the existing integrated audio-state journeys.
These are attributed browser results; no independent browser run is claimed
in this report.

The broader existing policy for initial capture overlapping a different Song
section is not changed or certified here; ordinary direct playback already has
that seam. Native sample placement, tail rendering, real storage reservation,
clock loss and hardware synchronization remain unverified and outside this
local design review.

## Reviewed source and baseline hashes

These hashes identify the independently inspected source, not a PR head or a
claim that later edits have been reviewed.

| Current file | SHA-256 |
|---|---|
| `docs/design/stage-transport-study.js` | `3ca5fcc49b8b184406f2691408ceef427b40da79c523ef3f4df2bdd720e866b4` |
| `docs/design/audio-state-test-harness.cjs` | `faa165ef0aff054c66dbe343046a497e3bfd5bd2a7f19531b5f7bf35315270d4` |
| `docs/design/fx-ux-prototype.html` | `38e60242e40451630bda5bdf56ac36c2610e4217965e53fadd0c5223fb62a58c` |
| `docs/design/stage-display-study.js` | `5dade15c26d7d861c5071e2794a400c74a78b7de42369ea50610661510ba0a12` |
| `docs/design/length-performance-study.js` | `e60f3bdc358e2455cd21ecfc4fbab3ce83a2ab732431c774354d6ecfbaef1337` |
| `docs/design/capture-recovery-scenes.js` | `06a5d0b498089da501dfef640eddd7ffcf3ed34d77264cee19dd6aab55ed391a` |
| `docs/design/verify_capture_recovery.cjs` | `de76c06837e5f98073eeae7ac60f2a0893510e8fa67907142d8e646f89d2d591` |
| `docs/design/verify_capture_recovery_browser.cjs` | `90e76a69b1383653e12ac95304aef718918a01332fd7d9c8c4f6b02bc6634c34` |
| `docs/design/verify_stage_transport.cjs` | `3aff6dd13b31c3b701ed0096c3f7424bebe2e83ce6c484b49216436dc9e4be44` |
| `docs/design/verify_audio_state_reconciliation.cjs` | `ab6502cdb5941eb3e7f22246126dd31af3549e639fb67d51e6057523e6be6523` |
| `docs/design/2026-09-08-shared-behavior-proposal.md` | `9cd729bd18f5915a27c6c2b14ed8db16d28b3f95e5fa9f99382ecba54bb820a4` |

| Supplied baseline | SHA-256 |
|---|---|
| `stage-transport-study.js` | `6b17eb6c1cc3a4fe2674c74e9aff6d5b9030bfb72994f08f452522bb5ef98efb` |
| `audio-state-test-harness.cjs` | `79ef709a4feafee5884f079ec06ae7cb1dd1d89d2b6dd2f2d95363e83ee6863a` |
| `fx-ux-prototype.html` | `4cb77e7aa11ed4b2de0f3f18ef96428b0d1581654002a2ff109c565f6b1c667d` |
| `stage-display-study.js` | `d10a5cf8a593aea0f37a6fa55ebfa51a7527f765de40b56d412d507f38e91fbc` |
| `verify_stage_transport.cjs` | `b4e639c95040e6fb86e8c5c293c1e2e1b364835cececc7163f3dfc0908a1b273` |
| `verify_audio_state_reconciliation.cjs` | `e36ff3ba50daa01295835a87b3debe852dd23bbabe9ee2eecf8e47dead92ea41` |

## Final authority and evidence reconciliation

The implementation hashes match the prior reviewed transport, host, display,
length and fixture revision. The only subsequent code changes in this scope are
the test harness publication observer and two Song/Band tests. The observer
clones attempted candidate state and journal without changing model behavior;
the tests assert that exclusivity is already present before a failed or
successful publication. Their syntax and whitespace checks pass, and the final
independent run passes all 21 focused cases plus the existing transport and ten
reconciliation contracts.

The final behavior record, shared proposal, production plan, audit plan,
progress note and reference follow-up now agree: established-cycle Multi
recovery is accepted and verified in the symbolic prototype. Active Clear All,
exact-duration recovery before a defining cycle, and retention of an already
chosen compatible Sync/Band window remain implemented proposals. Native guards,
PCM, phase, resource reservation and durable recovery remain outstanding. The
stale plan/reference statements that still described the corrected symbolic
behavior as unimplemented were reported and rechecked as corrected.

`verify_closure.py` independently passes: all 183 IDs, preserved baseline,
CSV/JSON agreement and valid evidence paths. LX-054 and LX-055 remain open at
the decision gate; LX-181 remains partial at the prototype gate. The inventory
still explicitly denies whole-audit completion and appliance certification.

The recovery gallery references five existing browser/Pen pairs, labeling two
Multi frames accepted and three Clear frames proposed. Its local links resolve
to files. The binary-only Pen hash matches the coordinator's final saved hash,
`d01d22afc1ebbe074b83098ec736697768b2e6a2e459a71e8b7e476f9b0087dc`.
Native-tool save, visual inspection and browser runs remain author-attributed
in the consolidated review; no independent Pen or hardware result is claimed.

| Final documentation/evidence file | SHA-256 |
|---|---|
| `docs/design/2026-09-08-capture-recovery-ux.md` | `31a0003b0b1e3d8137877ac137d91cd172692b3b7d8c9cf325cd7f6a36afee2d` |
| `docs/design/2026-09-08-shared-behavior-proposal.md` | `9cd729bd18f5915a27c6c2b14ed8db16d28b3f95e5fa9f99382ecba54bb820a4` |
| `docs/plan/2026-09-08-audio-state-parity-plan.md` | `d9ec465a78438c03e3d9d0c530df6868bfefc3718fbb5908b1fc4005cfcdf4b9` |
| `docs/plan/2026-09-08-audit-closure-plan.md` | `ad9f3032393b084ad0620af55ea04dcbfee4d34af803ecb2f44da9c467be53e8` |
| `docs/PROGRESS.md` | `21130934316409e859d7e3f0f052959d4ec32b8858cda54dbeddaa5981da551e` |
| `docs/research/segno-looper-x-comparison/2026-09-08-recheck/reference-closure-pass.md` | `5fb0c710d1842536668880119b3f784c37e1f86744cd87c706c6ef12f97e5cc3` |
| `docs/research/segno-looper-x-comparison/2026-09-08-recheck/closure-items.csv` | `50f0126dcad8df183232613c736d63ae87039cb1f79a4e740b3b0bd2591ac0da` |
| `docs/research/segno-looper-x-comparison/2026-09-08-recheck/closure-items.json` | `b1e329e4dfea80247ab45e33d459883ca4e32836542509e7226976c1abd7ebf0` |
| `docs/research/segno-looper-x-comparison/2026-09-08-recheck/closure-summary.json` | `3f99171a62aa33b30e7c2c89ccf88e0ff999819f77917e27dabbb09efc1312fb` |
| `docs/design/capture-recovery-previews/index.html` | `8f1d182d8b4134830178c448c9653b878279f1892bca5c4d0cf07bbfc272306d` |
| `docs/design/capture-recovery-previews/manifest.json` | `a2f6d281b40e618c924691872fd063049c6ffb251ab835d674d562a68d251ac8` |
| `docs/reviews/2026-09-08-capture-recovery/review.md` | `8530af6c7d0b20c691f979a1d9bcca8605dfc0ae2ddb27ea7060864ffab3796a` |
| `docs/reviews/2026-09-08-capture-recovery/evidence.json` | `a808042e6de7ded5c358a8040b3f720dbf72584df6eec36c0b5e9dfac711537a` |

## Verdict

Architecture is clean for the recorded local prototype revision and final
documentation. Zero unresolved actionable findings. This is a bounded local
review, not a native implementation or merge certification.
