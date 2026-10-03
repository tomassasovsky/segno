# Shared Hear click: verification

The candidate is based on `3025840dd212a86ee1b23c21b6980f0ac4866e20`.
The source manifest binds the implementation and tests. Local code, aggregate
and author-render checks are complete. Live app/Pen visual checks and published
CI remain separate gates; this file does not declare merge readiness.

The four choices share one confirmed owner across touch, encoder, MIDI and
External controls. An absent preference means First recording; explicit Off
remains Off. Recording and overdubbing refuse changes without stopping audio.
Held values remain live while Session Save and restart retain Released intent.
Shutdown waits for owed releases and requires explicit recovery when necessary.

| Check | Observed result |
| --- | --- |
| Full app | 2,611 passed, 120 conditional skips; 26,309/28,889 covered lines (91.069%, unchanged 90% floor) |
| Engine package | 352 passed against the immutable repaired native library |
| Native configurations | Standard, ASAN and telemetry-disabled suites plus the C++ shim pass on the repaired native source |
| Independent native oracle | 14 distinct groups and three expected-failing isolated mutations on the first native freeze; the repaired counter-width and publication boundary pass separately |
| Independent integration | All 35 intended behaviors have successful observations across bounded runs, including real native expression movement, Session files and actual App touch Retry |
| Adjacent Click volume | Normal and exactly compensated refusal both flush healthy; uncertainty still blocks shutdown |
| Root composition | 161 focused cases pass, six conditional skips; startup, App and native Session persistence are exercised |
| Settings repository | 184 passed; 793/874 covered lines (90.732%) |
| Session repository | 105 passed; 837/874 (95.767%, unchanged 89% floor) |
| Performance repository | 129 passed; 593/597 (99.330%, unchanged 99% floor) |
| Looper repository | 691 passed; 4,382/4,600 (95.261%, unchanged 95% floor) |
| Static | Explicit-path format and fatal-info analysis pass; Bloc analyzed 757 files with zero issues; whitespace clean |
| Expression layout | Original 42-pixel overflow reproduced; repaired expression suite passes 33 cases and its 1920 by 1080 private render is visually checked |
| Development build | macOS development build succeeds; interactive verification remains pending |
| Pen | New reference section saved; complete-section visual verification remains pending |

Immutable repaired native library SHA256:
`84b0c3b482dd30ded00a999ab72fa51b9c0ba00688e8273d13bdb23894287848`.
Pre-edit independent oracle SHA256:
`fe5eb3d8afdc50bb435476e3cf271f01bcb5eccec73f124d27a921c88ace820e`.

The independent 35-case result is a union of bounded successful observations,
not one uninterrupted green process. Additional private disposal assertions
remain a harness limitation after the actual App shutdown behavior succeeds.
Earlier failing and interrupted runs are retained. Native mutation evidence is
not relabeled as having run on the later binary; the unchanged PCM behavior is
reused with its original source binding.

Review repaired an obsolete startup-read failure that poisoned a newer
session, premature publication of raw mode, truncation of a 64-bit command
reservation, autonomous readiness feedback, and a compensated Click-volume
refusal that incorrectly blocked shutdown. Recovery readouts preserve the last
confirmed choice even when the page is reopened.

The first app aggregate exposed missing mock members and old expectations that
changing Hear click discarded unrelated pending tempo preferences. Fixture
repairs retain the original matching-edit precedence assertion and add a
separate test proving mode-only edits preserve saved tempo and count-in. The
generic repository projection test now requires a confirmed mode rather than
raw callback progress; the receipt regression independently proves that
boundary. No coverage threshold or behavior assertion was weakened.

The first focused fixture rerun also exposed an expression-panel overflow.
The repair reduces spacing in that choice editor while preserving button size;
the affected suite and subsequent full aggregate pass. Author-only golden
renders and the private expression capture are separate from CI and actual
device interaction. After the full aggregate, only equivalent adjacent string
literals and an import ordering fix changed Dart; final static checks cover
both exact files. The passing aggregate's before/after source binding had no
drift.

Limits: desktop and deterministic native checks do not prove appliance audio,
physical pedals, MIDI timing or power loss. The future capture journal must add
its stopped failed-finalization lock to this shared owner before that producer
ships. Full live-Control Session Load remains an M5 dependency. Published-head
CI, final review and the human merge gate remain separate requirements.
