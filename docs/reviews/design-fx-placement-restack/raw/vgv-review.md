# VGV code review

## Status and scope

Source review complete against `a0a54e57ed371c316b9eabcc64379c2c431150cc`, including new recipe sources and tests. Native v3 is reviewed and has no unresolved native findings; Dart product source is reviewed through repository `71f74c3891220c86c54c682f67c4eb4f567076a6f1ebfbc7ab4e9c132acae3bc`, Bloc `3a93404289c66c2715ff9336348469322183b73202f0baf0d088de23c26dfe0d` and MonitorCubit `936ab069514567d913b20572de35888df6ef5c7d20a78538933d9c64e157cd53`. Final fixture and aggregate reconciliation is complete; exact-head publication readiness remains separate. Exact reviewed path hashes and preserved snapshots are recorded privately for the final delta check.

The project uses Flutter/Dart, Bloc/Cubit, Equatable, repository packages, `AudioEngine` as the engine seam, and a C/C++ engine behind generated FFI. The lint configuration includes Very Good Analysis and Bloc lint. No dependency manifest or lint suppression was added by this feature. Final strict analyzer, formatter, Bloc and Dart aggregate results pass as reconciled below.

Five review roles are being performed by two reviewers with different implementation ownership. This is not five fresh independent reviewers. This reviewer did not author the implementation and owns the native bug gate, this VGV pass and simplicity pass; the other reviewer owns the separate architecture report.

## Findings and bounded repair checks

No unresolved actionable source finding. The aggregate exposed a session-replacement regression in the final recipe loop: remembered track chains outside the active track count were retained. The bounded repair removes unowned lane/track chain state without submitting invalid native targets and preserves the original failing assertion in `packages/looper_repository/test/looper_repository_test.dart`. The unchanged regression and final Looper suite pass.

- The explicit input-copy notification finding is source-repaired: `onLaneChainChanged` now routes through the existing settlement helper, and debounce callbacks also use that boundary. Two unchanged independent real-engine Bloc/settings cases now pass: explicit resync and an older parameter debounce hold the prior durable envelope through a 650 ms callback stall, then persist the confirmed replacement with its inherited identity.
- Independent Clear/Undo PCM probes pass enabled and disabled power, fresh dry recording and refused Clear. They caught a history-gate ordering defect: Undo checked the gate before staging the recipe, refusing the gesture rather than deferring it. The repaired sequence stages and confirms the recipe before admitting audio Undo.
- A separate independent restart probe reproduced erased FX returning when Stop/start dropped a pending dry-reset intent. The repaired repository folds history intent after callback quiescence and before replay; the unchanged stop/start probe and a direct-start reconnect-shaped neighbour both pass. Staged but unaccepted Undo is cancelled back to the cleared state. The original failure is retained as sensitivity evidence.


## Important and suggestions

No additional independent convention or style finding. The recipe timeout, unsupported bus identity/capability, monitor live-chain split and pending plugin-parameter findings are repaired in the bound source. Independent architecture review reconciles those caller paths; this review separately covers its authored-code exclusions.

## Reviewed conventions and regressions

- Presentation continues to send typed events to Bloc/Cubit and use domain repositories. New UI state code does not import FFI or storage clients. Engine DTO conversion remains at the domain/engine boundary. The native recipe staging boundary handles actual audio lifetime; Dart does not emulate callback ownership.
- The explicit track-level gain replaces the lane-zero approximation. Mixer reset changes track gain/pan without overwriting part levels, and settings/session/mixdown carry the independent fact. Current session metadata and strict explicit placement/channel rejection were reviewed separately; omitted canonical defaults are not a migration layer.
- Structural edits preserve instance identity, placement, power and channel facts. Placement moves partition at the repository boundary; ordinary reorder refuses crossing a stage. New recipe/image parameter collections are copied. Existing public state is replaced rather than mutated in place.
- Changed setters return `EngineResult`, and the edited Bloc/Cubit callers check admission before changing or saving their state. Boot and session replay submit one final recipe per target and wait before success publication. The actual notification path was also exercised through the real Bloc and SettingsRepository, including the older debounce race.
- Native retirement, immutable prepared recipes, capture ownership and cache view changes were reviewed across callbacks and callers. The full intended native diff plus v2/v3 repairs is complete. No new callback allocation, blocking operation or lock was found. C ABI/generated bindings and all186 exported FFI entry points agree.

## Testing assessment

The changed state-management units retain their tests and add behavioural cases for refusal, exact acknowledgement, placement/identity, independent gain, persistence and session replay. DTO tests mutate caller collections after construction; native tests use actual sample output, cache engagement, queue refusal and host reclamation. The real-engine monitor-to-Record test retains the race window before callbacks drain and now projects the confirmed image through the repository ticker after capture; it does not pre-drain away the race.

Independent numeric and callback-partition probes caught native defects that the earlier aggregate passed. Their original failures are retained and the unchanged probes pass v3. Actual native normal/ASAN/telemetry-off runs each pass744 named tests, plus plugin suites; ThreadSanitizer races and C++ shim pass. Final Dart fixture tests and strict static output are reconciled below; the intended committed fingerprint will be bound after publication. The first aggregate was failed/incomplete; its interrupted process exit zero is not a pass. Final results must include a successful JSON completion and no failed test events. No coverage-only claim substitutes for these behavioural checks.

## Simplicity assessment

No speculative base repository, new framework, compatibility wrapper or unnecessary package was introduced. The shared recipe boundary replaces repeated granular publication loops. Separate live controls remain necessary to preserve DSP state while dragging. No safe line-removal estimate is asserted beyond zero identified unnecessary lines; existing large repository files are not a reason to demand an unrelated refactor in this slice.

## Final source and gate reconciliation

Local review is complete with zero unresolved actionable findings. All 64 changed Dart paths and all 84 native freeze inputs were rechecked against the reviewed fingerprints. The last Bloc test-only amendment is `eb14048224f1bbb3e08dffbe0902803309da82ff71afb24fd1adae70c57dbedf`; it uses the standard error matcher and retains exactly one error and one write. The private combined final review manifest SHA-256 is `d26c60e74a655fb0ea43eb940afd7c76798e356e3b2c9b3e418cafc9e9f53fa4`.

App v4 passed 2401 tests with six unchanged skips; Looper v5 passed its complete suite. The final affected Bloc test file passed all 128 tests. Reused package inputs match, with the reviewed constant-only engine test amendment and Bloc-only amendment recorded separately; no whole-app rerun is claimed for them. Format checked 640 files with zero changes, strict analysis reports no issues, Bloc reports zero issues across 640 actual files, whitespace is clean, and the observed seven-document spelling check is clean. All configured coverage floors pass. Native v3 evidence remains valid with no changed inputs. Exact committed blob binding and remote CI remain later gates.
