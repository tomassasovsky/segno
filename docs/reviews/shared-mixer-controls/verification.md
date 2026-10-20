# Shared Mixer controls: verification

## Independent behavior

The final frozen product passed all 52 independent native-backed probes with
all 1,294 bound inputs unchanged. The unchanged previous failing probe now
retains both live and durable gain 1.5 after retiring a MIDI toggle that
superseded an External hold with Released gain 0.4.

Coverage includes literal gain/pan conversions, relative steps, strict
identities, all eight families, missing siblings, ordinary and equal-value
intent, refused writes, source retirement, topology replacement, queued
session changes, shutdown barriers and actual session-file capture. The
native test library is unchanged; no native API or binding changed here.

The gain-law negative control executed an isolated copy with gain `2*travel`.
At travel 0.25 the oracle required approximately 0.0066874 and observed 0.5,
so the check failed as intended. Its evidence is reused because the scale,
target, oracle, harness and native-library hashes remain identical.

## Author verification

Focused model/catalogue checks passed 30 cases and editor/dependent-page
checks passed 74. The final recovery repair passed three focused cases plus
13 neighboring cases, after two failing pre-repair cases. Label and native
screenshot checks passed 48 cases. These are separate runs with overlapping
coverage and must not be added into one test total.

The final ordinary application run passed 2,525 tests, with 88 native-only
skips and no native library or author screenshot font supplied. Coverage is
23,441 of 26,044 included lines (90.0054%), above the unchanged 90% floor.
The affected controller package passed 30 tests, covering 506 of 608 lines
(83.2237%), above its unchanged 82% floor. Both source bindings were stable.
Formatter, strict analyzer, Bloc lint and whitespace checks passed; Bloc
positively scanned 706 files. No native or firmware source changed.

The initial ordinary aggregate exposed older test mocks missing the
coordinator's required topology and state stream. Twelve fixtures were
updated without changing assertions; their focused run passed 652 checks
before the final aggregate. The initial strict analyzer also caught one long
label string, now split into identical adjacent literals. Earlier failures
are retained. No coverage threshold, exclusion or test skip was added.

The independent 52-probe run predates only that string wrapping and fixture
setup correction. Runtime and scale hashes stayed unchanged, so its
behavioral result is retained without another redundant replay. The final
ordinary aggregate and static checks cover the later revision.

## Visual evidence

Four new native renders cover MIDI gains, MIDI placement, External button
pan and External expression gain. Eight affected predecessor renders were
also inspected. The saved Pen section `Native implementation / Shared Mixer
controls / M3.10` contains the four new 1920 by 1080 references, with no
clipped children in the final layout inspection.

The running desktop application was restarted onto this candidate. The
External picker showed whole-track and one-based lane destinations. A track
pan assignment began at Center on both endpoints without moving the mix.
Saving an On value of 62% right succeeded; an unsaved change to 57% left was
cancelled and returned to the saved 62% right value.

Screenshots and desktop interaction establish layout and UI behavior. They
do not establish physical pedal timing, device reconnect or appliance audio.
Published-head CI and the human merge gate remain separate.
