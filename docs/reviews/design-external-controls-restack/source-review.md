# Independent source review

No unresolved actionable finding remains in the reviewed External controls
candidate. The bug-focused review and all five quality roles are complete for
the working-tree contents in [source.json](source.json), based on
`63607bdba8e5a41359c83b45087204bec9ca1a2b`. That public 100-path manifest has
fingerprint `a5b1cbc1bab3488744580ff6b6e6567c981c093025f17b51bb7e4ed9e92e4868`.
It includes additions, deletions, firmware, tests, art and the saved Pen.
Published-commit binding will be added by the coordinator; new review documents
are outside the tested product manifest.

One independent reviewer performed the bug-focused pass and the five quality
roles: [VGV conventions](vgv-review.md), [architecture](architecture-review.md),
[test quality](test-quality-review.md), [simplicity](simplicity-review.md), and
[PR readiness](pr-readiness-review.md). These are five perspectives, not five
independent agents. This reviewer made no product changes and ran no tests or
builds. A separate adversary performed the behavioral execution.

## Scope and completeness

The complete intended diff, including the new external writer and dispatch
tests, was reviewed with enclosing functions, callers and removed invariants.
The final 13 repaired source/test paths were rechecked against the preceding
complete pass; the other reviewed paths remained unchanged. The final source
binding was rehashed without drift.

Tracing covered strict immutable setup parsing and public construction,
retained profiles, unavailable identities, Press/Hold and latching edges,
draft ownership, stale dialogs, calibration tokens, pending Save, confirmed
storage and rollback uncertainty. Runtime inspection followed UART ingress
through repository events and ControlCubit into existing native admission,
receipt and settings seams, including shared MIDI/external holders and
source/configuration/session retirement.

The writer submits a complete recipe per native owner while preserving sibling
settings. Shared persistence retains lane inheritance. Automatic calibration,
cached replay and the old generic console interpreter were traced to their
replacements. Reuse, layering, efficiency and fix-depth checks covered the
action catalogue, focus/theme/localization, existing transaction ordering and
persistence. Native audio callbacks, ABI, generated FFI and UART schema are
unchanged; no compatibility fallback or second transaction framework was added.

## Resolved findings

| Findings | Verified repair |
| --- | --- |
| R1: malformed target aliases | Shared address structure and target construction reject malformed coordinates before configuration admission; valid unavailable identities remain retained. |
| R2–R4: stale picker, calibration owner and pending Save | Editor identity fences asynchronous results; owner tokens fence calibration disposal; pending Save retains its draft and reachable outcome. |
| R5–R6: unavailable-target repair and focus | Change control preserves row type and authored values; existing focus controls handle selectable targets and exclude disabled choices. |
| R7: synthetic firmware release | Detach silently resets contacts and publishes NONE; reclassification orders NONE before expression, without synthesizing an opening during absence/midscale debounce. |
| R8–R10: refused cleanup and holder order | Exact authored cleanup survives refusal; retries resolve current survivors; accepted Released activation receives its own priority and lifetime. |
| R11: older cleanup overwrites a new press | Cleanup registration runs inside the existing FIFO. Only successful same-target acquisition supersedes its older cleanup; refused acquisition and other targets retain their obligations. |
| R12: MIDI release waiter retires a new press | Deferred release checks the accepted contribution order, so a newer accepted same-trigger press invalidates the old waiter. |

The three R11/R12 failures were independently reproduced before repair and
pass afterward with unchanged reproducing assertions. Earlier failures remain
recorded; they were not relabeled as fixture errors.

## Evidence and limits

The final [independent execution](adversarial-review.md) passes all 54 bound
probes: 34 runtime/storage/actual-sketch groups and 20 structural model groups.
Candidate, harness, oracle and native-library bindings stayed unchanged during
execution. The accepted oracle was frozen before candidate evaluation; its
SHA-256 is `f8fc80bbede220fd13e194e6619fd567313671bb50cce229319e01cd59132274`.
[Verification](verification.md) records all six aggregate suites, required
coverage floors, firmware checks and the positive 694-file static scan passing.
Author visual checks remain separate from independent source review and CI.

This is bounded review, not exhaustive timing proof. Uncovered combinations
include every session/reconnect/take-lock/action-timer ordering, delayed startup
and overlapping editors, all missing/reordered targets, sustained mixed-owner
saturation, and every calibration smoothing/pending-write/navigation failure.
Storage probes exercise the actual repository transaction rather than every
page lifecycle. The R11 repress permutation uses injected admission refusal;
a separate probe exercises a full native command ring. The historical low-bit
sensitivity experiment was not repeated after unrelated repairs, although the
final full-byte transition probe passes.

No independent pixel render, appliance run, physical electrical/contact-bounce
or latency validation is claimed by this reviewer. Hardware without presence
contacts retains open-contact versus unplug ambiguity. Nothing was flashed or
deployed. Published-head CI is pending, and merge remains the established human
gate; a clean source review alone does not establish readiness to merge.
