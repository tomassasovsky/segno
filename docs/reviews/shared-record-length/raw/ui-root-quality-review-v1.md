# M3.14 model/UI and composition quality review v1

Status: bounded source review complete; targeted repairs and final fixture/gate binding remain pending. This is not a whole-source clean gate or readiness certification.

## Authority, independence, and binding

One reviewer applied the VGV, code-simplicity, and test-quality role definitions sequentially, after reading their full instructions. I authored the runtime owner, dispatch, repository, Settings, and native changes; those implementations are expressly excluded from this independent certification. I traced their public contracts only to assess the other authors' callers. Repository AGENTS and the approved Record length plan override generic requests for broad refactors, deletion of production fakes/seams, or speculative abstraction.

Base: `2cf6c3adfc19b0e229717fe4b6d1748267b0c17a`. Exact inspected production and fixture hashes are in `ui-root-quality-source-v1.json`. Initial product reads matched `m314-length-verification-v1/product-freeze-v1.json`. During this review the producer repaired the expression Escape finding; precisely `expression_controls_panel.dart` and `external_pedal_page.dart` differ from that manifest, and this report includes the targeted repair source. Test producers are still adding/repairing fixtures, so their current hashes are a review source read set, not a final test freeze. No test process, product edit, Git mutation, or delegation was performed for this review. Existing failed-attempt logs were preserved.

## Findings and repair status

### P2: expression Escape changed a preserved authored endpoint — source repaired, execution evidence pending

Original frozen source: `lib/control/view/pedal_setup/external_pedal_page.dart:692-698`, with `expression_controls_panel.dart:336-338`. Repair an existing Track volume expression with heel `.2` and toe `.8` to Record length; the page deliberately preserves authored endpoints. Enter heel keyboard editing, change its value, press Escape, then Save. The frozen cancel callback reentered the normal canonicalization routine, changing `.2` to `13/64` instead of restoring the exact opening value. This can change subsequent expression interpolation and violates cancel/repair preservation.

Current repair adds an explicit `onEndpointCancel` path and passes `preserveRaw: true`; actual changes still canonicalize. The new real-page test `Record length repair and Escape preserve authored raw endpoints` performs that journey and asserts saved `(.2, .8)` exactly. This source repair addresses the identified cause. Its test result and final producer hashes must be bound before closing the finding.

### P2 verification fixture gap: required RecordOptions provider missing — producer repair pending

`test/control/external_controls_page_test.dart:175-183` provides Control, Tracks, Pedal, Tempo and Playback but renders the real ExternalPedalPage without RecordOptionsCubit. The new production page watches RecordOptions for rows/catalogue availability. Adding only the unavailable port to the Control constructor does not provide the watched Bloc. Existing page journeys can therefore fail before exercising their assertions. `test/screenshots/external_pedal_screenshots_test.dart:232-240` has the equivalent omission. These are unfinished fixture repairs, not a production ownership defect. The MIDI screenshot fixture initially had this omission too; its current source now constructs, loads and provides RecordOptions consistently to Control and page. Screenshot checks remain author-only evidence, distinct from CI.

### Test-quality correction: no-audio assertions target the retired setter — producer correction requested

The new Record length editor cases in `test/control/midi_controls_page_test.dart` and `test/control/external_expression_page_test.dart` assert `verifyNever(setDefaultLengthPreset)`. The current real owner uses `setLengthSettings`, which those fixtures already stub. An accidental current-owner write could evade the stated no-audio assertion. Establish the startup vector call baseline after `record.load`, then assert no additional vector write during Add, endpoint draft changes, Escape, or Save. Keep the exact mapping/value assertions. This is a bounded verification gap; no current product audio dispatch defect was found in these handlers.

## Pass 1: VGV conventions and architecture

The Flutter/Dart Bloc/Cubit, mocktail, bloc_test and repository seams match the existing stack. Presentation additions consume the required initialized owner; they do not import storage/native clients. Typed target keys remain strict and fixed to Default plus Tracks 1–8. Normalization uses finite values, round(64*v), and 1/64 steps. Resolver existence and temporary edit locks remain distinct: capture and Multi disable editing without converting a retained mapping into a missing target. Pick handlers check current owner eligibility again rather than relying solely on an old rendered row.

App composition has one RecordOptions owner, one failure subscription, and explicit close ordering after Control cleanup. Startup stages strict mode plus all nine scalars before opening the engine and uses the single coupled vector; the obsolete post-start restore helper and duplicate per-track writes are intentionally removed. LooperBloc delegates ordinary length/mode writes to the owner and awaits outstanding operations at PersistFlush. Removing reported-mode persistence avoids a second writer and avoids silently persisting session recall as a new global preference.

Session acquires Mixer → Click → Playback → Record gates and uses the durable Record snapshot for capture. Root does not call owner flush/recovery from inside its exclusive callback. Shutdown retires controller ingress synchronously before awaiting work; explicit Retry recovers owners then retries owed retirement before final flush. Failure remains visible without stopping an active capture. App toast Retry is scoped to the failing owner. No additional actionable convention, layer, or composition issue was found in this bounded source read set.

## Pass 2: simplicity

The change uses the existing typed catalogue and owner composition. There is no new generic transaction framework, duplicate interpreter, native API, compatibility path, or migration. The narrow port is justified by real composition and AudioEngine/fake test seams. Disabled reasons and localized Auto/bar readouts serve the current locked-control contract. The separate cancel callback repairs a real distinction between authored changes and restoration; folding both back into the same canonicalization routine would recreate the bug.

No required removal or broad refactor is recommended. Existing long page files do not alone justify a scope-expanding rewrite. Estimated justified deletions beyond those already made: zero. Complexity is proportionate to the required transaction/lifetime behavior; that statement does not certify the runtime implementation excluded above.

## Pass 3: test quality

The model tests use literal keys, malformed coordinates, half-step/boundary values, non-finite refusal, fixed eight-slot presence, and locked-but-readable resolution. They do not merely derive expectations from the production conversion. The editor tests exercise actual pages and saved mapping state. Their remaining fixture and no-audio assertion corrections are listed above.

Root's App tests use the real owner and shutdown flow with controlled store failures/pending writes. They cover persistent startup Retry, preserving malformed stored data, waiting for ordinary writes, shutdown refusal, capture gating, held retirement, and rejecting new control acquisition after the cutoff. These are behavioral assertions, not source-text checks.

The new native Session persistence tests save real recorded audio and inspect released default/track choices in Save As and Save while the live held values stay unchanged. A blocked ordinary write makes Save wait for the owner queue. The new Bloc persistence case proves PersistFlush waits for explicit Track 8 Auto and later removal preserves absence. These cases do not claim to prove every live session reload/capture condition; independent runtime/adversarial evidence is still needed.

Legacy fixture changes were assessed against the transaction contract. Inspecting the durable owner during a pending mode receipt, instead of assuming staged Settings never change, is correct; rollback assertions remain. Validated offline startup intent surviving a failed native open is intentional. Removing old restore-helper tests is paired with complete-vector startup/owner cases rather than silently deleting their behavior. Ordinary Loop settings tests continue to assert exact values, explicit Auto versus absence, and refusal outcomes. Unrelated family fixtures can use an unavailable narrow port without claiming to test length behavior. Existing production fakes remain valid project seams.

No tests or coverage were run here because both process slots belong to the root/producer verification work. Do not infer green status from source review or producer completion. Final acceptance needs the repaired editor/provider/no-audio cases, current aggregate/static evidence, final source/test hashes, and the root's independent runtime review. Appliance behavior and author-only screenshot rendering retain their separate verification limits.
