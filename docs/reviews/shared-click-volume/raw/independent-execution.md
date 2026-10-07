# Independent Click volume execution

**55/55 probes passed on final product freeze v2**, run `click-v5-final05`,
exit 0, one worker. No unresolved candidate mismatch remains in this exercised
scope. This is independent behavioral evidence, not the complete source,
UI, CI or five-role gate.

## Candidate binding and method

The tested base was `42e5e849ec21bc5cd6a6feae0251a96923556ba7` plus the
27-path product manifest. Product v2 changes only TempoCubit and the English
and Spanish recovery copy from product v1. Every product hash was checked
before launch. The final run bound 1,297 files before and after, with no drift:
app/package Dart and native sources, harness dependencies, package metadata,
oracle/addendum, public plan, harness, runner and frozen native library.
This does not assert that all separately edited author test files were frozen.

Successful receipt paths use actual `PumpedNativeEngine` and
`LooperRepository`, not immediate-acceptance mocks. Controlled storage seams
inject delays, refusal and wrong readback. Wrong replay substitutes a real
native command value while retaining actual snapshot and settlement behavior.
The library was neither rebuilt nor overwritten. Execution used
`flutter test --no-pub --reporter expanded --concurrency 1` with the private
harness and `SEGNO_ENGINE_LIB` selecting the bound library. No product edits
were made by this reviewer.

Artifact names below identify retained evidence; they are not links to files
included in this public directory. All digests are SHA-256 of file bytes, not
internal manifest fingerprints.

| Final artifact | SHA-256 |
| --- | --- |
| `product-freeze-v2.json` | `67f1cbb391796f19bed56ffd308fa2b9c8700cf46128cc1ba207e75b20947ef5` |
| `m311-runtime-freeze-v2.json` | `47ced1ae95e9971032eb05dc8101f5f2762122b7e059a83bafa7efce228c10a4` |
| `prepared-v5full.json` | `a67c3756e86589bf29ef68c232504995407732f2f596f7ca9b6e193f85e7d9c0` |
| `independent_click_v5_test.dart` | `48e8460304df5b5beab31c8f44b2be2a35a83650fd6ef9d4fdb34b4f0ad9ba14` |
| `run_bound_click_v5full.py` | `cf33b83bd49158abc3fc6379aeaf1f14eef38d28ac1de8796ec966dd9cf51345` |
| `click-v5-final05-binding.json` | `4f00f85a13fab18f1fec3e8e6b8298791b7cccea309508a33e933dbb01fb7e1e` |
| `click-v5-final05.log` | `47deba88373af72dc05379ef031bd32f270b165f188ef89f8f9c5a99e223d7c4` |
| Frozen native engine library | `31ebe531d01e3eb85297b1785e0f3cdf05b9f04134f277dd2b5bb97ef2bb80a8` |
| Private final `execution-report-v3.md` | `6e10076cf55fca7b9a23c629a6556299eb813741b10f4cd9bbbdea514e516026` |
| Private final `execution-report-v3.json` | `7c5af945d1dc44fcd2727eb8abea954207896580fe5664ed27b6b8a239dd26c5` |

Original oracle and clarification hashes are in [oracle.md](oracle.md).
This public document translates the retained report; it does not share that
report's byte hash.

## Distinct exercised outcomes

The original 52 cases passed again. They cover:

- Strict target identity, malformed identities, linear/reversed arithmetic,
  unavailable versus zero, and relative detents including byte 64 = −64.
- Durable-before-enqueue ordering; callback withheld while the outcome remains
  pending; same-value ordering behind older work; storage refusal/wrong
  readback; exact missing/present checkpoint rollback; invalid input.
- Timeout, failed rollback, explicit recovery, stale lifetimes, delayed startup
  loading and stopped ordinary replay.
- MIDI and External Held/Released, both acquisition orders, ordinary edits
  before/during hold, same-value ordinary intent, non-held toggle priority,
  refused press/release and repress, early release, missing sibling and fresh
  input after reconnect.
- Real SessionCubit file Save containing Released 0.25 while native gain 1.5
  remains audible.
- Actual PowerOff state machine waiting on storage/native work; visible failure
  without halt; explicit Retry and fresh gate; no duplicates or timed retries.
- Autonomous replay timeout/mismatch adopted by the owner, pending replay
  blocking flush, and successful explicit recovery.
- Restart variants for MIDI and External: Released replay, later ordinary 1.25
  preserved, refused ordinary edit excluded. Shutdown cutoff rejects late
  ingress; Keep playing needs fresh input; refused cleanup remains owed until
  Retry publishes Released before halt.

