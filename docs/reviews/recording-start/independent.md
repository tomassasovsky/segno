# Independent Recording start review

The assigned native and phase-two product review is complete, with no unresolved actionable finding. The independent review found one native cancellation defect, C1; its unchanged reproducer passes after repair. Thirty bounded Dart, Session and App cases also pass. This conclusion applies to the source bindings below. It does not establish remote CI, visual approval, hardware behavior or readiness to merge.

Base: `505fbcad19303b78396035c807409ee5a706f132`. Expected behavior came from a 26-group pre-edit oracle, frozen before product implementation. Author test outputs were not used to choose independent expected values. No product source, native candidate library or author test was changed by the independent reviewer.

## Source and evidence bindings

All values below are SHA256. Execution records retain the exact commands, harness versions, logs and before/after hashes; all recorded runs report no input drift.

| Input or record | Hash |
|---|---|
| Pre-edit oracle | `d71c8cef83c17a0a5cd0eaad545aabbd051595ecde129c618e3f80a9dc43412c` |
| Oracle authority binding | `9cc1f14e82527554b355cff559741579b5720e56d00d2fe12b9803162981cef3` |
| Native v1 source manifest | `4374e17e94c635a840909ce36a943f358be9f080ac384387a9c682175ba7577d` |
| Native v1 immutable library | `e2fcf735d977b3754bfa633bf70cccad6d7f3ddec49f80efe18e74fc6f58259c` |
| Native v2 source manifest | `ba9094fe29110d3188e6600c5571821cd27d9af23b4867f9294e5f1767cbda2c` |
| Native v2 immutable library | `5ff334200a61b6591aae07ae7429757ca2be848a06566e6fd7da959a87547d86` |
| Runtime Dart production manifest | `56d153afb590bbf46e91159a6813b5bd1176158f4b7835dfabc61e7e1a87d5fa` |
| Root composition production manifest | `817e7c75be243a798b094d1807ce923be37a486b3467891f4d54532b2e5fdc0d` |
| Frozen verification checkout copy manifest | `558cb7e9d2d2cc18cd48815e348ed5ec7e60e4eb7b5595eeb8d1dcd0a474d1e3` |
| Native execution binding | `158106e0e30309c70b9305aa4676175c21e0d701a8430969a937172a5a67e037` |
| Native source review binding | `0d32394e028f3af5598d3aacacc69ba11b7287c08a8c67c77e5e8889c7f26d99` |
| Phase-two execution binding | `f52e249ae98f690d608cf45f93043432cfc0031e9e3979186464266a5d1b4f6b` |
| Phase-two source review binding | `fbe7997e811583b650258a1c084210668b34ead3815b85f8c3ed28cc75e3fc06` |

App and Session ran in a frozen verification checkout containing the intended changes and unchanged base FX sources. This isolated unrelated concurrent FX work. Shared test helpers were also explicitly bound. The native source review covers 20 changed engine-package paths, including tests; the phase-two binding contains 40 unique product/dependency paths, including unchanged dependencies. These are scope counts, not additional test counts.

## Executed coverage and repaired defect

Native v1 covers 18 unique groups across several source-bound runs: 17 passed and one exposed C1. This is a union of exercised behavior, not a single all-green run. Repaired v2 passes six affected groups, including the unchanged failure. Those six are replays and are not added to the unique count.

C1: at 8 kHz and 120 BPM, establish a two-bar countdown, enqueue Count-in four, then enqueue same-track Record while the original countdown remains live. Record is admitted as cancellation. In v1, the earlier setting command removes the old countdown and the queued Record becomes a fresh four-bar countdown: `counting=1 total=64000 elapsed=0 pair=4,0`. Expected behavior is no new acquisition. The repair preserves cancellation intent in the private command payload; v2 observes `counting=0 total=0 elapsed=0 pair=4,0` with unchanged assertions. Source review also traces the repaired image entry point, which delegates owned cancellation before FX preparation. Independent execution of this exact repair uses ordinary Record; the image variant has separate author evidence.

Other native groups exercise literal pair validation/defaults, configure preservation, same-value receipts, single pending reservation, capture refusal, queued Record-before-pair refusal, raw-post bypass refusal, queue-full preservation, counter width and receipt wrap. They distinguish Count-in and Sound edit kinds for existing arms and countdowns. Selected input 1 triggers Sound while signal only on unselected input 0 does not; no selected, invalid or excluded source refuses before preparation. Unpublished routing prevents new Sound acquisition while cancellation remains available.

Real PCM verifies a one-bar countdown lasts 16000 frames at 8 kHz, 120 BPM and 4/4. Frame 15999 is still counting, the next frame ends countdown, and the following literal .7 sample is the first live recorded sample. A finalized interior sample retains .1. This is one-track boundary evidence, not a general scheduler proof.

Phase two passes 30 distinct cases:

| Batch | Cases | Evidence |
|---|---:|---|
| Owner | 27 | Exact storage membership, transformation, receipt, compensation, recovery, lifetime and queue behavior |
| Session | 1 | Actual file Save, changed second Save, and refusal preserving the old bundle |
| App | 2 | Actual recovery/Power interaction and no-input track touch |

Owner cases verify absent defaults without materializing keys; explicit zero; Sound true with absent Count-in; malformed pairs staying unavailable; durable write before native submission; pending state until the real callback; same raw pair not counting as receipt; exact first/second-write and readback compensation; sticky failed rollback; explicit Retry; and an autonomous same-value timeout visible before a later owner edit or flush.

