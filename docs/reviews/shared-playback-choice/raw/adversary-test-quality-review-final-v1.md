# M3.13 independent review — test quality

Reviewed product base: `f186bb952d1d000522c5e8e55226bc2ee0931538`, plus the frozen M3.13 working changes. [Executed source manifest](adversary-executed-source-v1.json), SHA-256 `a90df12d01eded02aa009b9512262e1df1d9dcf2a301c5eb69541cb2b7d674eb`, binds 87 changed product/test/artifact paths, including 29 product source paths. The broader executable binding covers 1,487 inputs. Source, private oracle/harness and frozen native library were unchanged before/after the final normal run and negative control.

Product review is complete for that binding. The coordinator subsequently reopened **test fixtures only** after aggregate failures in old short-track/readiness fixtures. Those later test changes are outside this report's binding and require a delta review. No final PR-head approval or green aggregate is implied. The unrelated controller-package analysis exclusion remains outside approved feature scope.

Read scope includes every changed product source and relevant tracked/untracked tests: bootstrap/App/shutdown, typed target/resolver/catalogue/UI, Control MIDI/External lifetime/priority, Playback owner/port, repository receipt/restart/session paths, exact Settings checkpoints, ordinary Bloc writes, Session gate and file mapping. Runtime author output was read only after independent expectations and tests were bound/executed. See [independent execution](adversary-independent-execution-v1.md) for results, attempt history and limitations.

## Test-quality perspective: completed with explicit gate limits

Independent execution: **50/50 passed**, plus an isolated receipt-bypass mutant that fails the intended pending assertion. The first attempt's 12 recording precondition failures are retained and explained; no expected Loop/Once, duration, PCM, history, priority or durable outcome was weakened. There is no independent coverage percentage claim.

The inspected authored scalar/repository/owner/dispatch tests contain meaningful assertions for exact absent/false rollback, inheritor masks, command drainage, startup validation, wrong native bits, compensation, restart and queue order. Fake AudioEngine cases do not independently prove native audio behavior. The private suite uses the real frozen engine for admission/receipts, ten all-mode playback cases with actual recorded PCM, and two shared-clock capture cases. Actual Session file output and actual PowerOff state/Control/owner composition are exercised; the App widget route remains a separate coordinator fixture.

Editor tests cover accepted button endpoint defaults, expression/MIDI ranges, draft-only changes, Escape, Save/Cancel and repair preserving authored endpoints. Native-free journeys are distinct from screenshot/font-dependent author render tests. New screenshot renders are not counted as ordinary CI. The old direct Bloc-to-repository forwarding assertion was replaced with an actual owner/storage/flush/reset test.

The final two startup repair combinations have inspected author red/green regressions, distinguished from the independent 50. Source hypotheses preceded those authored tests. The coordinator's aggregate later found old short-track/readiness fixtures; their fixes and rerun are pending outside this executed binding. No complete green aggregate or full live-Control Session Load proof is claimed.