Case 53 retains the independently failing old/replacement lifetime sequence:
replacement restart must be 1.25, never old durable 0.25. Cases 54–55 add a
one-shot checkpoint-read failure followed by ordinary 1.25 or controller
1.5/Released 0.25. Both refuse before Retry, attempt zero new scalar writes,
retain confirmed/scalar 0.5 and keep restart blocked. Explicit Retry then
permits actual native restart at 0.5.

## Retained attempts and fixture distinction

| Attempt | Observed result and meaning |
| --- | --- |
| `click-v3a-attempt01` | Original 52 passed on product v1; no initial compile or fixture failure. |
| `click-v3a-sensitivity02` | Isolated intentional receipt bypass failed the intended pending assertion. |
| `click-v4-lifetime03` | Diagnostic fixture failed: expected at least five total writes, observed four. Mutate-then-throw performs one rollback, not the two expected for a different stale-success branch. This was not a product finding. |
| `click-v4a-lifetime04` | After correcting only that diagnostic count, native gain was 0.25 instead of the unchanged expected replacement 1.25. This was product defect M311-A1. |
| `click-v5-final05` | Final 55 passed once on product v2, including the unchanged 1.25 expectation and two new admission guards. |

The original attempts remain retained. No audible/durable expectation was
relaxed to make the repaired candidate pass.

M311-A1's trigger was: confirm old 0.25; block an old ordinary 1.5 store write;
stop and apply a replacement session at 1.25; restart with an actual wrong
native replay command 1.75; let the old store mutate then throw and its
checkpoint restoration fail; clear faults and explicitly recover. Product v1
restarted at 0.25. The final candidate restarts at 1.25. See the bounded
[delta review](independent-delta-review.md) for the ownership repair.

## Meaningful negative control — product v1 only

An isolated source copy bypassed the actual post-enqueue Tempo receipt wait
only for requested gain 1.5; seed gain 0.5 still used its real callback.
Unchanged C1 reached durable 0.25 and actual enqueue while native remained
0.5. It then failed with `Expected: null` and
`Actual: <Instance of 'ClickVolumeOutcome'>`. This was a behavioral failure,
not compilation or setup failure. The candidate was not mutated.

**This negative control was not rerun on product v2.** It remains historical
v1 sensitivity evidence. The final normal C1 passes, its literal assertion and
receipt-wait mechanism are unchanged, and the final delta concerns recovery
admission/lifetime and copy. That does not turn the old sensitivity run into a
new-candidate run.

| Historical artifact | SHA-256 |
| --- | --- |
| `product-freeze-v1.json` | `d37f30d1a3878646999c53eaa286004422996e7d52f4cd76e5142999bbf3558e` |
| `click-v3a-attempt01-binding.json` | `8634e3bbe447d43cccaad172984fb3f8f66e341f1d7e529230530c71262dc264` |
| `click-v3a-attempt01.log` | `8472236c7fe7b983d574335963c1216d9fdb57e8c1ff34b9af11c93b57fd32b8` |
| `click-v3a-sensitivity02-binding.json` | `15979d8df20dd840e87859da4f780ed9e3c311040ddf75d1a903ed915a5ff699` |
| `click-v3a-sensitivity02.log` | `efb2a3684823d086dacaed7e6680f5b75f3be9000b19b821553f3f442f42d945` |
| Isolated mutated Tempo source | `98a3d38f0ddcd19ebc16cc8603bb130ed42189ec5990627dbf72c8da14c6124b` |
| `click-v4a-lifetime04-binding.json` | `64bf8a9f4a8272257153c9ec93a0cecd48a3ea453ffae5d75683374eee73b57a` |
| `click-v4a-lifetime04.log` | `42884759ee2c82795474fdbb143497029e3ff43b5bed54303c91236560e70f89` |

## Material limits

No physical MIDI/pedal/device timing or OS halt was exercised. Direct repository
stop/start represents replay, not OS enumeration or reconnect delivery. Actual
PowerOff and Control/Mix/Tempo owners were composed, but App providers,
monitor/Looper wiring and rendered Retry/Keep-playing actions have separate
coordinator evidence. This suite contains no UI Add/Save/Cancel or semantics
journeys. Real session file Save does not clear the inherited M5 full
live-Control Session Load limitation.

Omitted permutations include absolute CC14 wire midpoint, calibrated expression
wire dispatch, zero-valued competing holder, continuous non-held overlap,
Remote disable/re-enable, unrelated pair invalidation, close while pending,
every configuration/session/storage interleaving and every mixed-owner shutdown
combination. The two direct-owner guard cases do not substitute for source
freshness journeys. One independent bounded review is not five independent
roles or a complete merge gate.