Real callback FIFO tests refuse capture-time pair changes. An actual Sound arm survives Count-in zero and is canceled by positive Count-in. Session replacement tests cover obsolete initial reads and obsolete mutating writes with both successful and failed rollback. Retry repairs the old scalar checkpoint without stopping or overwriting replacement audio. Device replacement during loading requires fresh confirmation. Count-in, Sound and exclusive operations preserve queue order.

The Session case waits for a pending pair, confirms successful Save, and reads `(0,true)` from the actual bundle. A second successful Save changes unrelated Decay to 37 and verifies both that change and the unchanged pair, ruling out a stale-file false positive. Uncertain storage blocks Save and preserves the old file.

The App recovery case verifies no halt while uncertain, no competing Recording start toast while the Power UI owns interaction, persistent recovery after an actual Keep playing touch, and exact key restoration plus one halt after an actual hit-testable Retry touch. Shutdown initiation uses the real PowerOffCubit; the system halt side effect is a counter. The second App case touches the actual track tile with no selected recording input and sees the input-selection notice, no arm/capture, and the unchanged Sound preference.

Acceptance uses the real owner, repositories and pumped native engine. Only two known-admission-refusal storage cases inject a refused native return; no successful native acceptance is mocked.

## Failure sensitivity and retained attempts

Three disposable native mutations each fail the intended assertion, with unmodified controls passing:

| Mutation | Discriminator | Result |
|---|---|---|
| Report settled before callback publication | Pause after actual mutation, before receipt publication | Expected unsettled assertion fails |
| Remove callback capture recheck | Queue Record before pair | Pair incorrectly changes during capture |
| Remove no-source admission refusal | Sound Record with no selected source | Expected invalid result fails |

Each mutation exits with code 42. Candidate source and immutable libraries remain unchanged. These controls were executed against v1; they were not repeated on v2. The v2 replay targets the cancellation repair and affected behavior.

Initial private native compilation/linking and instrumentation-copy failures are retained. An extra finalized-loop-head expectation was corrected: existing finalization folds an 80-frame seam into that head. The exact live .7 sample assertion remained unchanged, and the corrected finalized assertion checks index 100 outside the seam against the unchanged v1 library. This was a fixture correction, not a DSP repair.

The first App attempt failed both private teardown completion assertions because the fixture closed MixSettingsCoordinator after App had already closed its owned instance. The preserved corrected version removes only that duplicate close, retains other cleanup assertions and all behavioral expectations, and passes both cases. A named-parameter fixture correction was made before execution and is not counted as a compile failure. Failed attempts are not erased or counted as extra coverage.

## Source review perspectives

All requested bug-focused angles were completed directly without recursive delegation:

- **Changed lines and removed invariants:** traced strict pair validation, removed split setters/mirrors, admission versus callback refusal, autonomous settlement, exact compensation and nullable confirmed readouts. There is one pair authority rather than retained compatibility paths.
- **Cross-file tracing:** followed typed C API, generated bindings, snapshot conversion, repository acquisition-before-synchronous-read, Tempo queue, Settings serialization, startup, Session capture, UI consumers and shutdown. C argument widths, field placement, edit-kind order and symbol removal match; the repaired cancellation adds no public ABI.
- **Lifetime and repair depth:** traced pending-object cancellation, Session replacement, old scalar obligations and fresh device receipts. C1 preserves admission intent instead of reinterpreting state later. Independent old-read/write tests corroborate the owner boundaries.
- **Realtime and efficiency:** callback work remains bounded scalar/atomic reads and comparisons. No added allocation, I/O, locks or waits were found. Test hooks are native-test-only. Dart polling is bounded, and storage stays outside the callback.
- **Architecture and ownership:** presentation calls the owner; repositories remain below it. Session retains ordered settings gates and captures the confirmed pair. Bootstrap validates before opening audio and settles startup in both paths. Power retains cutoff, recovery, second cleanup barrier and final flush.
- **Reuse and simplicity:** existing queues, command rings, publication and arm cancellation are reused. A adds no mapped owner, compatibility shim, shared-launch scheduler or fake capture-journal lock.
- **Conventions and test truth:** AudioEngine remains the seam; presentation does not import data clients. Native tests distinguish enqueue from receipt. Source review reads migrated native/bridge tests; later aggregate fixture deltas are reviewed separately. App/Session independent assertions check actual user paths and file output. Author-only visual evidence is not counted as CI or independent execution.

No additional actionable defect was found. The native and phase-two reports together complete this reviewer's assigned product bug review. The coordinator's final intended-source binding, later fixture review and remaining gates remain separate.

## Limits

The 30 phase-two cases do not exhaust the 26 oracle groups or all permutations. Both audio-bootstrap entry points and the four presentation consumers' full mount/remount/capture matrix are source-reviewed here, not independently executed. Dart tests withhold the callback entirely; the paused-after-mutation publication window is independently exercised in native code, not by a new Dart bridge test. Independent FFI execution was assigned elsewhere.

No independent claim is made for all plugin-loaded preparation counters, all restart/readback failures, pair-versus-Click-volume ordering combinations, or a repeated full v2 native standard/sanitizer/telemetry suite. The independent queue case covers Count-in, Sound and the exclusive gate. Native coverage uses representative routes and one rate/tempo.

A intentionally contains no mapped Count-in, Held/Released APIs, shared-launch scheduler or native FrozenTake journal producer. There is no hardware timing, physical power-off, full live-Control Session Load, visual approval or remote CI claim. Repository Session replacement and actual file Save are narrower evidence. Existing later-family and hardware dependencies remain deferred.
