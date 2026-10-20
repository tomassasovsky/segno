<!-- cspell:ignore readset -->
# M3.12 Decay independent execution

The frozen candidate passes **51 independent probes**. The declared inverse-feedback negative control reaches real native PCM assertions and fails both selected endpoint cases for the expected reason. No actionable product mismatch was established. Execution is closed; test slot 2 was released. No product, author test, Git, firmware or native-library edits were made by this reviewer.

## Binding and independence

Base: `8b740c093b7ae84fb36c19fac88914246d6278b3`, branch `codex/shared-overdub-decay`. Product freeze v1 binds 25 changed product files; SHA-256 `3dfbd25ca44dab2b4f204dc8a1b9ab105a76b7f3b3a8fdfb23a4817dbecb3d02`.

Expected outcomes were frozen before implementation. `oracle.md` remains byte-identical, SHA-256 `f5d69b2ed110ae3ae71155768665f7639e39880ee2a1ec3599b59b6f17aaeed4`; authority readset `readset-v1.json`, SHA-256 `077d39240d47f63082012ea0076478946b58b546aa6d31d58b6fd51caa6ba37a`. Author tests were read for the later quality review, after independent expected values and executable harness were prepared; their success narratives did not supply the oracle.

Final behavioral preparation `prepared-v4.json`: `ea0ce5886eb8b7793aa8d61c069ad690a96d3503db9a704f0ef9d69408280229`. It binds all private fixture/test/runner bytes. Sensitivity-only runner correction `prepared-v5.json`: `8365cb35c90f15570659e346b366e2b7e6fa593a44138322d6bf1bb55c0b557e`; the v4 test files and assertions are unchanged.

Frozen `segno_engine_test.dylib`: `31ebe531d01e3eb85297b1785e0f3cdf05b9f04134f277dd2b5bb97ef2bb80a8`. It was loaded through the actual PumpedNativeEngine/LooperRepository seam and never rebuilt. Each run binding records exact command, package configuration, all app/package source dependencies, relevant package tests, oracle, harness, library, product manifest and before/after hashes. All six attempts report `unchanged: true`, with no changed bound input.

## Actual exercised behavior

The 51 cases comprise 42 model/owner/Control/lifetime probes, eight native PCM probes and one actual Session file Save probe. The log lists every expanded case.

- Strict default/fixed-track keys, malformed coordinates, literal rounding, immutable snapshots, reversed expression endpoints, actual relative MIDI bytes and redundant quantized continuous input.
- Storage blocked before atomic admission; refusal, wrong readback, mutate-then-throw, exact absence versus explicit zero rollback, unrelated sentinel preservation, failed compensation and explicit recovery.
- MIDI and External authored numeric Released values, both acquisition orders, prior versus later ordinary intent, non-held durable takeover, refused reset and retained cleanup, equal-valued Use default, preserved toggle intent, stale address revision, and delayed delivery of a real accepted owner outcome. The latter wraps the real result; it does not manufacture acceptance. Its valid sibling still applies and releases.
- Default/track live versus Released durable/restart projection, stopped/deferred intent, failed native restart, empty Track 8 explicit zero, invalid final startup slot with no partial publication, independent Once readiness, replacement-session fences, old failed scalar recovery and actual pending owner close.
- Real PowerOffCubit pending/failed/success phases using actual owner/Control cleanup and a bounded injected halt counter. Pending ordinary storage prevents halt; late MIDI/External ingress cannot author a new track; refused cleanup prevents halt until explicit Retry repairs and drains it.
- Real SessionCubit/SessionRepository Save produces a file with default20 and explicit track0 while live remains default80/track75. This proves file capture, not a full live-owner recall journey.

Native PCM checks start from old0.4 and input0.2, with the fixture's recorded loop/window and 1e-5 tolerance fixed in the preserved test source. Decay0/50/100 yields0.6/0.4/0.2; silent overdub yields0.4/0.2/0. Ordinary playback at decay100 preserves old material. Actual layer undo recovers old0.4. Explicit track0 overrides default100. Mapping dispatch and native feedback publication are real; fault injection selectively refuses an engine call only in failure-ordering cases. Decay is an immediate atomic native setter, so storage-complete success is deliberately tested without requiring callback pumping.

