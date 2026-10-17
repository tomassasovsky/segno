# Shared Click volume: verification

The final ordinary application run succeeded: 2,573 successful test results,
107 native-only skips and no failures. The result count includes 206 hidden
setup/teardown results. Coverage is 23,915 of 26,446 included lines (90.4296%),
above the unchanged 90% floor. It used no native-library override or author
fonts and excluded author-only screenshots, matching the ordinary CI boundary.
All bound inputs remained unchanged during execution.

Affected package suites also passed: Looper repository 676 successful results
and 12 native-only skips, Settings repository 155, Controller repository 30.
These counts include their hidden setup/teardown results. Coverage is
3,935/4,104 (95.8821%), 689/769 (89.5969%) and 506/608 (83.2237%) respectively.
The configured Looper and Controller floors are 95% and 82%; Settings has no
separate coverage floor. These package source hashes are unchanged from that
run. No coverage thresholds, exclusions or skips were added to pass this slice.

Final formatter, strict analyzer, Bloc lint and whitespace checks all pass.
The explicit source list contains 714 Dart files; Bloc scanned a positive
intended-file count. No input changed during the final static gate.

## Behavior, failures and sensitivity

The independent final candidate passed 55/55 probes against the unchanged
native engine library. All 1,297 bound inputs remained unchanged. The original
52 receipt, rollback, source-lifetime, session-save and shutdown cases passed,
plus the replacement-session recovery defect and two admission-after-checkpoint
failure regressions. The [independent report](raw/independent-execution.md)
records omitted cases and the exact source bindings.

A separate 60-case focused runtime run passed after the final recovery fix.
Root integration verifies real App provider wiring, delayed settings before
halt, visible failure/Retry and retirement of a held MIDI control. Actual
session-file tests verify durable Released capture with native callbacks;
the ordinary suite skips those native cases. Focused results overlap and are
not added to the aggregate count.

The isolated receipt-wait bypass failed the unchanged pending-result assertion
as intended. That negative control is explicitly historical product-v1 proof;
it was not silently rebound to v2. The mechanism and expectation are unchanged,
and the final normal path passes. Earlier failure logs and fixtures are retained.

The initial application aggregate exposed four legacy fixtures using older
mock/lifetime initialization or missing Click-ready expectations. Their existing
musical assertions were preserved; the focused correction passed 137 cases and
received cross-author review. Strict analysis then caught import ordering and
one long screenshot-test line. The final two-line mechanical correction is the
only source delta after the successful application aggregate; it does not
change generated pixels or runtime code. Final strict analysis covers it.

## Native UI and design

Four new 1920 by 1080 native renders cover MIDI Click endpoints, its destination,
External Held/Released endpoints and failed settings confirmation at shutdown.
All four author-only screenshot comparisons pass and were visually inspected.
Pen section `RQYox` groups the four references with labels outside each screen.
Final bounds inspection found no clipping; File > Save cleared the Edited state
and the on-disk hash changed. See [design binding](design.json).

The actual development app was restarted onto this runtime. Its External
picker exposed one Click destination, and both new button endpoints began at
100%. Saving Held at 199%, moving the draft to 1%, then cancelling returned
Held to the saved 199%. The existing unrelated pan mapping was preserved.

This is desktop UI and native-callback evidence, not physical-pedal, hotplug,
audio-device latency or OS power-off proof. The inherited complete session-load
failure with a live Control owner remains a separately reproduced M5 item.
The published head still needs its own CI result before ready-to-merge.
