# Shared Record length: verification

The ordinary app suite passes 2,729 results, including 225 hidden setup/teardown
results, with 114 native-only skips. It excludes screenshots and supplies no
native-library override or author fonts. Coverage is 25,352/27,859 lines
(91.0011%), using only the existing workflow exclusions and unchanged 90% floor.

Looper repository passes 693 results, including 25 hidden results, with 12
native-only skips. Coverage is 4,156/4,348 (95.5842%), above the unchanged 95%
floor. The earlier Settings run is reused after comparing unchanged package
inputs: 171 results, four hidden, no skips, 749/829 lines (90.3498%).
Counts include setup/teardown and overlap focused checks; they are not summed
into an independent-case total. Exact values and hashes are in [checks](checks.json).

Native-backed fuzz runs also pass: 197 app results (169 hidden) and 37 Looper
results (25 hidden), no skips. They exercise existing control/engine regression
paths with the newly frozen library. The unrelated Control fuzzer injects an
unavailable Record length port, so it is not evidence for new length behavior.
The independent matrix supplies that proof.

Formatting, fatal-info analysis, Bloc lint and whitespace checks pass. Bloc
scanned 741 intended Dart files through a verified non-hidden alias. Ordinary,
fuzz and static runs report no source drift. No coverage rule was weakened.

## Independent behavior and failure sensitivity

The pre-implementation oracle remains unchanged. The final independent matrix
passes 44 cases: 26 model/owner/dispatch, ten native/capture/PCM, and eight
lifetime/Session/PowerOff cases. It covers native capture preceding a plain or
same-mode vector, storage compensation, all eight fixed identities, Auto versus
inheritance, Held/Released arbitration, accepted/refused Multi entry and owed
release without interrupting recording. Existing samples, lengths and audio
history survive future-preset changes. Capacity rejection remains atomic.

An isolated receipt bypass fails the predetermined pending-result assertion after
actual enqueue, an unsettled fence and the unchanged raw vector are proved.
The unmodified control passes. The original oracle, runtime and frozen library
remain intact. [Independent execution](raw/independent-execution-v1.md) records
all attempts, hashes and omitted permutations. The final UI and fixture deltas
were reviewed separately, with runtime dependencies unchanged.

Root's actual App cases cover startup Retry, shutdown, failed flush and release
during capture. Two real native Session Save/Save As cases preserve durable
Released lengths while live values remain Held. Bootstrap checks also pass in the final aggregate.
Author runtime, owner, model and page tests pass, including 211 scoped UI/model
results. These overlap aggregate and independent checks rather than increase
their totals.

The narrow C capture guard passes standard, AddressSanitizer, telemetry-disabled
and non-Clang C++ shim checks. The new library SHA-256 is
`8e980280f9fbe6e8ba89d432ba94635ac8e72ddbe1f6503fb7c27050af85bb65`.
No API header, generated binding or firmware changed in this slice.

## Retained failures and corrections

- C1: startup read failure left the owner unavailable without a useful Retry.
  Recovery now repeats complete validation and receipt checking. Malformed
  saved data remains unavailable and intact until repaired.
- C2: cancelling an expression endpoint edit after repairing its target rounded
  the original raw value. A separate cancel path restores the exact endpoint;
  intentional edits still choose whole bars. A real-page red/green test binds it.
- C3: the Multi lock explanation overflowed a control row. The visible label now
  fits with ellipsis; accessibility retains the complete explanation.
- The first aggregate exposed older mocks missing the shared owner/readiness
  contract. Fixtures now model it; assertions were preserved. A timeout test
  now requires blocked restart and explicit recovery before replay.
- The Once timeout fixture originally stalled the global fence before the new
  Length sibling could settle. It now verifies a real healthy Length receipt,
  then withholds only the subsequent Once receipt and awaits the autonomous
  failure event. Original recovery and restart assertions remain.
- The first independent attempt had a native fixture type error; an initial
  overbroad mutant failed setup. Both remain preserved and are not counted as
  product failures or successful sensitivity proof.

## Design and limits

Two new 1920 by 1080 native renders cover MIDI Auto/64-bar endpoints and External
Held/Released lengths. Existing Custom length and generic shutdown references
complete the saved Pen section `GNTYj`. Bounds inspection reports no overflow;
the section and both new renders were visually reviewed. [Design binding](design.json)
records the saved file hash. These are author-only renders, not CI screenshots.

The actual desktop app exposed Auto/Auto for a new external button, allowed a
temporary Held 32-bar edit, and preserved original assignments on Cancel. Multi
disabled fixed-track length with the complete reason available to accessibility.
The final layout fix was checked after hot reload. No review mapping was saved.

The native receipt is inferred from the raw vector, mode and queue fence; it has
no unique command identifier. Identical-vector command history is not uniquely
observable. Representative cases do not exhaust all modes and event orderings.
Physical controls, audio-backend timing and OS halt still need appliance proof.
Full Session Load with live Control remains the inherited M5 item; Save and owner
adoption do not close it. Exact-head CI and human merge approval remain separate.
