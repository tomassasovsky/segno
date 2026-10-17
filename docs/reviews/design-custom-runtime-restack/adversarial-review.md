# M3.4 Custom runtime bounded adversarial review

Verdict: no unresolved actionable findings from the assigned six-group oracle and its bounded execution. Sixteen independent real-engine/shared-coordinator cases passed: 11 in `runtime-v3.log`, five in `neighbors-v2.log`. This is the existing Astra high reviewer, independent of implementation authors. Full source/five-role review is the peer's separate gate; aggregate app/static and publication are root-owned.

## Scope and binding

Base `cce88c32d03538c61bafeb64d89369b5aef708ac`, pending original `27efe48a9ca3871c85b4e307e3638fd20a49b604`. All 13 builder source/test hashes match the released builder freeze. The ten monitored production/helper inputs appear in `source-before.json` and `source-after.json`. One drift was explicitly reconciled: coordinator `1ed4cdc0…` to `742fea42…` adds only `unawaited` around the already non-awaited grouped `_submit(..., drain:false)` calls. Initial tool read and final diff agree with builder confirmation; no queue order, arguments, return handling or behavior changed. Other nine monitored inputs remained byte-identical. `final-adversarial-binding.json` binds exact final hashes and probe/log artifacts.

Used unchanged frozen M2.6 pump `31ebe531d01e3eb85297b1785e0f3cdf05b9f04134f277dd2b5bb97ef2bb80a8`. No native build, broad suite, product edit or Git mutation. Both Dart harnesses were external throughout; there are no temporary checkout test files to remove.

## Executed outcomes

- Fresh Mode is Mute/Custom. Hold stays in Tracks at 799 ms, enters Custom at 800 ms without Mute, and consumes release. Custom Exit and Bank act on contact; holding/releasing Bank does not page twice. Custom Mute/FX navigation pair executes only Hold, and release does not run the new context's action.
- Selected Hold follows selection until firing, then release does not change the later target. Bank-specific Hold follows the active bank at firing while fixed channels remain their explicit identities.
- Take lock acquired after contact prevents Hold. Confirmed setup replacement cancels pending work. A real asynchronous `applySession` increments session ownership before completion; the old Hold stays inert through that window and release. Equal binding application does not revive it. HELLO incompatibility cancels contact; reconnect plus old release stays inert, while a new press works.
- Merely assigning Mute leaves its LED dark. Accepted target mute lights it, authoritative external unmute darkens it, and Bank B uses frame index 4 without lighting Bank A index 0. Unsupported identity stays inert. Malformed explicit setup blocks configured actions while fixed Custom Exit and Bank remain usable.
- A pending durable Save leaves old Custom dispatch active. Acknowledgment publishes the complete new setup. A later write-then-throw returns an error and restores the exact confirmed serialized setup; actual dispatch continues using the confirmed new assignment.
- Through one shared real coordinator, a GUI gain write blocked at storage plus two Solo-all contacts leaves every Solo false. Group→single set true→group preserves all false; the stronger group→single set false on channel 2→group leaves exactly channel 2 true. Group→Clear Solo→group leaves all eight true. All eight exported original PCM buffers remain byte-for-value unchanged in the strong overlap case. An exclusive session boundary refuses grouped Solo without setting any Solo or lighting a success LED, and no deferred action appears after the boundary ends.

Expected booleans, channels, frame indices, serialized assignments and timing came from `oracle.md`; no expected outcome calls the new projection or invariants implementation. The real engine uses constant imported source buffers (alternating 0.10/0.20) and the actual settings/coordinator ownership path. PCM preservation here means original export preservation, not an independent audible-output/fade measurement.

## Source review and limits

Read the complete changed Custom dispatcher, function-state projection, setup default and grouped coordinator paths with surrounding gesture, lifetime and mutation callers. The group implementation queues per-channel intent before one drain and retains existing toggle parity, set and Clear ordering. It does not loop independent native Solo admissions. Mute reads authoritative remembered intent. Custom uses the existing UART interpreter and the existing session/take-lock timer fence; it does not create another transport. No unsupported M4 action was treated as implemented.

The compiled harness initially had API/lexical mistakes (wrong launch cwd; old helper argument names; empty binding factory syntax). Those failures are retained in `runtime-v1.log`, `runtime-v2.log` and `neighbors-v1.log`; preserved fixture copies and `fixture-corrections.md` identify them. No product failure was discovered in these runs, and no parent red run or mutation sensitivity is claimed.

All six oracle groups received bounded execution, but not every individual case was rerun. Draft Cancel/Restore/focus and full UI layout are peer/root evidence; unchanged source-specific momentary mechanisms retain prior M3.1 coverage rather than inventing unsupported Custom momentary catalogue entries. Normal transport baseline, raw protocol6, startup-load rollback and broad package/audio behavior are not claimed as freshly retested. No appliance foot timing, electrical UART, physical LED or hardware validation is implied. Exact-head publication and remote CI remain separate gates.
