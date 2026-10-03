# M3.14 final test-only delta review

No actionable finding. Read-only review; no test process, product edit or assertion changes by this reviewer. Binding `fixture-delta-binding-v1.json` SHA256 `86b1f9ff85c6d87ad80e9a9d2a0ee22856880eeed71082179a1490104534b4bc` includes the four root fixtures and all ten paths in Sol's aggregate-fixtures/freeze-sha256.txt. All ten match that manifest.

All 29 reviewed product hashes remain unchanged after the already reviewed C2/C3 UI corrections. The earlier conservative 1,295-entry source read set included package tests as well as runtime: its only current difference is recording_settings_test.dart, explicitly reviewed below and not imported by the private harness. The other 1,294 entries, actual private runtime dependencies, oracle and native library remain unchanged. The 44-case run and meaningful N1 proof remain valid without another run. The earlier binding is retained, not rewritten.

## Root fixtures

- **control_cubit_test.dart:** new settled-length and transport stubs provide required repository facts. Crucially capture lock derives from the fixture's current track states rather than always returning false; selected/custom transport light tests retain their original true/false assertions and changing engine state. Required unavailable Record length ports are injected into the unrelated Control constructors. No tested dispatch result is fabricated and no assertion was removed.
- **timing_ownership_cubit_test.dart:** complete RecordOptions state expectations now include recordLengthReady=true after the independent length restore/session adoption. Existing auto-record, tempo, Decay and Once assertions remain. This preserves the test's purpose that delayed unrelated settings must not overwrite newer session state; it does not mask length initialization failure.
- **one_shot_transaction_test.dart:** a narrow pre-mask hook settles the already-published healthy Length sibling using the actual repository. It asserts settled/no-recovery synchronously and then awaits the captured successful EngineResult. Only then is the subsequent Once command's global fence stalled. The failure stream is subscribed before start; no owner write or flush drives the timeout. Its bounded event wait replaces the wall-clock 550 ms assumption while keeping Once recovery, stop, failed flush, explicit recovery, successful restart and final confirmation assertions. The hook is cleared before restart. This is a valid isolated callback ordering, not a mocked successful receipt. It directly addresses the preserved aggregate failure explained in once-aggregate-triage-v1.md.
- **recording_settings_test.dart:** the timeout still preserves confirmed four-bar state and stops the uncertain engine. New assertions require recovery=true and blocked restart before explicit recoverLengthSettings; the existing successful restart, all-eight-slot four-bar replay and successful settlement remain. These strengthen the new safety contract rather than weaken the old four-bar expectation.

## Sol fixtures

The ten manifested files contain required-port injection, imports, missing typed failure streams/booleans on older mocks, and one real RecordOptions provider/load/teardown alongside the existing Playback/Tempo owners. No success/failure assertion was removed. FakeRecordLengthControl deliberately reports unavailable and rejects its writes; it cannot certify Record length behavior in unrelated tests. The native fuzzer receives that unavailable owner and is not newly claimed to fuzz Record length. The real owner/native private matrix supplies that separate proof.

Root reports 223 focused passes, the isolated Once case pass, and RecordingSettings 32 passes; Sol reports 76 passes. These are separately owned executions, not new tests run by this reviewer. The earlier failing aggregate remains historical evidence. The observed static v2 record has successful format, analyze, Bloc and whitespace checks; its hash is bound. Full aggregate v2 and exact-head CI remain separate gates.

## Readiness boundary

The final fixture delta is review-clean. Publication documentation has not yet appeared under docs/reviews/shared-record-length at this check, and full aggregate v2 was still in progress. Final PR-readiness review remains pending those public artifacts and finished gate records. No merge-ready claim is made here.
