# Shared overdub decay: verification

The final ordinary application run passed 2,617 successful test results,
including 210 hidden setup/teardown results, with 110 native-only skips and no
failures. It used no native-library override or author fonts, and excluded
screenshots. All bound inputs remained unchanged. Using only the explicit
workflow coverage exclusions, coverage is 24,365/26,863 lines (90.7010%), above
the unchanged 90% floor. No threshold, exclusion or skip was added to pass.

Affected package suites passed: Looper repository 680 successful results and
12 native-only skips, Settings repository 161, Controller repository 33. Counts
include hidden setup/teardown results. Coverage is 3,964/4,133 (95.9110%),
707/787 (89.8348%) and 515/617 (83.4684%). Looper and Controller retain their
95% and 82% floors. Package source hashes remain unchanged from these runs.
The [machine-readable results](checks.json) retain commands and input stability.

Formatting, strict analysis, Bloc lint and whitespace checks pass. Bloc scanned
723 intended Dart files through a verified non-hidden alias. The final static
and application checks cover the same final Dart source. The standard native
engine/MIDI/plugin suites pass. This slice changes no native C, C++, FFI or
firmware files; sanitizer, telemetry-disabled and platform CI remain required
on the published head.

## Behavioral proof and retained failures

An independent reviewer froze literal expectations before execution. The final
51-case harness passes against the unchanged native library: 42 model, owner,
source-dispatch and lifetime cases, eight audio-sample cases and one actual
session-save case. The isolated negative control reverses native feedback and
fails both endpoint sample expectations: zero decay expected 0.6 but produced
0.2; full decay expected 0.2 but produced 0.6. This reached rendered samples,
rather than failing compilation or an assertion copied from the implementation.

The [independent execution record](raw/independent-execution.md) distinguishes
fixture repairs and failed tooling from product failures. Earlier attempts are
retained; the accepted oracle, literal sample expectations and final source
binding were not weakened. Root reproduced stale read/write exceptions before
repair, then the unchanged private probes passed alongside the prior 13 runtime
cases. Startup tests first failed on inherited-slot replay and pass after the
repository began explicitly replaying all eight slots.

Root's native session run passed eight cases across Decay, Click and MIDI save
and recall. It includes real serialized bundles, explicit Released zero while
live Held values remain audible, and a pending ordinary edit delaying Save.
App tests cover pending edits before shutdown, refusal, Retry, Keep playing and
retiring held values before goodbye. These focused counts overlap other gates;
they are not added to the ordinary aggregate.

The first broad app run exposed an External expression fixture missing the
shared playback provider. Its 20 existing assertions pass after wiring the
same owner into the page and controller. Four other legacy fixtures received
coherent owner/readiness initialization; their 165 focused cases pass. A prior
Once edit no longer cancels unrelated Decay restoration, matching independent
field ownership. Out-of-range Decay now refuses rather than silently clamps.
Import-order repairs were mechanical and precede the final aggregate.

## Native UI and design

Three new 1920 by 1080 native renders cover MIDI endpoint ranges, the Loop
controls destination and External Held/Released decay. The unchanged generic
shutdown-recovery render is reused from M3.11. All new renders passed and were
visually inspected. Pen section `A3mXW` keeps labels outside the four references;
bounds inspection found no clipping. File > Save cleared Edited state and the
on-disk design hash changed; see [design binding](design.json).

The actual development app was restarted onto this product. Adding Loop
defaults decay began with both endpoints at Off / Keep layers. Held 50% and
Released zero saved successfully. Removing that row then cancelling restored
the saved mapping and values. Only the temporary review mapping was removed
afterward; existing pan and Click assignments were preserved.

Desktop UI and deterministic callback tests do not prove physical pedals,
hotplug, appliance audio timing or OS power-off. The inherited complete session
load defect with a live Control owner remains a separately reproduced M5 item.