## Preserved attempts and fixture corrections

No product repair or weakened expected value explains the transition to green.

| Attempt | Result | Interpretation |
| --- | --- | --- |
| `decay-v1-attempt01` | Three load failures; zero behavioral cases | Private fixture exported two `AudioBackend` types. V2 hides the unused settings export. |
| `decay-v2-attempt02` | 46 pass / 5 fail | Fixture issues described below; initial observations retained. |
| `decay-v3-attempt03` | 50 pass / 1 timeout | Owner close mixed FakeAsync work with a repository subscription created on the real clock. |
| `decay-v4-attempt04` | 51 pass | Owner-only close uses real async throughout, with the same blocked-then-complete and idempotence assertions. |
| `decay-v4-sensitivity05` | Tooling crash before tests | Flutter native-assets lookup required the isolated app root in package configuration. This is not negative-control proof. |
| `decay-v5-sensitivity06` | Two intentional native sample failures | Runner-only package-root correction; same private PCM tests and oracle. |

V2's five failures were: (1) PumpedNativeEngine's deliberately always-running snapshot made a stopped/deferred assertion false; the private subclass now reflects actual start/stop calls only in status fields, preserving real native commands and samples. (2) Close completion was asserted across incompatible fake/real async scheduling. (3) Silence100 PCM passed, but assuming exactly one Undo overlooked an existing boundary-tail layer; the fixture now waits bounded layer retirement and undoes the available bounded history to recover the unchanged old0.4. (4) Simultaneously starting two captures invokes the existing single-capturer rule; explicit-override PCM now uses sequential controlled passes with unchanged0.6/0.2 expectations. (5) Session Save initially rejected because the required real Click owner had not been loaded; initializing it enables the intended Decay file capture. Every prior source, log and binding remains alongside the corrected version.

## Meaningful isolated sensitivity

Only the isolated repository copy changes `feedbackOfDecay` from `1 - percent/100` to `percent/100`. Integration files are unchanged, app source is read-only, and the same native binary performs DSP. Original repository hash `8b5b828d1296417a64bd5f968bd08b220cedfd510ed1fe3a6a59471148782c88`; mutant hash `bfece3b0c9bd1f0141dd3821579c385da9db144d5a4be4ec28fb39ac13313cff`; redirected package-config hash `be3394b9e4f22f96eafcafe79fce61e92cb859e3f22f68c62f22e6ebb9c0e093`.

At frame2048, decay0 expected0.6 but observed0.20000000298023224; decay100 expected0.2 but observed0.6000000238418579. Both fail at the sample assertion, as predicted before implementation. Decay50 alone would not distinguish the wrong transform and was intentionally excluded from N1. Optional N2 was not run.

## Limits and disposition

This is bounded behavioral evidence, not a full product, device or PR gate. No physical MIDI/pedal/audio device, OS halt, firmware, appliance reconnect timing, sanitizer/build matrix or visual/accessibility audit was exercised here. Test-side PowerOff composition uses the approved order but does not replace root's actual App wiring regression. Author screenshots and native-library-gated tests are distinct from ordinary CI; this private harness is not installed as a CI suite.

The oracle is a representative matrix, not a claim that every sub-permutation ran. Omitted independent permutations include mode-by-mode DSP/availability, a mid-pass feedback transition, rename/bank interaction, reversed-relative dispatch, every missing-target/format combination, refused cleanup followed by re-press without an intervening reset, Keep playing after failed shutdown, and exhaustive storage/native/session orderings. Endpoint UI initialization/repair/no-preview is source and author widget evidence rather than independent native harness coverage. Full live-Control Session Load retains the inherited M5 EMPTY-length/publication limitation: Save, owner adoption and restart are not presented as complete recall proof.

Candidate disposition: no unresolved mismatch in the exercised Decay scope. Exact-head CI, root's final bug review, publication and merge/device gates remain separate.
