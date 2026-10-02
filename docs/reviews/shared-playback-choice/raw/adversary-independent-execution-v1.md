<!-- cspell:words predeclared -->

# M3.13 independent execution

**50/50 independent cases passed.** The predeclared isolated receipt-bypass negative control failed exactly the acceptance-before-callback assertion. No unresolved product mismatch was established in the exercised scope. Test slot was released after sequential execution; no product/Git/native-library mutation occurred.

## Frozen evidence

- Base: `f186bb952d1d000522c5e8e55226bc2ee0931538` plus frozen working source.
- [Executed source](adversary-executed-source-v1.json): 87 changed paths, 29 product source paths; SHA-256 `a90df12d01eded02aa009b9512262e1df1d9dcf2a301c5eb69541cb2b7d674eb`.
- Original oracle: `d2057da82dc1e7e8e0b2ccf9ec12471b6444e4611302b853d07fead15b364d05`; unchanged since before product implementation.
- Prepared harness v2: `6ced14fe76032b2d23418e22e8f74b90c77c09fabb63f1f08632f27af9c9b6c6`.
- Frozen native test library: `31ebe531d01e3eb85297b1785e0f3cdf05b9f04134f277dd2b5bb97ef2bb80a8`; reused, never rebuilt.
- Runtime author manifest: `4b3d6d56cffdefda7f218bb85ecd6008a42331e215ba19dc903704f426b9f332`; model/UI manifest: `dd6551600c42d3a4b811f6f4e2e4b09a4af3c55d7159ad7a9f762ed7130904a3`. All 47 author-bound paths matched before execution.

Runs used one Flutter process at a time, `flutter test --no-pub --reporter expanded --concurrency 1`. Logs, commands and before/after hashes are retained in private evidence using the labels below. The 1,487-input final binding includes app/package/test source, package configuration, harness/oracle and library. Every bound input was unchanged after normal and sensitivity runs.

| Run | Result | Binding SHA-256 | Log SHA-256 |
| --- | --- | --- | --- |
| independent01 | 38 passed, 12 fixture-precondition failures; exit1 | `3887f79b8b8e66845e38e74a0a32bd75c3d5ac35117c510ebfa38300e2baca5f` | `286999e7945994af74784f16ae2c4cce6acd56e0c84f10bceb80015904c1e26f` |
| independent02 | 50 passed, exit0 | `31f7bfb8e1d03370e88892fd1a6cc58dad44dcfa0abf1c3e70c5da686282fce1` | `9b2c12c461780db370076c5591f5af2bd95453ed93e0383ae0ceaabea6a4dafb` |
| sensitivity03 | Intended P02 failure, exit1 | `861eb8d82bea40564c164092612895542de941af93d3e8d22544c65225752528` | `73a079e56f7f0ed36ce4881a485b37f82e7c518a40d73040867ed3b99b343c3c` |

## Distinct exercised behavior

The 50 expanded cases consist of 28 core owner/model/dispatch cases, ten actual native Loop/Once cases across Multi/Sync/Song/Band/Free, eight lifetime/file cases, and four edge cases.

- Literal identities, immutable membership, threshold `0/.49 → Loop`, `.5/1 → Once`, reversed expression endpoints, relative MIDI bytes `1/127/64` and one-choice detents.
- Store wait → scalar receipt → actual native enqueue → withheld callback → actual native receipt, with no early owner acceptance. Explicit Custom false and true, captured inheritors and empty inheritor mask.
- Store refusal, wrong readback, mutate-throw, absent/false rollback, native refusal, timeout, drained wrong bits and failed compensation blocking new writes/capture.
- Latest accepted MIDI/External source in both orders, including false, surviving-source Released projection, ordinary before/during hold, non-held durable takeover, accepted/refused Use default, equal-effective reset and toggle latch, refused old release followed by new accepted press, and delayed real receipt/reset/sibling interaction.
- Independent Once/Decay readiness, malformed last-slot refusal, shared-queue ordering, dual durable Session file output, Released-only restart, stale scalar compensation across replacement, autonomous replay failures, shutdown pending/refused cleanup, Retry, Keep playing, late ingress and close/Bloc persistence drain.
- For every native mode, an actual 8,192-frame recorded take remains playing two frames before its endpoint; Once stops after crossing its own pass boundary while Loop continues. Exported PCM, length and undo depth remain unchanged. Sync/Band primary Once stops while the sibling capture and frame clock continue.

## Retained fixture failures

All 12 attempt01 failures occurred before Once application: second-record completion was followed only by a zero-frame drain, so the native seam-overlap capture still reported recording. The existing engine requires approximately 10ms of audio for the defining seam; v2 pumps 512 samples at the same `.4` input before the unchanged playing/length assertions. The two sibling fixtures additionally allow a loop boundary for Sync's mandatory capture arm. Expected choice, pass end, PCM, history, priority and persistence outcomes are unchanged. The original v1 files and failed logs remain intact. The correction was documented and hashed before attempt02 (`6e91ec4ea54ceda1a4d85a0c5082dd4339bd1734733ba26026c9bb5f537e9029`).

## Meaningful negative control

Only an isolated LooperRepository package copy was altered: `_settlePendingOneShot` accepted the queued intent without command drainage or raw-bit proof, preserving restart projection and all other source. Original repository SHA `b0aa492df04f179a3f5fcb7cb243a79748c54049428a6885d1c58467a754332e`; mutant SHA `51bd69f319a605d2c0c42261644bd96fc5a03c7723d6d81f6028f18f871c4a8f`.

P02 reached actual native enqueue with callback withheld, commands unsettled and previously false raw bits. It failed with `Expected: null; Actual: OneShotOutcome`, reason `N1: enqueue cannot publish owner acceptance`. This is behavioral sensitivity, not a compile/tool failure. The candidate repository and shared library stayed unchanged. A second negative-control variant was unnecessary.

## Limits and final gate

This bounded matrix does not cover every format/mode/index/fault-position combination, physical MIDI/pedal/audio-device cycling, real OS halt, performance export, every missing-target/editor/accessibility path, a dedicated Once relaunch, separate same-value queued receipt, rename/bank UI, or all simultaneous recovery-checkpoint failures. Actual App widget shutdown is coordinator evidence; this private suite uses actual PowerOff/Control/owner composition with a halt counter. Author screenshots are distinct from ordinary CI.

Actual Session Save and source/session replacement do **not** close inherited M5 full live-Control Session Load. The exact A1/A2 combination regressions are inspected author red/green evidence, not added to the independent 50 count. After these runs, root reopened only legacy test fixtures following aggregate failures. Later fixture deltas, aggregate validation, final review binding and exact-head CI remain required before merge readiness.
