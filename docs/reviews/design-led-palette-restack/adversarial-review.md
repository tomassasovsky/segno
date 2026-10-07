# M3.6 independent adversarial review

No unresolved actionable finding in this bounded behavioral review. The reviewer authored none of this M3.6 delta. Previously authored M3.5 native/protocol code is outside the independent review scope and was not rebuilt or retested here.

## Exact source and oracle

Base `27b13351a7ad43828a4bd83d14305ed5978572b4`; final freeze-v2 has 31 paths and fingerprint `263eb7002dcaf03c6b1f23a24c406a81541e1e5cdb3aea95b7d4d85bcc630582`. Every final path matches its manifest. All 30 original freeze-v1 paths remained byte-identical during these probes; v2 adds only the documented palette token-test exception. Final binding records the manifest, probe files, fixture dependencies and logs.

The pre-implementation oracle remained unchanged: SHA-256 `91b88b70667ee75761caa533db7bcd564ec34719612bf9437abcae91ab03b75d`. Runtime checks use the existing real pumped native library, SHA-256 `31ebe531d01e3eb85297b1785e0f3cdf05b9f04134f277dd2b5bb97ef2bb80a8`, shared LooperRepository and MixSettingsCoordinator. No fake immediate native acceptance replaces that seam.

## Observed execution

Nine model/runtime cases and four widget cases passed; both final commands exited zero.

- Strict palette validation rejects malformed explicit values, duplicate/non-positive IDs, invalid RGB, unknown keys and dangling references. Shared IDs remain stable through edits and reload, caller maps are detached, exposed maps refuse mutation, white is the default and black remains valid.
- A real fired Hold Mute retains target state, physical mask and last-Hold identity through hue Save and release. Externally clearing its target darkens the correct lamp. A pending Hold survives the 400 ms hue Save and fires once at 800 ms; changing its actual assignment cancels the old gesture without replaying release.
- Active Solo survives hue Save and the next toggle turns the actual Solo off. A held Solo queued behind the shared GUI/settings owner receives the confirmed new hue before its native callback, then retains the original accepted action identity after acknowledgment and release.
- A real FX momentary keeps its captured prior state across hue Save. An unrelated release does nothing; the matching release restores the original target after the selected track moves. A configured FX mode door returns to Custom after hue Save.
- Delayed Save keeps the old live palette until durable completion. Write-then-throw restores the exact old durable bytes and leaves the live setup unchanged. Widget execution also confirms failed rollback remains uncertain after Cancel and a confirmed same-value Save repairs the durable value.
- All ten physical controls support local hue preview while preserving the canonical active mask independently of selection. The repository frame stays on confirmed hues; Cancel restores the local map. A dialog result cannot resurrect a live configuration replaced while it was open.
- Clear Custom followed by a shared-color edit to black, a Stop hue change and a Track Hold change allows Restore to recover only the previous A/B Custom assignments. Later edits remain intact and the complete saved payload reloads exactly.

The external runtime harness reuses the prior independent real-pump rig's setup mechanics. The widget harness uses the existing test graph's construction mechanics; the behavioral sequences and oracle assertions above were added independently. `runtime-v2.log` and `widgets-v2.log` are the final execution records.

## Retained initial failures

`runtime-v1.log` retains two invalid fixture assumptions, not product defects. First, the fixture expected palette Save to finish while an earlier GUI settings write was deliberately blocked; the shared settings owner correctly serializes both. The corrected sequence releases that store gate, confirms the palette has published while native Solo is still pending, then pumps the callback and checks the original action identity. Second, the fixture expected a fresh Mode Press to operate the FX return door, but its default action is Mute. The corrected fixture explicitly assigns Mode Press to FX; the expected return to Custom is unchanged. No production code or behavioral expectation was weakened. The first two widget cases passed on their initial run; both additional failure-path cases passed on their first run.

## Limits

This is a bounded behavioral gate, not a claim that every oracle permutation was executed. Long-palette scrolling/focus, delayed initial load, unrelated-save interactions and all session/disconnect fencing permutations were not independently replayed here. Canonical insertion-order equality was exercised; every possible ordering was not. Source/five-role review, visual inspection, full application/static/coverage gates, unchanged-package reuse, exact-head CI and publication remain separate evidence. No parent sensitivity run, firmware build, device execution or physical brightness claim is made.
