<!-- cspell:words heatsinks Omron -->
# Segno — Progress & Roadmap

<!-- cspell:words hashlib manufacturability unassembled Axicom Mbps raucs -->

Living status doc for Segno, the live looping appliance (a Raspberry Pi 5
console). It began as a Flutter desktop loopstation; the original plan is
`docs/plan/2026-06-08-feat-flutter-desktop-loopstation-plan.md`. macOS and
Windows were dropped as targets in #920, so desktop-era entries below are
history.
Update this as work lands so any session (human or agent) can resume cold.

Repo: https://github.com/tomassasovsky/segno · branch `master`.

---

## Active threads

Issues with a live branch. Agents add a row when a thread starts, update it
when its stage changes, and remove it in the PR that closes the issue or when
the work is parked (rules in `AGENTS.md`). Stage and autonomy are copied from
the issue labels, which are authoritative; if a row disagrees, fix the row.

| Issue | Thread | Stage | Autonomy | Branch |
|-------|--------|-------|----------|--------|
| #1433 | Looper X racks part 9: pitch groundwork (bench, hop split) and Pitch Shift | in-review | merge-gate | `claude/fx-pitch-1433-p*` |
| #1430 | Looper X racks part 8: Spring (fit to captures); Dub-Verb and Amb-Verb wait for a capture | in-review | merge-gate | `claude/fx-spring-1430` |
| #1388 | MODE footswitch moves from GP5 to GP12 (firmware 2.4; design PR separate) | in-review | auto | `claude/console-mode-gp12-1388-fw` |
| #1367 | Start helper programs with posix_spawn, never fork the app | in-review | merge-gate | `claude/no-fork-1367` |
| #900, #906 | The audio thread never faults or copies on write (replaces #907, #914) | in-review | blocked-verify | `claude/zero-stall-memory-907-914` |
| #1299 | Appliance slowdown profiler | in-review | merge-gate | `claude/appliance-responsiveness-08d39b` |
| #1301 | Idle console redraws at 60 fps | build | merge-gate | `claude/idle-redraw-1301` |
| #1337 | Retry Wi-Fi after a runtime drop, holding off while performing | in-review | blocked-verify | `claude/wifi-runtime-retry-1337` |
| #1349 | Console LEDs dim with the screens (protocol 11, console 2.2, ring 1.1) | build | blocked-verify | `claude/idle-dim-leds-1349` |
| #1352 | Console negotiates the charger's full 20 V current, with a power-cycle prompt | in-review | blocked-verify | `claude/pd-provisioning-1352` |
| #1081 | Console v3 and ring carrier firmware on protocol 10 | in-review | merge-gate | `claude/console-v3-port-1081` |
| #1077 | Song queue completion | in-review | blocked-verify | `claude/song-queue-comet-1077` |
| #1140 | Keep recorded material across audio-engine reopen | in-review | merge-gate | `claude/engine-reopen-1140*` |
| #1143 | Replay audio-history changes in performance stems | build | merge-gate | `claude/stem-history-replay-1143` |
| #1144 | Report render manifest failures | in-review | merge-gate | `claude/manifest-failure-1144` |
| #1146 | Guard fresh capture preparation | in-review | merge-gate | `claude/capture-prep-guard-1146` |
| #1159 | One settings-transaction owner | (none) | merge-gate | `claude/settings-owner-1159-*` |
| #1164 | Foot Peel | plan-review | merge-gate | `claude/peel-plan-1164` |
| #1168 | Foot Multiply and Divide | plan-review | merge-gate | `claude/multiply-divide-1168-*` |
| #1177 | Appliance USB storage service | build | merge-gate | `claude/usb-storage-1177-*` |
| #1178 | Library and Sessions redesign | build | merge-gate | `claude/library-1178-*` |
| #1179 | Pitch and time DSP core | build | merge-gate | `claude/pitch-time-1179-*` |
| #1197 | Instruments | plan | merge-gate | `claude/instruments-1197-*` |
| #1198 | Recording to USB and long recordings | plan | merge-gate | `claude/recording-1198-*` |
| #1200 | Backing player | plan | merge-gate | `claude/backing-1200-*` |
| #1202 | Shared render recipe, Bounce, Save selected | plan | merge-gate | `claude/render-1202-*` |
| #1228 | MIDI clock | plan | merge-gate | `claude/midi-clock-1228-*` |
| #1270 | Device and appliance pages | plan | merge-gate | `claude/device-pages-plan-1270` |
| #1342 | Ring carrier firmware updates from the console | in-review | blocked-verify | `claude/ring-update-1342` |

---

## October 2026 RAUC status off the FAT boot partition (#1397)

An unclean power-off twice left a broken cluster chain in RAUC's
`/boot/rauc/central.raucs`. The kernel remounted the FAT `/boot` read-only and
every install failed. RAUC's `data-directory` is now `/data/rauc` on ext4, and a
`rauc.service` drop-in waits for `/data` and `/boot` and creates the directory.
`boot.mount` pulls in `systemd-fsck@` for its device, so `fsck.vfat -a` repairs
the partition before it mounts and logs what it changed to the journal.
`segno-update-ctl install` exits 3 when `/boot` is read-only, and the Updates
page then tells the player to restart instead of reporting a failed download.

Shell tests cover the helper under bash and dash, and a static test covers the
RAUC and fsck wiring. Dart tests cover the env, cubit and page. Device checks
are owed: `rauc status` reads the new file, the boot journal shows the fsck
unit, and an install followed by mark-good succeeds. Existing units start with
an empty status file. The stale `/boot/rauc` directory is left in place,
because nothing reads it.

## October 2026 Clear history and Fade (#1142)

Clear and grouped Clear now retain the Fade amount applied at the audio boundary;
Undo restores stationary levels before playback, with ordinary mute and frozen
history preserved. Performance capture records exact restored material through
its existing staging and renderer owners. Invalid source transitions fail their
derived stems while the independently recorded master remains usable.

The [review](code-review/fade-clear-history/review.md) records the native safety
matrix, six actual-native repository tests, all 187 FFI symbols, package coverage
and independent source reviews. Production adds 323 lines and removes 108, with
no additional state owner. General history replay (#1143), whole-render manifest
errors (#1144), reopen (#1140) and Fade controls remain separate work. Actual
Claude, published-head CI and human merge gates remain pending independently.

## October 2026 stationary Session Fade (#1139)

Sessions now save recorded tracks' current Fade amounts and restore them as
stationary levels before publishing stopped playback. Material finalization and
all Fade confirmations complete first; rejected or retired imports are cleaned up.
The implementation extends five existing production files without another owner
or native API. Exact Session schema 11 requires the saved amounts.

The [review](code-review/session-fade-levels/review.md) records 3,166 passing app
tests, 716 ordinary Looper tests and 116 Session tests, plus 21 actual-native
focused checks. Coverage floors, analysis, formatting and positive Bloc lint pass.
Independent review repaired two test issues without production changes. Claude,
published-head CI and human merge remain separate gates. Full-engine reopen
retention (#1140), Clear/history and public Fade controls are separate follow-ups.

## October 2026 Fade duration persistence (#1137)

Fade defaults and explicit per-track durations now survive startup and Session
save/recall through one settings writer. Failed writes restore the previous
record or require explicit recovery. Incoming Session settings finish before
the existing boot barrier releases; an active fade keeps its original rate.

The [review](code-review/fade-duration-settings/review.md) records 3,162 passing
app tests (49 conditional skips), 198 settings tests and 114 Session tests, with
all applicable coverage floors met. Analysis, formatting and 811-file Bloc lint
pass. Independent reviews are clean after bounded fixes. Actual Claude,
published-head CI and human merge approval remain separate gates. Coefficient
recall/reconnect, Clear/history and Fade controls are still separate follow-ups.

## October 2026 stopped Session recall (#1134)

Session recall now publishes recorded tracks stopped, with timing and crown
preserved, and keeps ordinary transport edits blocked until saved settings finish
applying. Explicit Play starts the recalled material. Unavailable audio devices
are rejected before destructive work; settings-only empty loads still work.

The [review](code-review/stopped-session-recall/review.md) records the local gates:
3,142 app tests, 715 ordinary Looper tests, 112 Session tests and 356 Engine tests
pass; coverage meets every affected floor. Native safety configurations, FFI,
analysis, formatting and positive Bloc lint pass. Independent reviews are clean;
Claude review, published-head CI and human merge approval remain separate gates.
This prerequisite does not complete Fade duration or Session persistence.

## October 2026 native track Fade (#1131)

The native Fade capability now has independent per-track envelopes, confirmed
callback results and matching performance-log rendering. It changes neither
saved Mixer gain nor recorded PCM. Existing playback remains at full Fade level;
user-facing control and durable Session/reconnect composition are separate parts.

The [review](code-review/foot-fade-native/review.md) binds the candidate and its
checks: native standard, sanitizer, telemetry-disabled and C++17 pass, as do all
187 FFI symbol lookups. App tests pass 3,137 cases at 92.634% coverage; ordinary
Looper coverage is 95.136%, with four additional actual-native Fade tests.
Analyzer, formatter and 806-file Bloc lint pass. Independent reviews repaired a
Session-retirement receipt leak and have no remaining actionable finding.
Actual Claude review, published-head CI and human merge remain separate gates;
no appliance validation or deployment is claimed.

## October 2026 recording-start pair (#1026)

Count-in and Sound-start now share one confirmed setting across Recording,
Tempo, both Audio setup surfaces, startup and Session save/recall. Count-in
above zero disables Sound; enabling Sound turns Count-in off. Explicit Off
remains Off, while a new setup defaults to one bar. Capture refuses edits;
unknown or failed acceptance stays visibly unavailable until recovery.

Storage writes preserve exact prior keys on failure, and native callback
receipts confirm changes before publication. Fresh recordings wait for a
confirmed pair; cancellation and finishing remain available. Sound-start
requires a usable selected input before arming and reports the affected track
when one is missing. Session save and shutdown wait for settlement.

The [part-one plan](plan/2026-10-03-feat-count-in-part-1-plan.md) defines this
boundary. Native standard, sanitizer, telemetry-disabled and C++ checks pass.
Independent tests caught and repaired a countdown-cancellation ordering defect.
The saved Pen section contains five checked native captures. The full app
passes 2,789 tests at 91.927% coverage; all five affected package suites meet
their required gates. Static checks cover 763 Dart files, and independent review
has no unresolved finding. A bound native desktop build passes the paired
Count-in/Sound interaction and all 182 FFI symbol lookups. Exact-head CI and
human merge remain separate. Shared launch countdowns and mapped
Count-in are the next two parts; they are not implemented by this part.

## October 2026 shared Hear click (#1026)

Touch, encoder, MIDI and External controls now share Off, First recording,
Recording and Play & record. New setups default to First recording; explicit
Off is preserved. Native callback receipts confirm changes before publication.
Recording and overdubbing refuse edits without stopping audio. Session Save and
restart retain Released values while Held remains audible, and safe shutdown
waits for owed releases or presents recovery.

`docs/reviews/shared-hear-click/` binds the candidate and independent evidence.
The app passes 2,611 tests at 91.069% coverage; Looper passes 691 at 95.261%.
Engine passes 352 against the repaired native library. Native configurations,
affected package suites and 757-file static checks pass. Independent review
closed callback publication, command counter width, obsolete initialization,
recovery readout and compensated-flush defects. Author renders include the
repaired expression choice layout. The saved Pen section has passed its final
composite visual check. Native desktop interaction still needs verification
against a bound build. Published-head CI and human merge remain separate.

Count-in and its Sound-start interlock are next. The future capture journal must
extend the capture lock before stopped failed-finalization takes ship; no such
producer is implemented by this slice. M5 full live-Control Session Load and
physical appliance checks remain open.

## October 2026 shared Record timing (#1026)

Touch, MIDI and External controls share the seven recording-timing choices for
Loop defaults and fixed Tracks 1–8. Explicit Immediately remains Custom; null
restores inheritance. Waiting requests can be rescheduled or cancelled without
changing unrelated arms. Capture refuses edits without stopping audio. One
native vector and coherent receipt replace the split timing writers; record
acquisition is fenced before plugin, layer or history preparation.

Held timing stays live while Save/restart retain Released intent and remembered
division. Exact rollback preserves absent settings. Shutdown refuses unfinished
release cleanup; Retry and Keep playing retain their distinct recovery behavior.
The shared owner composes startup, session capture and the existing settings UI.

`docs/reviews/shared-record-timing/` binds the implementation, independent review,
tests and saved Pen references. Full app: 2,552 passed at 90.989% coverage; Looper:
675 passed at 95.344%. Native variants, snapshot/preparation negative controls,
affected independent replay, Engine/Settings/Session/Performance packages and
748-file static checks pass. Author-only renders and native desktop interaction
are recorded separately. Published-head CI, human merge, appliance verification
and M5 full live-Control Session Load remain separate gates. Hear click is the
next bounded shared-control slice.

## October 2026 shared Record length (#1026)

Touch, MIDI and External controls now share Auto/1–64-bar choices for Loop
defaults and fixed Tracks 1–8. Explicit Auto stays Custom; Multi retains latent
track overrides. Capture blocks edits without stopping audio. Held values stay
live while Save/restart preserve Released choices, and refused cleanup retries
when safe. Startup and shutdown require confirmed state or explicit recovery.

`docs/reviews/shared-record-length/` binds 88 source/test/render paths and saved
Pen references. Ordinary app checks pass 2,729 results at 91.0011% coverage;
Looper repository passes 693 at 95.5842%, Settings 171 at 90.3498%. The 44-case
independent matrix and receipt-bypass negative control pass their expectations.
Native configurations, native-backed fuzz and 741-file static checks pass.
Review repaired startup Retry, raw endpoint cancellation and a clipped lock
label. Published-head CI, human merge, physical proof and M5 live-Control full
Session Load remain separate. Shared Record timing is the next bounded slice.

## October 2026 shared Playback Loop or Once (#1026)

Touch, MIDI and External controls now share confirmed Loop/Once choices for
Loop defaults and fixed Tracks 1–8, including empty tracks and all five modes.
Explicit false remains Custom. Use default supersedes older held cleanup;
Save and reconnect preserve authored Released values. Startup validates all
nine stored choices and verifies the eight native bits. Shutdown drains pending
changes and offers recovery instead of losing them.

`docs/reviews/shared-playback-choice/` binds source and saved Pen references.
The final app suite passes 2,666 results at 90.7948% coverage; Looper repository
passes 686 at 95.7472%. Settings and Controller results are reused only for
unchanged sources. The independent 50-case matrix covers all native modes, and
an isolated receipt bypass fails the expected pending assertion. Strict static
checks cover 733 Dart files. Review caught and fixed startup-validation Retry
and reconnect-readiness defects. Exact-head CI and human merge approval remain
separate; hardware proof and M5 live-controller full Session Load remain open.

## October 2026 shared overdub decay (#1026)

MIDI and External button/expression controls now share the Playback owner for
Loop defaults and fixed Tracks 1–8. Explicit zero remains Custom; Use default
removes only that field and supersedes older held cleanup. Storage is verified
before acceptance. Sessions/restarts retain Released intent, and shutdown waits
for pending changes and refuses on unresolved recovery.

`docs/reviews/shared-overdub-decay/` binds the source, saved Pen references and
local evidence: 2,617 ordinary app results at 90.7010% coverage, three affected
package suites, 51 independent probes, a native-sample negative control, eight
native session cases, standard native suites and clean strict static gates.
Startup replay and stale-error defects found during review are repaired. CI on
the published head and human merge approval remain separate. Hardware and the
inherited complete session-load defect with a live controller owner remain
explicit follow-up work.

## October 2026 shared Click volume (#1026)

Click volume now shares one confirmed owner across touch, MIDI and External
buttons/expression. The same linear range appears as 0–200%, with unity at
100%. Temporary held values do not enter saved sessions or engine restart
intent. Settings and native acceptance are checked; explicit recovery keeps
old failures separate from replacement sessions. Shutdown retires controls,
waits for settings and stays on after a failure with Retry or Keep playing.

The [verification record](reviews/shared-click-volume/verification.md) binds
83 intended files, 55 independent native-backed probes, ordinary app coverage
of 90.4296%, affected package gates and strict static checks across 714 Dart
files. Four native references are saved in Pen. Earlier failures and repairs
remain documented. No native/FFI or firmware source changed. Published-head
CI, human merge and physical device validation remain separate. Shared decay
and the remaining loop targets follow; the M5 live-owner session-load issue
is still open.

## October 2026 shared Mixer controls (#1026)

MIDI and External assignments now share eight typed Mixer control families,
actual-unit endpoint readouts and one confirmed durable transaction. Input
monitor level remains separate from recording trim. Missing targets retain
their identity; source retirement and topology replacement preserve newer
accepted changes. Session capture saves Released values while a control is
held. Four new native references are saved in Pen.

The [verification record](reviews/shared-mixer-controls/verification.md)
records 2,525 ordinary app tests at 90.0054% coverage, 30 controller tests at
83.2237%, static checks across 706 files and 52 independent native-backed
adversarial probes. Failed prior cases and repairs remain documented. No
native API or firmware changed. Click/loop targets follow next. Broader live
session-load publication remains tracked for M5; physical controllers,
published-head CI and human merge are separate gates.

## October 2026 MIDI reconstruction (#1026)

MIDI setup now selects explicit message formats, learns stable sources and
edits multiple action or value targets through the shared control owner.
Save/Cancel, source overlap, missing-target repair, pause/retry and session
replacement preserve confirmed state. Pending effect writes and momentary
restoration join the session/shutdown persistence barrier. Obsolete MIDI
bindings and the old editor are removed.

The [verification record](reviews/design-midi-controls-restack/README.md)
records 2,433 passing application tests, nine package suites, native checks,
coverage, independent review and adversarial probes. Native renders are saved
in Pen. The broader shared target catalogue remains the next M3 slice;
physical MIDI validation, published-head CI and human merge stay separate.

The first MIDI publication passed tests but failed ordinary CI coverage at
89.07%. A reviewed test-only correction adds 23 editor journeys. The matching
local run excludes author screenshots and supplies no native library: 2,306
tests pass at 90.0039% coverage, with static gates clean. All 20 workflow jobs
and GitGuardian subsequently passed on PR #1047 head
`06633b2b537efba4c59108e38764e58c0b2c542e` (run 36935129976). The current-head
review is clean; human merge and physical MIDI validation remain separate.

## October 2026 external pedal reconstruction (#1026)

Single, Dual and Expression now share a confirmed External setup and the
existing UART CTRL ingress. Multiple actions, FX activation, parameter ranges,
directed calibration, unavailable-target repair and independent jack profiles
are implemented. Source retirement and refused release cleanup preserve newer
accepted controller contributions; the old generic console editor is removed.

The [verification record](reviews/design-external-controls-restack/README.md)
binds the final source, 2,467 passing app tests, five package suites, coverage,
firmware and 54 independent adversarial probes. Source and five quality-role
reviews have no unresolved actionable finding. Native render references are
saved in Pen. Published-head CI and human merge remain separate gates; physical
pedal validation is not established by the desktop checks. The MIDI slice above
builds on this verified dispatch foundation.

## September 2026 design-stack reconstruction (#1058)

The accepted Tracks, selected-track display and crown slice (#1010 / #1011)
is reconstructed on current master, retaining its UART console and appliance
lifecycle. Review corrected full-track waveform coordinates, stopped-waveform
retention, divided/independent bar counts, and compact desktop Wave layout.
See the [slice ledger](plan/2026-09-09-segno-implementation-ledger.md) and
[validation record](reviews/design-tracks-restack/validation.md). The remaining
stack is still pending reconstruction; no appliance deployment is implied.

## October 2026 Loop settings reconstruction (#1012)

The Loop settings slice is reconstructed on the verified recording-timing
stack. Default and per-track choices retain field-level inheritance, including
explicit Auto and Loop overrides. Length and mode requests submit one bounded
engine command and publish or save only the callback-confirmed result. Startup,
recall, timeout and device reconnect use the same confirmed state boundary.
Touch and keyboard focus cover edit, commit and Cancel; obsolete Loop and
coarse timing controls are removed. See the
[validation record](reviews/design-loop-settings-restack/README.md).

Follow-tempo/pitch processing remains explicitly unavailable until its engine
slice. Physical encoder routing remains in the controller slice; desktop focus
checks do not establish UART or appliance behavior. No deployment is implied.

## October 2026 FX surface reconstruction (#1016)

Effects now uses the accepted destination/library/editor flow on the verified
mix, routing and Pre/Post stack. Adding a single or rack opens its confirmed
new instance directly. Structural edits retain stable identities, reject full
destinations and cannot complete against a replacement session. Saved presets
retain rack identity and create independent instances. The obsolete Signal
surface and its unused cache controls are removed.

Native, package and app checks plus independent source and visual reviews are
recorded in the [verification record](reviews/design-fx-surfaces-restack/README.md).
Exact factory parameter/DSP completion remains M6 work; physical appliance
validation and the human merge gate remain separate. No deployment is implied.

## October 2026 pedal gesture reconstruction (#1026)

FX assignments now carry separate Press/Hold targets and explicit fixed or
selected-track scope, using the existing UART control owner. Holds resolve
selection when they fire and retain that target until release. The accepted
800 ms default is shared with Settings; normal Record/Play and Stop remain
immediate. Session changes, take locks and disconnects invalidate pending
work without applying it to a replacement session.

Refused momentary restoration waits for callback readiness, removed effects
do not strand a pedal, and LEDs follow the successfully dispatched action in
the correct bank. The
[verification record](reviews/design-assignments-restack/README.md) separates
independent behavioral checks from physical pedal validation. Layout A setup,
Custom mode and external/MIDI assignment surfaces are the next dependent
slices. No appliance deployment or human merge approval is implied.

## October 2026 Custom pedal runtime (#1026)

Layout A now edits and runs Custom Press/Hold assignments. Mode exits and Bank
pages; fresh Mode defaults to Mute/Custom. Gesture lifetime follows accepted
selection, session and connection rules. Grouped Solo shares the app-wide mix
coordinator, and Clear/Restore preserves unrelated setup edits. See the
[verification record](reviews/design-custom-runtime-restack/README.md).

Application and independent behavioral checks pass. Configurable physical LED
colors and all-ten activity transport are the next slices; no appliance
installation or human merge approval is implied.

## September 2026 PCB routing completion

**September 28 Revision P completed: H1 ground-contour cleanup.**
Claude removed two obsolete front-ground exclusions beside H1 that caused
notches in the rounded copper boundary. All traces, vias, pads and placements
remain unchanged. Strict checks pass: zero ERC/DRC findings, 123 fault controls,
415 screen fabrication comparisons and 175 unchanged console/ring comparisons.
The conservative copper-loss model is 15.93 mV, below the retained 20 mV
allowance. Independent source/export review is clean, with earlier full circuit
reviews retained for unchanged scope. The owner confirmed
that the available cables physically reach; conductor gauge, insulation,
shielding and assembled USB performance remain separate. A fresh full Mouser
quote shows all 55 lines / 192 units available at the check, with $69.81 parts
and $9.94 estimated tariffs. The matching shared cart adds $8.49 selected
UPS Ground shipping, totaling $88.24 before tax; final address and tax are
not entered and no purchase was made. See the
[Revision P review](reviews/screen-power-ground-cleanup-1072/review.md).

**September 28 Revision O completed: fully removable USB shields.**
The four screen-board USB headers now use XH5, with pin 5 carrying the shield
to GND and no separate soldered tether. Local placement and rounded power
routes clear the longer headers; the two-layer outline, power circuit and
292 USB copper items are retained. Fresh checks pass: zero ERC/DRC findings,
123 deliberate faults, 415 screen manufacturing comparisons and 175 unchanged
console/ring comparisons. Conservative copper loss is 15.93 mV below its
20 mV allowance. The final populated review also corrected a hidden CTRL label.
Five independent local roles and the bounded model review completed without
unresolved findings. Claude helped author the change, then reached its limit;
there is no new Claude approval of Revision O. See the
[current review](reviews/screen-power-xh5-1072/review.md) and
[manufacturing identities](reviews/pcb-finish-all-three-1072/manufacturing-zips.json).
The combined Mouser import is 55 lines / 192 units, estimated $88.22 before
tax with only changed connector/contact prices freshly checked. Current-head
CI and assembled USB/enclosure qualification remain separate; no order,
merge, flash or deployment occurred.

**September 28 Revision N all-three-board adversarial review completed.**
Claude's console continuation returned a successful final verdict after the
reset, closing the last outstanding review. All three Claude and DeepSeek
passes are now complete, with no unresolved actionable PCB finding. The
console pass verified unchanged production identities, reviewed the committed
assembly/wiring corrections and closed the screen-side GPIO17 default-off
coverage gap. Unchanged prior full-review evidence is explicitly retained;
no claim is made that every model reread every unchanged file. See the
[completed coverage and disposition](reviews/pcb-revn-adversarial-1072/review.md).

The audit corrected the obsolete Rev M order selection, external-fuse and
negative-gate-driver instructions, and old wiring budget. Ring USB programming
keeps AUX and the separate strip feed off until USB is removed and J1 restored.
No native board, BOM, circuit or Gerber ZIP changed during this closeout.
The exact files retain their passing native/CAM evidence and are accepted
for bare-board fabrication. The final review hold is lifted; current-head CI,
assembled qualification, enclosure mounts and runtime installation remain
separate. Nothing was ordered, merged, flashed or deployed. Earlier review
entries below are historical.

**September 28 Revision N and copper-finish review.** The screen board now
uses a stocked Omron power relay and coil driver, one removable 8 A input
fuse in a PCB holder, and four soldered branch fuses. The consolidated Mouser
US quote is $86.56 estimated before tax including tariffs and shipping;
all 53 lines / 168 requested units were available at the final recheck.
The screen copper audit removes the AUX stub, redundant via extension and
pointed ground ends; two ring front-ground dead ends are removed. Console
copper, ring tracks/pads/rear ground and all 292 USB copper items/18 anchors
are retained. All three boards remain two layers and hand-soldered.

Final DRC is zero/zero on all three boards; screen ERC is zero and all 103
screen fault controls pass. Exact final filled-copper calculation gives
12.760–13.158 mV nominal loss and 15.366 mV in the thinner-material sensitivity
against the retained 20 mV allowance. Independent native/CAM comparison
passes 175 console/ring and 415 screen assertions. See the
[Revision N review](reviews/screen-power-stock-cost-1072/review.md),
[bug-focused gate](code-review/pcb-stock-cost-1072/review.md), and
[current archive manifest](reviews/pcb-finish-all-three-1072/manufacturing-zips.json).
Claude's September 27 verdicts below cover the preceding design; no new
Claude approval is claimed for N after its service failures. Independent
local roles and bounded DeepSeek component review cover the new work.
The planning AUX load is 7.818 A with normal pills and the full-white 40-pixel
strip using its direct harness. Assembled qualification, full current-head CI
and runtime/enclosure integration remain separate. Nothing was ordered,
merged, flashed or deployed. Earlier entries below are historical.

**September 27 final Claude review completed.** All three saved sessions now
returned completed final verdicts on design revision
`60ff3a637a400deb1ce846f6cb76979c94250a32`, with no open actionable board defect.
The screen's additional manufacturer-source follow-up also completed, closing
its two direct-read gaps. See the [completed verdicts](code-review/pcb-claude-followup-1072/claude-review-status.md).
No further design, routing, BOM or executable firmware changes were required.
The stale auxiliary console DRC report was rerun: zero violations/unconnected
pads, date-only report change. All 97 production inputs and the three native/ZIP
identities are preserved. The documentation release adds the final review
records and their hashes to the manufacturing manifest. Assembly qualification,
runtime/enclosure integration and current-head CI remain separate; nothing was
ordered, merged, flashed or deployed. The earlier interruption below is history.

**September 27 Claude follow-up: verified circuit and assembly corrections.**
The [current correction review](code-review/pcb-claude-followup-1072/review.md)
resumes all three saved Claude reviews and independently adjudicates their
findings. Screen R2 is 4.7 kΩ, 1%; ring C2/C3/C4 are 10 nF, with hand-soldering
thermal relief and a separately specified 1000 µF strip-entry capacitor.
Console R11/R12 now use Pico 3.3 V, and CTRL pin 4 uses the jack's RN contact.
Claude authored the native changes. Independent review caught and closed a
new 0.3 mm console supply segment; the final connection is uniformly 0.6 mm
with a native rounded bend. No component placement or outline changed.

Fresh final native DRC is zero/zero on all three boards. All 77 screen self-test
checks, 24 console circuit controls, 15 layout controls and the retained
power guards pass; ring source/encoder controls pass 8/13 cases respectively.
Independent current CAM comparison passes 175 console/ring and 412 screen
assertions. All boards remain two layers. Current runtime is #1082 at
`53828fc4eae1c18af45abfc3ea7c31f19f9799d7`; its latest three documentation changes
match RN wiring without changing behavior, and all eight firmware suites pass.

Claude completed its initial reviews and applied the final CAD correction,
but its usage limit interrupted the last follow-up verdict; no final Claude
approval is claimed. See the [exact review coverage](code-review/pcb-claude-followup-1072/claude-review-status.md).
Only the [current archive manifest](reviews/pcb-finish-all-three-1072/manufacturing-zips.json)
identifies order files. Bare-PCB acceptance does not complete runtime/enclosure
integration, assembled qualification or current-head CI. No order, merge,
flashing or deployment occurred. Earlier paragraphs below are historical.

**September 26 repeat production review: encoder and UART corrections.**
The [fresh all-three-board review](code-review/pcb-final-repeat-1072/review.md)
found and closed the ring encoder part/footprint mismatch and the console A2
UART resistor margin. The selected encoder is Same Sky ACZ11BR1E-20FD1-20C,
with its exact threaded-part footprint and separately sourced mounting nut.
Console R18 is now 6.8 kΩ, 1%; console copper is unchanged. The former ring ZIP
is withdrawn. Screen Revision M copper is unchanged, with freshly regenerated
exports and input hashes. All three boards pass native ERC/DRC, and independent
CAM comparison passes 175 console/ring and 412 screen assertions. Independent
correction reviews and the completed DeepSeek follow-up close the findings.
The new-board encoder direction/bounce fix is separately pushed in runtime
#1082 at `dd46ab0d1a44bc55c7f42bc7db7992773c7a4113`; nothing was flashed.
Use only the [current archive manifest](reviews/pcb-finish-all-three-1072/manufacturing-zips.json).
This supersedes the earlier statement that console/ring inputs were unchanged.
Bare-board CAD/CAM acceptance does not establish assembled USB, enclosure or
runtime qualification; full CI remains unavailable on the stacked feature base.
No order or merge occurred.

**September 26 USB correction: Revision M CAD and manufacturing files pass.**
[Revision M](reviews/screen-power-usb-revision-1072/review.md) replaces the
host-powered relay coils with AUX-powered coils and per-host low-current
presence detectors. Claude authored the placement/routing correction, with
local native KiCad checks closing the remaining copper and silkscreen faults.
The complete rebuilt board has zero DRC, unconnected or ERC findings; all
75 fault-detection controls, 50 component models and 6,264 USB ground-reference
samples pass. Independent comparison passes 412 manufacturing assertions.
Four shield-drain pads retain the XH4 cable interfaces, with documented local
cable construction. The 0.78/0.23 mm USB pairs retain matched paths; the
coated-field estimate is about 90.8 ohms, while ordinary two-layer fabrication
still has no impedance guarantee. The corrected AUX planning budget is
7.708 A with a full-white 40-pixel ring and normal pills.
Use the [current archive manifest](reviews/pcb-finish-all-three-1072/manufacturing-zips.json).
Revision L screen Gerbers remain withdrawn; console/ring files are unchanged.
This closes bare-board CAD/CAM correction, not assembled USB qualification,
whole-PR CI or a merge. No order or device deployment has occurred. Earlier
screen completion text below is historical.


The [final production review](reviews/production-final-1072/review.md) supersedes
the earlier release checks below. It reviews the complete circuits, all three
native boards, wiring, current budgets, thermal estimates, mechanical envelopes
and exact manufacturing exports. It corrects sub-minimum silkscreen dimensions,
selects the actual 40-LED strip in the purchasing BOM, removes old ring wiring
instructions and names the separate v3 runtime needed for A2 presence inputs.
Console and ring USB-programming isolation is now explicit. The screen's
proposed enclosure location still needs its floor holes incorporated in the
enclosure release; this does not change the fixed PCB outline. No order, merge
or deployment is part of this review.


The September 26 final PCB review additionally replaces the selected 40-pixel
ring's straight-through power harness with a direct AUX star feed near the strip.
Only DIN uses carrier J2; console J6 carries only the two UART wires. This closes
the hot-wire/aged-contact voltage-margin gap without changing PCB copper. See
`docs/reviews/production-final-1072/ring-voltage-margin.md` and the current wiring.

The September 26 [all-three-board audit](reviews/pcb-finish-all-three-1072/audit.md)
records the current native boards and replacement manufacturing archives.
The final pass rounds the remaining exposed signal/control bends as well as
the power routes, closes the console's 0.05 mm slot beside J24, retains the
ring's two straight vertical taps and moves C20 beside its supply pin.
Screen C4 is aligned with the charge-pump pin. A subsequent
[U1/U2 alignment correction](reviews/screen-u2-alignment-1072/verification.md)
puts both packages on common pin rows while preserving their stock courtyards.
USB pairs use mirrored rounded bends with their widths, gap and ground
reference verified independently.
The Q3/Q4 source bridge and drain feeder remain uniformly 2.5 mm wide and
the AUX input remains 2.0 mm. All boards retain two copper layers.
Work follows the owner's one-order requirement, with no pre-PCB prototype
or new owner measurement campaign. The
[gate-drive assessment](reviews/screen-power-rev-l-1072/gate-drive.md) supports
an LMC7660/TLP627M negative gate supply and lower-voltage TN0702 relay drivers;
the [startup assessment](reviews/screen-power-rev-l-1072/startup.md) does not
establish a need for active current limiting. Claude Cloud authored placement
and explicit routing changes; independently reviewed local corrections finished
the remaining geometry after its session became inaccessible. Final native
DRC is zero/zero on all three boards, and screen ERC is clean. All 56 screen,
11 console-power and 7 ring-power fault controls pass, along with 13 native
rounding regression cases. Fresh export comparison passes 409 screen and
175 console/ring assertions. DeepSeek's completed source review has no
unresolved verified finding. The [current archive manifest](reviews/pcb-finish-all-three-1072/manufacturing-zips.json)
supersedes earlier Revision L artwork and exports. This is bare-board CAD
and manufacturing-file acceptance; assembled operation, whole-PR review and
CI remain separate gates. Earlier Revision K evidence below is historical
and does not qualify the changed circuit.

September 25 screen-power correction: **Revision I screen Gerbers are withdrawn**.
The [independent Claude review and assessment](reviews/screen-power-claude-1072/assessment.md)
confirmed that relay commons 3/6 were floating: upstream data used normally
closed contacts 2/7, so neither USB touch path could conduct in either state.
Revision J corrects that pinout, retains normally open contacts 4/5, and adds an
independent contact-state regression guard. It also widens MOSFET necks to 1.9 mm
and the C2 feed to 1.5 mm, with three dedicated shared-power stitching vias.
Checks and replacement exports are recorded in the
[Revision J verification](reviews/screen-power-rev-j-1072/verification.md).
Revision K retained that correction and superseded J.
It introduced short 1.9 mm MOSFET approaches, a full 3 mm central bridge and gradual
transitions into the 4.5 mm distribution rail. Correct BOM-sized capacitor
models replace undersized previews, and C1 moves 1.5 mm to clear the mated
power plug. The system wiring diagram now routes both screens through this
board, specifies the main-power leads and accounts for the full AUX/PD budget.
The [Revision K verification](reviews/screen-power-rev-k-1072/verification.md)
records that historical package; the current revision status is above.
No additional owner measurements are prerequisites for bare-board fabrication.
Earlier screen-board readiness claims below are historical and superseded.

The [completed Claude cloud review](reviews/screen-power-rev-k-1072/claude-cloud-assessment.md)
found no verified K circuit/artwork defect and recommended first-prototype
fabrication. The [implemented follow-up](reviews/screen-power-claude-fixes-1072/verification.md)
specifies an exact external screen-branch fuse/holder, includes its voltage
drop in the conditional gate-drive calculation and replaces R8's approximate
assembly model. Circuit values and manufacturing artwork remain unchanged.
The fuse adds harness protection, not guaranteed MOSFET fault survival;
assembled operation still needs the documented qualification.
That historical package's OpenCode Go reviews were incomplete after provider
limits. The completed Revision L DeepSeek review is recorded separately in the
[current external review](reviews/screen-power-rev-l-1072/external-model-review.md).

Revision L retires the historical 6 A expansion allowance. Its screen planning
load is 4.25 A including both main outputs, both touch outputs and the bleeder;
the 3 A main and 500 mA touch branch ceilings are not additive guarantees.
The separate full-white ring, normal pills and console bring the AUX budget
to 7.608 A. Expected screen loads support upright Q3/Q4 without heatsinks under
the documented thermal estimates. Connector positions, the 68 × 76 mm outline,
purple mask and two copper layers remain unchanged. The
[screen-board notes](../hardware/kicad/screen_power/README.md) give the current
parts, wiring and post-assembly acceptance checks.

September 25 update: the owner requested unrestricted full-white operation for
one 40-pixel ring strip. The console and ring carrier now have dedicated wider
power paths, sized independently of firmware brightness. Board outlines,
placements, two layers, 1 oz copper and purple-console/white-ring colours remain.
That full-white change left the screen-power board unchanged. The
[full-white fabrication review](reviews/ring40-full-white-1072/verification.md)
supersedes the earlier 24-pixel/current-limited power assessment and order ZIPs.
It preserves first-assembly validation and the separate 10 A whole-system limit.

Publication is split by hardware generation. This branch includes the screen
power PCB, console connectors and power-domain corrections, white XIAO ring carrier (module footprints or external strip), and GPIO17 lifecycle service. The current old-console
ten-pill/40-LED-strip firmware is tracked separately under #1076 and #1077.
New-v3 console/ring firmware and PD diagnostics are published separately in
PR #1082 at `92af127d`; they remain an integration draft and are not code
included in this hardware publication. See the [publication record](reviews/hardware-publication-1072/verification.md).

The populated screen-power board has a proposed position behind CLEAR, left of
the buck pair, on 15 mm standoffs. Four floor mounts still need to be integrated
and actual harness/assembly fit checked; the CAD placement is not a physical
fit test. See the [placement study](reviews/pcb-completion-1072/screen-power-placement.md).

The historical September 24 order package included all three designs: console,
screen power and ring; its Revision I screen Gerbers are now withdrawn. The ring
carrier now uses white solder mask and black
silkscreen, with larger J1 and module-support holes. Its routes and placement
are retained; refilled-zone DRC has zero violations or unconnected items, and
all 63 connected pads match the circuit. See the
[ring order verification](reviews/ring-order-ready-1072/verification.md).

The console and ring boards for #1062 / PR #1066 now carry the wider power
rails in their routed files and manufacturing exports. Both pass full-severity
KiCad checks with zero violations and zero unconnected items, and exact circuit
netlist parity. See the [routing verification](reviews/routing-1062-2026-09-21/verification.md).
The PR remains open and hardware validation is still required. Screen power
switching has completed prototype CAD under [issue #1072](https://github.com/tomassasovsky/segno/issues/1072).
Revision E retains **hand-soldered assembly only** and removes the factory
variant. The new 64 × 76 mm board uses 19.6% less area than revision D's
72 × 84 mm hand board, with the same 37 populated through-hole parts and
four M3 mounting holes. All populated parts have portable STEP models.
Revision F added 3 mm rounded corners and a complete component cost estimate.
Revision G implements the requested two-layer board with purple solder mask.
Its 68 × 76 mm outline gives the power rail space beyond the USB connectors;
the two right-hand mounting holes move 4 mm with that edge.
Revision H aligns all eight keyed connector housings and vertical pin rows,
rotating the four two-pin headers and rerouting their connections.

Four-pin JST XH data connectors retain the selected direct USB-A / USB-C /
Micro-USB leads and pin map: 1 = VBUS, 2 = D−, 3 = D+, 4 = GND. Separate
screen-power leads retain two-pin JST VH connectors. The 28 AWG data leads
are not specified for the screens' full power loads; suitable main-power
leads and their final termination remain to be selected.

The control section is more compact, power enters at the upper-right edge,
and the two USB paths stay straight. Main power uses a wide
front-side rail at the right edge; USB stays on bottom copper without data
vias, with filled front-side ground underneath. Both outer faces have ground
pours; the board has no inner copper layers. The existing Pi-to-console ribbon remains direct; console
J25 carries GPIO17 and GND to screen J2. Console PD connector J23 now aligns
with RING J6 and screen-control J25 on one row. Its 0.8 mm move updates the
local PD/ground connections and clears two adjacent switch traces. PI PWR J9
now sits beside the ribbon on that same row, with PWR BTN J8 kept in place.
R2 turns horizontally below the buffer and R18 shifts 0.15 mm to clear the
existing PI PWR label. The floating button pair and affected signal routes
are complete; KiCad reports zero violations and zero unconnected items.
The underside screen pinout text is replaced by a top-side `SCREEN` label.
At that earlier placement review, ring routing was unchanged and the LED budget
was 1.44 A plus controller; the full-white review above supersedes that budget.
Its 3 A JST XH rating still requires 22 AWG power and ground leads.
See the [console placement verification](reviews/console-pi-power-placement-1072/verification.md)
and the [interface pinout](reviews/console-screen-connector-1072/verification.md).

Live USB inspection identified APROTII touch at 12 Mbps and UPERFECT touch
at 12 Mbps behind a 480 Mbps hub. Both connect directly to the Pi, so the
UPERFECT path still needs 480 Mbps qualification through the IM02TS relay
and selected cables. The relay footprint and default-off intent are retained;
Revision J corrects the contact wiring described above. The
4.5 V IM02TS relay now improves pickup margin on the 5 V host supply.

See [revision H verification](reviews/screen-power-rev-h-1072/verification.md)
and the [connector map and assembly notes](../hardware/kicad/screen_power/README.md).
Revision I superseded those exports, but is itself withdrawn following the
September 25 relay finding. The historical September 24
[first-fabrication review](reviews/pcb-completion-1072/first-fabrication.md)
removed the blanket pre-order measurement requirement; that decision remains,
subject to completing the Revision J correction and checks. Assembled hardware
remains unverified. The pre-order
audit corrected finished-hole allowances, added metal-fastener copper
clearance on the screen board, and moved console CTRL analogue pull-ups to
the Pico supply so Pi power cannot feed its unpowered ADC inputs. See the
[completion and pre-order status](reviews/pcb-completion-1072/verification.md) for final checks and
remaining physical and firmware acceptance items.

The board remains an unassembled prototype. Cable mating, polarity, shielding,
USB-C source configuration, USB operation/suspend, hot relay restart, inrush,
fuse coordination, voltage drop, temperature, impedance and enclosure fit
need physical checks. The owner confirmed on 2026-09-22 that both screens go
fully dark with power/touch USB disconnected and HDMI retained, following the
Pi-on test. The HDMI-only visual check therefore passes; GPIO cutoff and
discharge timing remain unverified. The included GPIO17 lifecycle service
passes its host tests; the five-second wait remains provisional. Local new-v3
firmware/PD work described in the historical completion report is outside
this publication. Issue #1072 remains `autonomy:blocked-verify` for assembled
validation and merge.

## Solid second-row enclosure platforms - 2026-09-15 (#1037)

Integrated the existing solid CLEAR/BANK collar revision into the active
manufacturing generator and print STEP/STL/archive. Both Fusion models are
saved and reopened at sheet metal 160 / populated 388. The four driver bores,
short-screw mounting patterns and all external interfaces are verified; other
native geometry and all 42 / 434 positions are preserved. Metal outputs did
not change. All 134 enclosure tests pass, plus the seven focused mounting
tests after strengthening the solid-material check. The #1019 physical load
hold remains. See [evidence](../hardware/enclosure/reference/solid_mid_platform_verification.json).

## Enclosure corner preparation - 2026-09-15

Prepared the welder's example on the existing #1025 branch while Dinacut's
confirmation is pending. Four angular reliefs now provide a nominal 0.50 mm
gap and 1.00 mm overlap. The rear upper return and all control/support mounting
geometry remain intact. The weld scope includes all four corners, lower relief
openings and the two upper rear joints, with the separately agreed 5356 filler
and smooth exterior finish. No files were sent and no fabrication was authorized.

Generator, native Fusion models (sheet metal 159 / populated 387), STEP, DXF and
individual drawings are synchronized. Both saved models were reopened; all
42 / 434 placements and unrelated body geometry/health are preserved. The full
generator and 133 tests across 15 modules pass. Cross-kernel mass integration was
qualified independently before changing its numerical consistency limit to
50 ppm; dimensional, forming, source-hash and full-flat gates remain unchanged.

The separate #1019 structural/load hold remains. Dinacut still needs to confirm
the relief/tooling assumptions; post-weld fit and front drilling are completed
before paint. See [current evidence](../hardware/enclosure/reference/welder_corner_preparation_verification.json)
and [release review](../hardware/enclosure/RELEASE_REVIEW.md).

## September 14 enclosure revision - historical digital evidence

The owner authorized #1025's welded rear-corner direction and manufacturing
tolerance revision from `43c94a27` on
`claude/sheet-metal-enclosure-analysis-6c2aa4`. This supersedes the older riveted
process below. It is implementation approval, not fabrication release; **#1019
remains an independent structural/load hold**, including the changed corner
restraint and welding effects.

The new metal handoff has five parts, one each: base, faceplate and ring disc
in 2.0 mm 1100-H14 aluminium, a **1.2 mm aluminium rear panel**, and a 1.6 mm
cold-rolled steel beam. Rear-panel alloy/temper and steel grade remain to be
confirmed. One metal archive carries exactly 15 STEP/DXF/individual-PDF
files with material, thickness and quantity in their names; no assembly,
hardware, printed parts, drafts, removed brackets or posts.

Dinacut cuts/folds/deburrs; a separate welder joins both rear corners. The two
brackets and ten base rivet holes are removed. The nine front lid/body stations
are laser-piloted and drilled out by Dinacut **after folding and before
welding** (#1090). No electronics trial or second manufacture is requested. A separate
painter coats all faces and clearance passages smooth matte black RAL 9005,
0.06–0.10 mm locally per face, protecting identified electrical-bond contacts.
The owner then cleans Ø2.5 pilots and taps **32 M3 threads** (18 lid, 14 screen
supports), and fits shims/felt. No new holes or enlarged screw passages are
planned after paint.

The current fit candidate is rear **10 mm depth ×6 mm wide CUT slots / OD12
washers**, front **Ø4.5 / OD7**, and **1.1 mm nominal bare front clearance**
with **0.70–1.50 mm acceptance inclusive of forming/fixture errors**. Coating
alone projects **0.357–1.488 mm** painted clearance. The slot passage calculation
does not qualify washer seating, wedge contact or the welded assembly;
final fit, washer selection and shim bearing remain pending.

Fusion was saved and reopened as **VAMP sheet metal 158 / populated 386**.
All changed features are healthy; all 42 / 434 final occurrence placements
survive reopening. Both bases have the ten rivet holes removed and both bracket
pairs are gone; each base measures **945.325929644 cm³**. The revised lids,
discs, washers and nominal shims are present in both models. Reopened native
solids match the verified exports; the populated lid flat comparison is exact
and each base differs by less than 0.000619 mm². All **126 tests across 14
modules** and the full generator pass. Five individual metal PDFs were visually
reviewed; the exact 15-file metal archive was verified after removing only
proven timestamp noise. The historical riveted guide was corrected.
All five independent implementation reviews are complete with no unresolved
findings; see the [consolidated review](reviews/dinacut-welded-revision/review.md).
Physical fit and strength qualification still block fabrication; no supplier message
or cutting authorization was sent. See the
[current plan](plan/2026-09-14-fix-dinacut-manufacturing-tolerances-plan.md),
[release review](../hardware/enclosure/RELEASE_REVIEW.md) and
[internal supplier drafts](../hardware/enclosure/SHOP_REVIEW.md).

## Enclosure release corrections — local, 2026-09-05

The following dated evidence records earlier revisions. Its riveted-corner
process, fit dimensions, quantities and saved versions are historical; the
September 14 status above governs the current revision.

Prepared from `fix/drawing-legibility-1001` at `1d14d701` on
`codex/sheetmetal-release-fixes`. Earlier converter, monitor support, post,
rear-panel gauge and corner corrections remain in place. The owner confirmed
no shop work has started, separate metal/painting suppliers, short text messages,
and **smooth matte black RAL 9005**, with no texture.

A full review corrected intersecting corner cutting paths, USB corner geometry,
an encoder bushing-root clash, coating-sensitive drilling/bore requirements,
hardware quantities and unsafe partial/failed archive publication. A repeat
review then found and corrected the installed Ring24 pin-strip stack's clash
with its printed holder, the disc's finished outer-diameter allowance, lid
centering before drilling, stale bend/post-gap notes and acceptance of retraced
laser slits hidden by CAD healing.

Fusion is saved and reopened as **sheet metal 131 / populated 344**. The repeat
pass changed only the existing ring holder with two cuts and eight support ribs;
all 414 other populated occurrences and all 18 sheet-metal occurrences retain
identity, geometry, placement, visibility and appearance. There are no empty
leaf components. The selected Ø80 board/pin strip and visible encoder positions
remain fixed. Its 73-body interface and bottom-up insertion clear the new
one-piece holder; nominal PCB axial clearance is 0.1346 mm and still needs the
actual print-fit check. Align the holder to the board before gluing.

The complete generator and **26 regressions pass**. All six metal laser profiles
pass topology checks; native base/bracket flats have zero missing/extra area,
and lid difference remains 0.008358 mm² each way within the 0.01 mm² gate. The
expanded printed-part sweep completes 1,056 candidate pairs without Boolean
failures; residual physical contacts are measured 0.000139–0.007803 mm
seat/compliant-rubber fits. The five changed PDFs / ten pages were rendered and
inspected. Final archive hashes and independent repeat-review results are in
[the repeat-pass evidence](reviews/sheetmetal-release-fixes/round2-verification.json).
The selected Ø80 ring-board revision must not be confused with this checkout's
Ø68 Gerber package.

**Seam corrections completed locally; Fusion saved and reopened at132/345.** The base side profile now follows the
lid ridge at 0.30 mm nominal clearance; fit to 0.30–0.40 mm before coating. Two
handed rear brackets back the upper straight seam with approximately 0.22–0.30 mm
vertical relief, fitted to 0.20–0.40 mm. Nine purchased stainless shim packs
support the front M3 stations; their actual thickness is fitted before painting
between hidden bearing lands, subsequently masked (September 6 sequence correction). Nominal 0.50 mm CAD packs are reference only.
The selected electronics, ring stack and all visible controls remain in place.

The seven fabricated stems make eight pieces, plus nine purchased reference
solids in the assembly. All 28 manufacturing regressions pass and six final
archives contain 90 matching members. Base and both handed bracket flats match
source exactly in both Fusion documents; unchanged lid parity remains within
0.01 mm². See [current seam evidence](reviews/sheetmetal-release-fixes/seam-fix-verification.json)
and [the correction review](reviews/sheetmetal-release-fixes/seam-review.md).
Earlier 131/344 and 26-test records above are historical.

**September 6 sled/screen corrections completed locally.** Populated Fusion
is saved and reopened at **346**; the separate mini console is synchronized to
the current source and saved/reopened at **13**. Each mini sled has two underside
retention fixings at 60 mm pitch, with matching tray access. Both sleds now
appear in the assembly STEP. A toe relief and revised rear lid bosses/locating
tabs remove the closed-lid and LED-insert clashes found during integration.
All 27 native mini interface checks are clear. The seven-inch module and four
mounting bosses move 0.50 mm toward the front along the faceplate; its six floor
anchors and aperture stay fixed. All 50 screen-area native checks succeed,
with only the unchanged tab-seat contact. **33 manufacturing regressions pass.**
Printed mini/tower/jig files are current; the console print ZIP carries the new
tower. Metal DXFs, PDFs and the five other supplier ZIPs are byte-identical to
the preceding reviewed package. No new PDF was authored. See
[the sled/screen evidence](reviews/sheetmetal-release-fixes/sled-screen-verification.json).

**Not released for fabrication.** Shop stock/tooling, rivet choice and final
pre-coating fitting and the coated fit coupon must be accepted; purchased-part fit, insert/screw lengths,
knob relief and coating sample still require physical checks. First-piece dry
and finished assembly and load/retention qualification remain necessary. See
[the release review](../hardware/enclosure/RELEASE_REVIEW.md),
[verification](reviews/sheetmetal-release-fixes/full-review-verification.json)
and [short supplier drafts](../hardware/enclosure/SHOP_REVIEW.md).
No package or supplier message was sent; no commit, push or remote issue/PR state
was changed by this review.

The subsequent rear-joint correction removes the remaining 0.610842 mm straight
seam opening: both rear/side joints now measure 0.050001 mm in both native
models. Source, actual native flat, formed STEP and shop packages were regenerated.
The owner retained rivets and a visible fine joint, with 0.00–0.10 mm dry fit
before riveting/coating. All 34 enclosure regressions pass; independent geometry
and preservation checks found no new interference or unrelated movement.
Final saves **sheet metal135 / populated348** reopened with unchanged geometry.
The source base was rebuilt from its DXF to repair an unreadable derived flat;
all five source flat products now load. See
[the rear-joint verification](reviews/sheetmetal-release-fixes/rear-closure-review.md).


**September 6 coating-scope correction — local checks complete.** The owner
retired the full-face overlay; labels remain on individual pedal tiles. Extra
machining PDF pages are removed in favor of text instructions. All metalwork
remains before the separate painting shop. All enclosure surfaces and clearance
bores are coated smooth matte black RAL 9005, without texture; only threads and
identified ground contacts are protected. Source/native clearances, printed
supports, screen setback and lid washers account for the stated coating range.
All 40 enclosure tests pass, the full generator reports ALL PASS, and the five
archives contain 88 verified members. Eight changed PDFs (11 pages) were
rendered and visually reviewed. Earlier masked-seat/prepaint evidence is
superseded for this coating process. Final native save versions are recorded
in [the current verification](reviews/sheetmetal-release-fixes/full-coat-verification.json).
The standalone mini geometry remains unchanged. Nothing has been sent to either
supplier. Physical shop/tooling, coated-coupon and assembled retention checks
remain open; local CAD checks do not grant production release.

**September 7 owner finishing decision.** The owner will install the ten corner
rivets before painting, retaining the existing Ø3.3 rivet holes, and manually
tap the eighteen M3 body holes after painting. The shop delivers matched parts
with Ø2.5 body pilots untapped and Ø4.5 lid clearances finished. Paint-narrowed
body pilots are cleaned back to Ø2.5 before tapping; no other post-paint hole
changes are planned. This supersedes the earlier all-machining-before-paint
sequence and protection of already-cut body threads. Ground contacts remain
protected. Only process notes change; native geometry and poses are unchanged.
The base drawing and painting notes were refreshed, all five pages visually
checked, and changed archive members verified. The proposed straight Ø8.5 disc
hole clears the modeled encoder root with paint allowance, but is not applied:
actual retaining nut/washer coverage must be checked before removing the chamfer.

**September 7 straight encoder-disc hole completed.** Owner measurements are
washer ID7.25/OD11.85. The disc now has a laser-cut straight Ø8.50±0.05 bore,
without chamfer; the outer diameter, thickness and all placements stay fixed.
Finished bore8.25–8.43 clears the modeled root when centered; conservative
opposing clearances leave0.87 mm minimum washer coverage. Both native documents
were saved/reopened (sheet-metal138/populated351), with no unrelated changes
or new warnings. All40 enclosure tests pass; five changed output files and
matching archive members were updated; two PDFs/five pages were visually checked.
See [the current disc verification](reviews/sheetmetal-release-fixes/straight-disc-verification.json).
No supplier message or package was sent. Physical fit/retention acceptance remains.

**September 8 thread-count and structural-comment correction.** The current
source and the supplied base DXF contain 32 M3 tap pilots: 18 lid fixings plus
14 screen-support anchors (six for the 7-inch tower and four per 15.6-inch
stand). The earlier September 7 process note counted only the lid fixings.
The owner cleans any paint-narrowed Ø2.5 pilots and manually taps all 32 after
painting; the shop delivers them untapped. The 18 lid clearance holes and
18 head washers retain their existing quantities. Current process prose and
the generated base note now distinguish those counts. Unsupported fixed
1050 strength, fold-stiffness and dent-load claims were removed from source
comments: actual temper, assembled support conditions and physical loading
remain to be qualified. These prose corrections do not establish structural
capacity or change the joint hardware. Historical verification records remain
unchanged.

**September 8 floor support update completed locally.** Four original rubber
feet are retained and eleven are added: four front, four rear and three
staggered near CLEAR/BANK and the steel posts. Both native bases were rebuilt
from the generated flat and saved/reopened as sheet-metal139/populated352.
The populated group has15 real feet; no unrelated components moved and no
warnings were added. All45 enclosure regressions pass, both final flats agree
with source contours, and the current sheet-metal-only archive has14 verified
STEP/DXF members. Base drawing inspected; older supplier packs are not the
current handoff. [Evidence](reviews/extra-feet/verification.json).

The owner's sustained scale reading was15–20kg and displayed maximum35kg; body
mass70kg. The provisional200N/700N static cases are not impact ratings. A
published-temper comparison and bare-sheet-strip sensitivity screen leave
assembled bending unresolved. Actual foot contact and printed-support load
spreading must be assessed before physical load qualification or cutting
release. [Temper analysis](reviews/extra-feet/temper-screening.json).

**September 9 console collar print correction completed locally.** Front/rear
light-baffle walls grow from 0.85 to 2.4 mm, increasing collar depth to 118.47 mm.
The bore, sleds, insert pockets, screw axes and pedal heights are unchanged.
Both native documents are saved/reopened at sheet-metal 140/populated 353 and
their collar solids match source exactly by bidirectional volume comparison.
The sheet-metal document's older collar references also receive the current
source geometry and mirrored populated-model placement. All 442 unrelated
populated occurrences and 35 unrelated sheet-metal occurrences are unchanged.
All 49 enclosure tests pass, including four new collar regressions. The two
collars' STEP/STL files and 36-member printing archive are current; all other
output files, including the metal-shop archive and sled files, are byte-identical.
[Evidence](reviews/collar-thickness/verification.json). First-print insert fit
and assembled structural qualification remain physical checks.

September 9 cable-opening follow-up completed locally: both console collars
now have an 8.6 mm centred open-top exit, with its bottom 6.95 mm above the
bare pedal underside. This clears the measured 7.6 ×11.45 mm feature with
0.5 mm side clearance and covers the 1.05 mm vertical measurement discrepancy.
All 50 enclosure tests pass. Native sheet-metal 141/populated 355 were saved,
reopened and matched to source; other geometry and placements remain fixed.
The user's three visibility changes during inspection are preserved. Updated
collar STEP/STL pairs and the printing archive agree; other outputs, including
the metal-shop archive, are unchanged. [Evidence](reviews/cable-opening/verification.json).

Closed stadium update, September 9: the console cable opening is now
8.6 ×13.5 mm with R4.3 ends and 4.9 mm straight sides, closed at the top.
Thread the cable before seating the pedal/sled. This supersedes the prior
open-top version. The 0.5 mm fitting allowance assumes the reported cable
feature has a stadium profile. Both models are saved/reopened at sheet-metal
143/populated 358, with exact native/source parity and 50 passing tests.
Other geometry/placements and the user's visibility choices are preserved.
The two print pairs and printing archive are updated; the metal-shop archive
and all other outputs are unchanged. [Evidence](reviews/cable-hole/verification.json).

Short-screw CLEAR/BANK mounting, September 9: the two tall collars now anchor
independently to the bottom base with M3×6 screws and M3 Ø5 ×5 inserts. Their
new dedicated sleds attach through the 8 mm deck with four M3×12 screws per
module. Front sled/collar, all metal geometry, mini-console and cable stadium
are preserved. Bench-assemble and remove the complete module for service.
Both native documents are saved/reopened at sheet-metal v144 and populated
v360; native/source differences are zero, with 448 other populated and 43 other
sheet-metal occurrences unchanged. The first-print ZIP now contains four STLs
(one collar and matching sled for each row). All 56 enclosure tests pass.
Physical insert fit and loaded PETG
performance remain unqualified. [Evidence](reviews/mid-platform-mount/final-verification.json).

September 9 material certificate received: Dinacut corrected the offered stock
from 1050 to 1100-H14. The Alcast certificate covers 2.00 mm lot 26E0269, with
127 MPa reported yield against a 95 MPa specified minimum. Use the minimum as
a material reference with separate design margins; the lot result is not a
universal allowance. Job-stock traceability and the 1.2 mm rear-panel material
remain unconfirmed. The previous strip screen still does not qualify assembled
stomp strength. Generator/drawing material callouts await controlled reissue;
no output/CAD geometry changed for this evidence review.
[Certificate assessment](reviews/material-certificate/review.md).

## September 2026 Mac recording companion

The standalone [Segno Transfer app](../apps/segno_transfer/README.md) implements
the owner-requested Mac workflow in #1056: connect using existing SSH access,
browse and select performance audio, name downloaded copies, verify transfers,
and stream recording previews with seeking. Its Swift package is independent
of the instrument runtime. The helper uses the appliance's minimal Python with
jq and sha256sum; Python json/hashlib modules are not required.

The streaming update uses bounded SSH range reads through the native player,
replacing full-file preview preparation. Local acceptance includes a real two-file download, custom filenames, matching
source hashes, and Finder reveal. Automated checks cover the transfer failure
paths, selection state and playback. Source review and product approval remain
separate from this local app delivery; #1056 retains its merge gate.

The owner approved free GitHub distribution with local signing and no paid
Apple signing or notarization. Companion tags use `transfer-vVERSION`; their
workflow tests and builds the Apple Silicon disk image, includes installation
instructions and the license, and publishes a checksum alongside the download.
Release review also corrected preview shutdown: quitting waits for cancelled
reads to finish their connection and temporary-file cleanup, including previews
closed or replaced just before quitting. Closing previews remains responsive.

## September 2026 appliance integration

The console link, CTRL jacks, and appliance delivery stack (#984, #986, #990)
integrates with the newer master changes. See
[the integration record](APPLIANCE_INTEGRATION.md) for release 137's verified
source commit, retained v2 behavior, pending v3 firmware, and the separate
software and device validation boundaries. Merging source does not publish or
install an appliance update.

The update helper now requests tryboot explicitly when an update is staged
(#977); an ordinary restart keeps the active slot. Isolated shell tests cover
both paths. This source correction does not validate a new installed image or
resolve the separate crash-loop health-gate issue (#976).

## September 2026 click timing

With Sync tempo off, later recordings now take their click timing from the
existing loop (#1051), including loop-top downbeats for loops shorter than one
beat. Native regression and sanitizer checks pass. The appliance listening
check remains pending; this source change does not install an update.

## Startup readiness and bundle inspection (#980 / #982)

The startup mitigations from #982 for #970 (the launcher's wait for a stable
Wayland socket and the 750 ms delay before the second window opened) were
removed with the GTK runner (#1330): ivi-homescreen opens both screens itself,
with no compositor to wait for. Restarts still pause for three seconds
(`segno.service`).

The bundle build inspects the actual RAUC artifact for the selected board and
version, its rootfs and boot archive, and the firmware install hook. The boot
archive producer and installer from #990 stay authoritative. See the
[integration record](APPLIANCE_INTEGRATION.md#startup-readiness-and-release-inspection)
for checks and the remaining device boundary.

Builds 138 and 139 compiled successfully but failed collection: the release
host lacked an archive extractor, then its RAUC version could not read verity
bundles. Inspection now runs before bundle deployment using the pinned
Yocto-native RAUC with JSON support, archive tools and jq. The checker matches
the existing boot archive filename ending in `.tar.img`; the producer and
install hook remain unchanged. A failed inspection stops the release build.


## September 2026 pill housing and simulator (#1074)

`hardware/pill_light_mask/` contains the eight-LED visual simulator, the flush
bench/panel lens and solid carrier, and the current angled friction-fit cradle
housing. Fit revision 2 adds 0.30 mm across the housing ribs and narrows the
platform throat by 0.30 mm after the measured loose fit. The current sample
parts and full STEP/STL exports are checked against pinned front/mid cradles.
The deeper grip, supported diffuser and open wire slots retain the accepted
12 mm strip and 12.5-degree face angle. Earlier snap variants remain historical
local artifacts and are excluded from this release. Physical fit, wear, pedal
travel and diffuser bridge anchoring still require validation; #1074 stays
`autonomy:blocked-verify`. The simulator is illustrative, with no device link.

## How to build / test (environment gotchas — read first)

- **Dart/Flutter tests:** the very_good_cli MCP `test` tool is broken in this
  env (exit 69, machine-output parser vs Flutter 3.44). Use the working SDK:
  `/Users/Tomas/development/flutter/bin/flutter test`. Codex does not install
  the former Claude hook that blocked bare CLI test commands.
- **Scaffolding:** prefer the Very Good CLI templates for normal packages.
  The Very Good MCP `create` tool only makes federated method-channel plugins. The
  FFI plugin (`segno_engine`) is **hand-authored** (`ffiPlugin: true` + CMake +
  podspec). Native engine lives **inside** the plugin at
  `packages/segno_engine/src/` (Flutter symlinks plugins at build time, so
  out-of-package native paths dangle).
- **macOS FFI loading:** the podspec sets `MACH_O_TYPE => mh_dylib` and uses
  `Classes/` forwarder TUs that `#include` `../src`; `DynamicLibrary.process()`
  on Apple (SPM static-links into the Runner). Don't revert these.
- **Native engine tests** (deterministic, no device — the real safety net since
  the audio thread can't be runtime-tested here):
  ```sh
  bash packages/segno_engine/src/test/run_native_tests.sh
  ```
  Concurrent native configurations need separate `TMPDIR` directories: the
  script uses fixed executable names there, so sharing a directory can make
  builds overwrite another run's binaries.

  The script self-locates (no preceding `cd` needed) and builds/runs the
  engine core test suite and the MIDI test suite on every desktop OS
  (`gcc`/`gnu11` by default, overridable via `CC`), plus macOS-only plugin
  scan/slot native tests against the vendored VST3/CLAP SDKs. Each suite
  prints "ALL PASSED"; the script exits non-zero on any compile or test
  failure.

  CI runs the same script in **two more configurations**, both of which must
  stay green and both of which are worth running locally after touching the
  engine:
  ```sh
  EXTRA_CFLAGS="-fsanitize=address -g" bash packages/segno_engine/src/test/run_native_tests.sh
  EXTRA_CFLAGS="-DLE_CALLBACK_TELEMETRY=0" bash packages/segno_engine/src/test/run_native_tests.sh
  ```
  The second is the callback-telemetry gate (#722) — the escape hatch if the
  instrument ever perturbs the appliance, so it has to *pass*, not merely
  compile. Assertions that can only hold with the instrument compiled in are
  wrapped in `CHECK_TIMING` in `test_engine_core.c`; everything else is asserted
  in both builds.
- **Adding a header to `src/core/` — the C++ blast radius nothing on macOS
  catches.** Any new core header reaches **every C++ translation unit in the
  VST3 builds**, via `engine_private.h` → `engine_fx.h` →
  `vst3/test/host_harness.{h,cpp}` (which includes `engine_fx.h` *inside* an
  `extern "C" { }` block). So a header that is perfectly good C can still break
  the plugin builds on two of three platforms:
  - `engine_private.h` carries a **C++ atomics shim** (`#undef _Atomic` plus
    macro/`template` stand-ins for `atomic_load_explicit` and friends) because
    MSVC and GCC reject `_Atomic` in C++ and offer no keyword-compatible
    `<stdatomic.h>` there. It is guarded to `#if defined(__cplusplus) &&
    !defined(__clang__)` — **so macOS CI never compiles it at all**. A header
    that uses an atomic op the shim does not cover passes every macOS job and
    fails Windows *and* Linux. (This bit twice on #722: first a missing
    `atomic_exchange_explicit`, then a `template` that cannot be declared with C
    linkage — the shim's `extern "C++" { }` wrapper is what fixes the latter and
    is load-bearing, not decoration.)
  - **The only local repro on this Mac** (there is no non-Clang compiler here) —
    note the `-U__clang__`, the `extern "C"` wrapper, and `std::min` in scope;
    a plain top-level `#include` does **not** reproduce it:
    ```sh
    cd packages/segno_engine
    cat > /tmp/shim_repro.cpp <<'EOF'
    #include <algorithm>
    extern "C" {
    #include "engine_fx.h"
    }
    int main() { return (int)std::min(1, 2); }
    EOF
    clang++ -std=c++17 -U__clang__ -I src/core -I src/midi -I src/miniaudio \
      -c /tmp/shim_repro.cpp -o /tmp/shim_repro.o
    ```
  - A core header that pulls in **`<windows.h>`** must `#define NOMINMAX` first,
    guarded with `#ifndef`, because stock `<windows.h>` defines `min`/`max` as
    macros and turns any later `std::min(` into MSVC C2589 — which is exactly
    the `std::min` in the repro above. Define it **in the header that drags
    `<windows.h>` in**, not in the build files: a `-DNOMINMAX` would have to be
    repeated in CMake, the podspec, the SPM target and the native test runner,
    and would drift the first time one was missed. Do **not** reach for
    `WIN32_LEAN_AND_MEAN` instead — it applies to the whole TU, including
    miniaudio's own later `<windows.h>`, and miniaudio documents it as excluding
    symbols it then redefines by hand.
- **Regenerate FFI bindings** after touching `src/segno_engine_api.h`:
  ```sh
  cd packages/segno_engine
  dart run ffigen --config ffigen.yaml
  dart format lib/src/generated/segno_engine_bindings.dart
  ```
  The `dart format` step is required: ffigen emits legacy short-style code,
  but the committed bindings are canonical `dart format` (tall) style. Without
  it, every regen rewrites the whole file and buries the real diff. With it,
  regens are field-scoped regardless of your local SDK's formatter version.
- **FFI symbol parity — the skew a clean build will not catch.** Dart reaches
  the engine only through `dlsym`, which resolves at *first call*. A bundle
  whose bindings name an entry point its `libsegno_engine.so` does not export
  therefore compiles, packages, installs and launches — then throws
  `Failed to lookup symbol '...'` on the device, on whatever path reaches it
  first. That is not theoretical: the appliance threw 137 such exceptions on
  2026-08-25, across six app starts, off a *periodic* timer -- so it repeated
  for as long as each run lasted -- from a bundle whose halves came from
  different trees. Compare the two lists against a built library with:
  ```sh
  packages/segno_engine/tool/check_ffi_symbols.sh <path-to-libsegno_engine.so>
  ```
  CI's `appliance-bundle` job and the release build run it against the bundle
  they just built, and `build-arm64-bundle.sh` runs it before the bundle can be
  deployed or staged for Yocto, so ordinary work should never see it fail. It is worth running by
  hand after a regen if you are about to hand-stage a bundle. The check is
  itself tested (`bash packages/segno_engine/tool/test/run_check_ffi_symbols_tests.sh`),
  including that it **fails closed**: if ffigen's emitted call shape ever drifts
  out from under the extractor, it aborts rather than quietly checking a subset.
- **macOS app run/build:** flavor schemes required.
  `flutter build macos --debug --flavor development -t lib/main_development.dart`
  Run: `flutter run -d macos --flavor development -t lib/main_development.dart`
- **Appliance bundle:** `deploy/rpi/build/build-arm64-bundle.sh` builds what
  the console runs (`build/appliance/bundle`) in an arm64 container, on the
  Flutter release the image's engine is (`FLUTTER_ENGINE_VERSION` in
  `deploy/yocto/meta-segno/recipes-graphics/flutter-engine/flutter-engine-version.inc`).
  There is no `linux/` and no Linux desktop build: the app is built with
  `flutter assemble` and the engine with its own CMake project, and the
  console runs it on ivi-homescreen (#1330). macOS is the dev host.
- **Driving the Network page off the appliance:** Wi-Fi is a Linux-only
  helper (`segno-wifi-ctl`), so on macOS every path past "no WiFi on this
  build" is unreachable — including the ones with the most
  behaviour in them. Add `--dart-define=SEGNO_FAKE_RADIOS=true` to swap in
  an in-memory stack:
  ```sh
  flutter run -d macos --flavor development -t lib/main_development.dart \
    --dart-define=SEGNO_FAKE_RADIOS=true
  ```
  The define is read inside `createWifiClient` **before** its platform test,
  so every entry point picks it up with no app wiring change. The fake is
  opinionated rather than empty — it exists to reach the states the mockups
  draw, with deliberate delays so in-flight spinners and banners are visible.
  Failure is reachable on purpose: `segno123` is the only passphrase that
  joins. **Off by default**, so a shipped build can never
  present invented networks as real ones; the factory tests assert the flag
  from both sides, so the branch is covered by the ordinary CI run.
- **Appliance helper suites** (shell, no device): every
  `deploy/yocto/meta-segno/recipes-segno/segno-bundle/test/run_*_tests.sh`,
  as the `appliance-shell-tests` CI job runs them. Bluetooth was retired (#1199): the
  image ships no BlueZ, and the pairings an earlier image kept stay on
  `/data/bluetooth` for a fallback to the previous slot.

---

## Architecture (VGV layered monorepo)

```
packages/
  segno_engine/        DATA  — FFI plugin over a hand-written miniaudio engine (C)
  controller_repository/ REPO — hardware-agnostic MIDI → looper actions
  looper_repository/   REPO  — owns the engine; EngineSnapshot → LooperState
  settings_repository/ REPO  — persistent settings over KeyValueStore
  local_storage_client/ DATA — KeyValueStore (shared_preferences)
  session_repository/  REPO  — save/restore .segno session bundles (manifest + WAV stems)
  performance_repository/ REPO — performance-recording capture lifecycle (arm/finalize/recover)
  wav_codec/           DATA  — 32-bit-float WAV encode/decode (pure Dart, no Flutter dep)
  daw_export/          DATA  — pure-Dart Ableton Live 12 (.als) exporter for a performance capture
  midi_client/         DATA  — native USB-MIDI device client (ControllerSource) over the FFI seam
  midi_device_repository/ REPO — MIDI device enumeration/selection + hotplug (audio-independent)
  pedal_repository/    REPO  — console pedal-board link (footswitch/encoder in, LED frames out) over UART
  routing_graph/       UI KIT — reusable routing-graph canvas/wires/cards + theme (Signal, FX editor)
lib/
  app/        App + MultiRepositoryProvider (looper, controller, settings)
  looper/     LooperBloc + Chewie-2 track grid (home)
  audio_setup/ device/sr/buffer, engine start/stop, latency, loopback note
```

Strict layering: presentation → bloc → repository → data. The engine's typed
`AudioEngine` interface is the test seam (fakes everywhere).

### Native engine model (`packages/segno_engine/src/engine.c`)
- One **master loop clock** (`le_loop_clock`: length + position). First finalized
  track sets the length; all tracks index the same `position` → phase-locked.
- **Multi-lane tracks** (PR 1 of the multi-lane/dual-route rework). A `le_track`
  is a container that owns the **transport** (state / multiple / pending-arm),
  one **shared latency-compensated write head** (`record_pos`), and **one undo
  span** (`undo_stack`/`redo_stack`, the same slot index in every lane). Each
  `le_lane` (`lanes[LE_MAX_LANES]`, `LE_MAX_LANES == 8`) records
  **one** hardware input (`a_input_channel`, -1 = none) into its **own clean mono
  buffer** — sibling lanes are **never merged/averaged** — with per-lane output
  mask / volume / mute / effects. Recording is **track-addressed** and fans out
  to every active lane; playback **sums** all lanes; undo swaps every lane's
  `a_live` in lockstep. **Lazy lane allocation**: only lane 0 of each track is
  allocated at configure; `le_engine_set_lane_count` allocates added lanes on the
  control thread, and a **real-time null-guard** keeps the audio thread from
  dereferencing an unallocated lane buffer. Track-addressed setters (volume /
  mute / input / output / fx) map to **lane 0** for backward compatibility.
- Lane buffer pools + undo/redo stacks are owned by the **control thread** (sole
  writer of each lane's atomic `a_live`). The **audio thread only reads
  `lane.pool[a_live]`** — no allocation/locks/stack-access on the callback.
- **Effects are per-lane** (one **stageless**, non-destructive chain on each
  lane's own `fx` state — the pre/post `stage` and the per-lane `mon_fx` are
  gone): `le_engine_set_lane_fx(channel,lane,index,type)` / `…_fx_count` /
  `…_fx_param`. Track-addressed FX setters map to **lane 0** for back-compat.
- **Live monitoring is per hardware input**
  (`le_monitor_input monitors[LE_MAX_MONITORED_INPUTS]`, one slot per input,
  ≤ `LE_MAX_MONITORED_INPUTS`=8; a higher-numbered channel is still recordable,
  just not monitorable): each enabled input is summed live
  through **its own** stageless chain into its output mask, **never recorded**,
  independent of all track state — replacing the old global monitor-FX bus,
  monitor-follow-track, and monitor masks. `le_engine_set_monitor_input(input,
  enabled,output)` / `…_fx` / `…_fx_count` / `…_fx_param`. A loopback
  measurement clears all monitor enables (cable-feedback safety); `passthrough`
  enables input 0 at start.
- **Dry + wet monitoring (independent routing).** Each monitor input also has a
  **parallel dry send** (`a_dry_output_mask`, `LE_CMD_SET_MONITOR_INPUT_DRY=33`,
  `le_engine_set_monitor_input_dry(input,dry_mask)`): the CLEAN (pre-FX) sample
  is summed to its own outputs alongside the effected route, so an input can be
  heard clean on one set of outputs and effected on another at once (`0` = off,
  the default; never recorded). Threaded through `InputMonitor.dryOutputMask`,
  `LooperRepository.setMonitorDry` (remembered + reapplied on restart),
  `MonitorCubit.setDryOutputMask`, and the `monitor_input_dry.$input` key.
- **Monitor routing graph** (`monitor_graph_view.dart`, replacing the per-input
  chip tiles that didn't scale on big interfaces): inputs left, each *monitored*
  input a node + its effect chain in the middle, outputs right, on a zoom/pan
  canvas. Two colour-coded sends per input — **wet** (blue, through the chain)
  and **dry** (amber, dashed). Tap an input to monitor + focus it; an Effected/
  Dry toggle picks which send an output tap wires. Only monitored inputs show as
  nodes; unused ports dim. `monitor_fx_editor.dart` (the old chip editor) is
  removed.
- **Dart domain layer (PR 4) is landed.** `looper_repository` exposes per-lane
  setters (`setLane{Input,Output,Volume,Mute,Count}`, `setLaneEffects`/`…Param`)
  with **lane-0 convenience wrappers** (`setVolume`/`setMute`/`setInputMask`/
  `setOutputMask`/`setTrackEffects` map to lane 0; a selection mask collapses to
  its lowest input via `maskToInputChannel`) and **per-input monitor** methods
  (`setMonitorInput`, `setMonitorEffects`/`…Param`). New domain models `Lane`,
  `InputMonitor`, and `Track.lanes`; `_project()` fills lanes from the snapshot.
  `MonitorCubit` is now a **per-input** list (`Map<int, InputMonitor>`) —
  `MonitorMode`/follow-track and the global monitor-FX bus are gone. Persistence
  moved to `lane_*` / `monitor_input*` keys (old `track_*mask`/`track_effects`/
  `monitor.*` keys dropped, drop-and-default — no migration). Session export
  stays **lane-0 only** (documented follow-up).
- **Multi-lane routing UI (PR 5) is landed.** *(Superseded by the unified Signal
  surface below — `lane_graph_view.dart` and the per-track routing page were
  removed; the lane-addressed `LooperBloc` events described here remain in use.)*
  The per-track routing page is one
  **unified wiring graph** (`lane_graph_view.dart`): hardware inputs on the left,
  the track's lanes stacked in the middle (each a node + its own effect chain),
  hardware outputs on the right, with bezier edges showing every lane's wiring on
  a zoom/pan canvas. Tap a lane node to *focus* it, then tap input/output nodes to
  (re)wire that lane; effects drag-to-reorder and tap-to-edit in a docked panel
  that also holds the focused lane's mix and add/remove-lane (lanes are a stack —
  only the last is removable, capped at `kMaxLanes`). New **lane-addressed**
  `LooperBloc` events (`LooperLane{Count,Input,Output,Volume,Mute,Effects,
  EffectParam}Changed`) replace the lane-0-only mask/track-effect events; each
  forwards to the matching `setLane*` repo method and persists the per-lane
  `lane_*` key. The per-input live-monitor section (audio settings) and the
  stageless chain were already in place from PR 4.
- RT contract: no malloc/lock/syscall/unbounded-loop in `le_engine_process`.
  Commands arrive via an SPSC ring; state published via per-field atomics.
- `le_engine_process` / `le_engine_configure` are exposed for **device-free
  deterministic tests** (`src/test/test_engine_core.c`); per-lane state is read
  with `le_engine_get_lane` (legacy per-track view mirrors lane 0).

---

## Done

Phases 1–3 of the plan plus several sync refinements. See `git log` for detail.

- **Accepted design, slice 3e (#1016, epic #1009):** the October
  reconstruction applies complete FX recipes at an audio boundary and persists
  only their confirmed application. Whole-track Pre combines original parts
  once while keeping the Mixer gain separate. Capture inheritance, Clear/Undo,
  restart, plugin ownership and channel refusal have independent sample and
  persistence checks. All relevant local Dart/native suites, coverage floors,
  static checks and source reviews pass; publication and current-head CI are
  separate gates. FX screens follow in 3f; complete offline rendering, exact
  DSP parity and in-flight cross-session storage ordering retain their later
  owners. See `docs/reviews/design-fx-placement-restack/README.md`.
- **Accepted design, slice 3b (#1016, epic #1009):** output destinations
  have level, mute, Stereo/Mono, retained balance and a post-sum effect chain.
  October reconstruction joins output setup to the shared atomic mix and durable
  rollback path. Performance recording freezes the actual destination and its
  effect chain at callback acknowledgment. Default capture excludes final level
  and mute; Follow applies their later changes. Both policies exclude hardware
  Mono/Balance/master gain/limiter. Cut stops current sources and clears old
  tails and the current click pulse, while preserving monitoring preferences.
  Failed arm publication retains ownership for Stop; malformed destination
  metadata is refused. Track-wide routing surfaces are slice 3c. Offline
  reconstruction still lacks full multi-lane, live-input/click and track-bus
  replay; these are later integration work, not proof of complete parity.
  Ledger: `docs/plan/2026-09-09-segno-implementation-ledger.md`.
- **Accepted design, slice 3a (#1016, epic #1009):** the mix model: per-lane
  pan with a unity-centre balance law, per-track Solo beside mute, a capture
  trim per input on the recorded branch only, monitoring for every hardware
  input, a recorded image fixed per lane from its input's setup (stereo
  pairs as two lanes with a shared balance), the Mixer's meters (post-fader
  stereo peaks per track, per-input, per-monitor and per-output peaks) and
  typed mix targets; persisted in settings and the session manifest. The
  October reconstruction adds one durable mix coordinator, exact rollback
  and stopped recovery, capture lifetime fencing and atomic recording/Undo
  admission. Verified scope and remaining integration boundaries are recorded
  in `docs/reviews/design-mix-model-restack/README.md`.
  Ledger: `docs/plan/2026-09-09-segno-implementation-ledger.md`.
- **Accepted design, slice 2c (#1012, epic #1009):** the Loop settings
  pages at the pen's size (hub, Loop mode cards with reasons and the stop
  dialog, Recording, Tempo & click with the signature grid, Length &
  quantize and Playback & overdub with the Tracks / Defaults / 1-8 selector
  and field-level inheritance, Audio & tempo as a readout), opened from the
  tray's Loop entry and the Settings rail; the tray's Loop tabs and Tracks
  Lengths tab, the desktop Tempo and Mode sections and per-track rows, the
  boolean quantize cubit and the sync switch are gone; the session manifest
  carries per-track length and Once overrides; the click output and level
  sit on the Audio tray's Device tab until the Mixer. Ledger:
  `docs/plan/2026-09-09-segno-implementation-ledger.md`.
- **Accepted design, slice 2b (#1012, epic #1009):** timing ownership: one
  record timing setting (Immediately, Loop start, bar to 1/16) by default and
  per track (a per-track division joins the per-track gate in the engine),
  overdub decay by default and per track with a ramped live change, Once in
  all five modes (a track's lap ends on the shared clock in Multi/Sync/Band),
  count-in and Sound start exclusive through native commands, repository and cubits,
  and the overrides in settings and the session manifest. Ledger:
  `docs/plan/2026-09-09-segno-implementation-ledger.md`.
- **Timing reconstruction (#1061):** explicit per-track inheritance survives
  empty-track/session recall, Immediate retains the remembered musical grid,
  and queue refusal leaves Count-in, Sound start and armed tracks unchanged.
  Native snapshots publish the applied start choice as one coherent state.
  Current validation and independent review are recorded in
  `docs/reviews/design-timing-restack/README.md`; hardware proof stays separate.
- **Accepted design, slice 2a (#1012, epic #1009):** mode changes with
  recorded audio follow the accepted contract (the engine measures the gate:
  compatible spans switch on a stopped rig, playing loops are stopped first,
  captures and queued arms refuse; nothing is cleared or resized); undo during
  an overdub removes the pass, undo during a take cancels it with an
  immediate-playback redo, a clear on a capturing track freezes the take
  restorable, and Clear All is one grouped edit. Ledger:
  `docs/plan/2026-09-09-segno-implementation-ledger.md`.
- **Accepted design, slice 1 (#1010, epic #1009):** the Tracks view is the
  accepted stage (four columns per bank with name/crown, number · bars ·
  layers · FX, one dB-linear whole-track meter with a clip cap, queued cue,
  bottom progress, shared dBFS scales, footer, Library/bank/view/Settings
  top bar, Wave view) and the 7" follows the selected track. The engine
  crowns the first completed take and clears the crown of an empty session;
  the snapshot
  carries a per-track playhead and the master-bus peak. The volume overlay,
  status bar and readiness strip are gone. Ledger:
  `docs/plan/2026-09-09-segno-implementation-ledger.md`.
- **Phase 1:** monorepo, miniaudio FFI plugin, duplex passthrough, round-trip
  latency harness, "hello duplex" smoke app.
- **Phase 2:** single-track looper (record → master length → overdub → mix →
  vol/mute → clear), `looper_repository` + `LooperBloc` + channel-strip view,
  `audio_setup`.
- **Phase 3 core:** N-track engine (LE_MAX_TRACKS=4) + grid UI;
  `controller_repository` (MIDI-learn-ready) wired into the bloc.
- **Loopback latency auto-detect** (PulseAudio monitor / WASAPI / virtual
  driver) + cable-free auto-measure (digital-path estimate; cable for true
  analog).
- **Latency compensation (record offset):** overdub/new-track input written at
  `pos − offset`; monitoring is **live** (not folded); offset auto-set by a
  measurement, overridable.
- **Persist latency:** per-device (device + sr + buffer) via
  `settings_repository` / `local_storage_client`.
- **Single-capturer recording** (chained hand-off): record on a new track
  finalizes the current one and starts the new from the loop top.
- **Multi-level undo/redo** per track (control-thread buffer pool; undo = overdub
  layers, clear = remove track).
- **Fully free mode** (no tempo): all BPM/metronome/click/count-in/tap-tempo,
  loop↔tempo sync (#2), and quantize-start (#3) logic was **removed** from the
  native engine, FFI, repository, bloc, and UI. The looper has **one master loop
  length**, set by the first finalized recording; there is no beat grid, no
  click, and no quantization — captures start and stop immediately. Per-track
  loop multiples (#4, below) are retained, as is latency compensation, the loop
  waveform visualizer, Big Picture / two-window mode, and theming.
- **Loop multiples** (#4): a non-defining track can span an integer multiple of
  the base loop. A free-running `loop_iteration` counts base-loop wraps; each
  track plays `((iteration − start_iter) % multiple)·baseLen + position`, so the
  master still wraps at the base length while a k-loop track cycles its k
  segments. New tracks record freely from the loop top across base loops and are
  **auto-rounded up** to whole base loops on stop (buffer zeroed on the control
  thread so a rounded-up tail is silent). Per-track `multiple` in the snapshot;
  `×N` chip in the UI.
- **Theming + Big Picture mode** (Phase 4 slice): Material 3 theming via a
  `LooperTheme` `ThemeExtension` (neon-on-black **Big Picture**). _(The
  dark-neutral Desktop theme, the desktop `LooperView`, and the `UiMode`
  toggle were later removed — Big Picture is the single UI mode.)_ Big Picture
  is a
  Chewie-Monsta-style row of tall colored track columns (per-track number,
  loop-waveform thumbnail, editable persisted name via `BigPictureCubit`,
  selection highlight, per-track accent / red recording) **plus a second OS
  window** (`desktop_multi_window`) showing the whole-loop output waveform with
  a white playhead bar. Fed by a new RT-safe native **loop-indexed viz tap**
  (`le_engine_read_visual` + `read_track_visual`: peak per loop bucket, master
  + per-track, refreshed as the playhead sweeps). `KeyValueStore` now stores
  string/bool/double. _(The second window and `desktop_multi_window` were
  later removed: the readout is the console's 7″ screen, a second engine
  under ivi-homescreen, #1330.)_
- **Auto-start audio + first-run flow:** the last-used audio config (sample
  rate / buffer / monitor) is persisted on a successful start
  (`SettingsRepository.save/loadAudioConfig`). On launch, `tryAutoStartEngine`
  loads it and starts the engine; if none is saved (first run) the **Audio Setup
  page is the start screen** until the engine connects, then it hands off to the
  looper.
- **Big Picture is the only look** (the `UiMode` toggle was removed).
  A dedicated, minimal **Big Picture settings page** (rename tracks, reach audio
  setup, toggle the waveform window) is reachable from the
  performance view by **right-click** or the **`S` key**, and from the **macOS
  system menu bar** (`PlatformMenuBar`, ⌘,). A persisted `WaveformWindowCubit`
  gates the secondary window. The chromeless big-picture exit button was removed
  (exit lives in settings now).
- **Record immediately, even mid-loop** — a new track over an existing master
  starts capturing at the current loop phase (no waiting for the loop top);
  `record_pos` seeds to the master position so writes stay phase-locked and the
  pre-press slice stays silent. Start-at-top is unchanged (multiples preserved).
- **Transport reset-to-zero** — the master clock no longer free-runs in silence:
  when no track is playing/recording/overdubbing it holds at position 0 (and
  resets each track's loop phase), so play after a full stop starts from the top.
  While any track is active the clock advances as before.
- **8 tracks as two banks of four** — `LE_MAX_TRACKS = 8` (FFI regenerated). A
  persisted **bank-enable** toggle (default off = one bank of four); when on, the
  eight tracks show as two banks of four (A / B), one bank visible at a time.
  `BankCubit` (app-wide) holds enabled + active bank; Big Picture shows an A|B
  switch.
- **Performance keyboard + Record/Mute modes** — handled in the Big Picture
  `Focus` (plain keys consumed so macOS does not beep). `M` switches mode (a
  REC/MUTE indicator shows it); `1`–`8` select a track (auto-revealing its bank);
  Record mode adds `R` record/overdub and `P` play/pause the selection; Mute mode
  makes `1`–`8` select + mute/unmute; both modes: `Space` play/pause all, `C`
  clear all, `⌘/Ctrl+Z` undo, `⌘/Ctrl+Y`/`Shift+Z` redo. `PerformanceMode` +
  `toggleMode` on `BigPictureCubit`; new `LooperClearAllPressed` event.
- **Code-review pass** — removed a debug `settings.clear()`; app composes the
  engine via `LooperRepository.withNativeEngine()` (no `segno_engine` import in
  `lib/`); deleted dead Big-Picture waveform polling and made the level meter a
  stateless widget (no per-tile timers); extracted a shared rename dialog;
  `AudioSetupPage` reads its repositories from context; added the missing test
  coverage. The Big Picture per-track thumbnail is a **level meter**, not a
  waveform.
- **Functional settings surfaced** — the settings/routing UI now exposes the
  engine's real knobs: **quantized recording** (snap start/stop to the loop
  grid, global + per-track override), **configurable input monitoring**
  (input/output channel masks, or follow-the-selected-track), **rec/dub**
  second-press mode, **sound-activated** recording, **loop multiples** (global
  default + per-track `×N`), and **max-loop cap** / **UI refresh rate**. Each
  is remembered in `LooperRepository` and re-applied on every (re)start, and
  persisted via `SettingsRepository`. "Default" chips/labels name the resolved
  global value. The per-track routing dialog reuses the signal-flow graph
  scoped to one track.
- **Effects chain** — *(engine reworked: the chain is now **per-lane** and
  **stageless** — one non-destructive chain per lane via
  `le_engine_set_lane_fx*`; the pre/post `stage` and the global monitor-FX bus
  are gone, replaced by per-input live monitors, see the multi-lane section
  above. The Dart `TrackEffect.stage` model + the card-strip UI below still
  describe the pre-rework PR #11 shape and are reworked in the Dart/UI PRs.)*
  Each chain carries up to
  `LE_FX_MAX = 8` effects (the cap is for a fixed, allocation-free audio-thread
  array, not a CPU limit), each with `LE_FX_PARAMS = 3` normalized params:
  **Drive** (tanh saturation), **Filter** (TPT state-variable low-pass),
  **Delay** (feedback + wet mix, lazily allocated 1 s ring per entry on the
  control thread), **Tremolo** (sine-LFO). All DSP is allocation-free in the
  callback; the pre chain runs on `insample` before the buffer write, the post
  chain on the playback sample before routing. Structural edits (type/stage)
  route through the command ring so the audio thread resets that entry's DSP in
  lockstep; a published `a_fx_count` gates active entries; params are plain
  atoms read once per buffer (a live tweak never resets DSP). Setters
  `le_engine_set_track_fx(index,type,stage)` / `set_track_fx_count` /
  `set_track_fx_param`. `TrackEffect {type, stage, params}` + `TrackEffectType`
  carry native codes, labels and musical defaults; the chain is JSON-encoded for
  persistence. Configured from each track's routing dialog as a **signal-flow
  card strip** — `In ▸ [pre cards] ▸ Track ▸ [post cards] ▸ Out`, add per lane,
  reorder within a lane, move across the track (flips the stage), tap a card to
  edit type + sliders. `LooperRepository` remembers the chain and re-applies on
  (re)start (structural vs. granular-param paths); persisted per channel.
  Designed plugin-ready — a hosted VST3/CLAP plugin is just another effect type.
  **VST3 SDK went MIT (VST 3.8, Oct 2025)**, clearing the licence/GPL block, and
  **the host has since shipped**: vendored VST3 + CLAP SDKs, plugin
  discovery/scan/catalog, slot lifecycle + sealed `TrackEffect` topology guard,
  dynamic parameter UI, native editor windows (NSWindow on macOS, HWND on
  Windows) with two-way param sync, and state persistence with missing-plugin
  resilience. A plugin browser ("+" → Add effect/Add plugin…) replaced the old
  debug seam. **macOS and Windows hosting are feature-complete; Linux (X11)
  hosting is the one remaining gap**, deferred to on-platform work.
- **Windows + Linux native — portable foundation (PR1).** Generated the Linux GTK
  app scaffold (`linux/`); `flutter build linux --debug -t lib/main_development.dart`
  compiles + bundles `libsegno_engine.so` (miniaudio dlopen()s the audio backend at
  runtime). Desktop flavors are **entrypoint-only** (`--target lib/main_<flavor>.dart`;
  `--flavor` only namespaces build output). CI now fires on PRs (trigger fixed
  **`main` → `master`**) and adds compile-only `windows-latest` / `ubuntu-latest`
  build jobs. Per-channel label exclusion is **unchanged** (`return 0` off macOS;
  ASIO/PipeWire are PR2/PR3). *Hardware-gated, not yet run on real interfaces:
  end-to-end record/loop/play/monitor/FX, the `desktop_multi_window` waveform window
  on GTK, device-name classification, and the latency harness.* _(`linux/` and
  the Linux desktop build were later deleted; the appliance bundle is built
  with `flutter assemble`, #1330.)_
- **Windows bring-up fixes (real-hardware run).** Two blockers found running the
  app on a real Windows interface, both fixed + verified (build + app launch +
  native tests green via MSVC):
  - **MSVC C11 atomics:** CMake's `C_STANDARD 11` only emits `/std:c11`, which is
    not enough for MSVC to accept `_Atomic` / `<stdatomic.h>` (the lock-free ring)
    — it needs `/experimental:c11atomics` too. Without it the whole Windows engine
    failed to compile. Added under `if(MSVC)` in `src/CMakeLists.txt` (+ quieted
    C4996 `strncpy` warnings via `_CRT_SECURE_NO_WARNINGS`).
  - **WASAPI device ids collapsed to `"{"`:** `device_id_to_str` read the WASAPI
    *wchar* id as a narrow `char*`, truncating every id to its first byte, so all
    devices shared one id → the device-picker `DropdownButton` crashed and pinning
    was broken. Fixed behind the platform seam (`le_platform_device_id_to_str`):
    Windows converts wchar→UTF-8, macOS/Linux keep the verbatim copy. Regression
    test `test_device_id_to_str`.
- **Windows per-channel labels — ASIO scaffolding (PR2).** `SEGNO_ENABLE_ASIO`
  CMake option. _(The Steinberg ASIO SDK was later **vendored** under
  `packages/segno_engine/third_party/asiosdk` and the repo relicensed to GPLv3,
  so ASIO now builds **on by default on Windows** — see docs/WINDOWS_ASIO.md.)_
  `win_asio_labels.cpp` probe reads `ASIOGetChannelInfo().name`
  and reuses the portable, unit-tested `le_excluded_mask_from_names` /
  `le_label_is_loopback`; dispatched from `engine_windows.c` under the flag,
  degrading to `0` on any failure/ambiguity. Docs: `docs/WINDOWS_ASIO.md`.
  *Still gated on the user's 30-min hardware spike* (does `ASIOChannelInfo.name`
  carry "Loopback" on the interface, and does the WASAPI↔ASIO device match hold?).
- **WASAPI exclusive mode — full device control on Windows.** Opens the duplex
  device in `ma_share_mode_exclusive` + `wasapi.noAutoConvertSRC` so audio bypasses
  the Windows mixer (native format, low latency). Surfaced as a Windows-only
  audio-setup toggle, **default ON on Windows** / hidden + off on macOS/Linux,
  persisted (`audio.exclusive`). One *intent* bool (`le_config.exclusive`) flows
  down; one *reality* bool (`le_snapshot.exclusive_active`) flows back up the
  snapshot so the UI shows a "Shared — device refused exclusive" note only on a
  fallback. **Graceful fallback**: a pure `le_decide_share_fallback` helper retries
  shared once if exclusive init fails, so audio never dies; the platform default is
  resolved in the presentation layer (`defaultTargetPlatform`), never in storage.
  Verified on a real interface: exclusive engaged with the requested 128-frame
  buffer honored (shared would clamp to the OS period). macOS/Linux unchanged
  (no hog mode). See `docs/WINDOWS_ASIO.md`.
- **Device-backend seam (ASIO Part 1 — foundation, behavior-preserving).** An
  internal vtable (`le_device_backend.h`: `open`/`start`/`stop`/`close` +
  `le_device_open_result`) that `le_engine_start`/`stop`/`destroy` drive instead
  of calling `ma_device_*` directly. The existing miniaudio device lifecycle
  (config build, context init, pin/loopback resolution, the exclusive-mode
  fallback, `ma_device_init`/`start`/`uninit`, data + notification callbacks)
  moved verbatim behind it into **`engine_miniaudio.c`** (compiled
  unconditionally like the per-OS TUs); `le_engine_process`, the ring, the
  snapshot, and the looper/lane/FX DSP stay in `engine.c` and are reused
  unchanged. `le_select_backend(backend)` returns `&le_miniaudio_backend` for
  every choice in this build — the default build links **no** ASIO symbol
  (link-time guarantee; the `#if SEGNO_ENABLE_ASIO` branch lands in Part 2).
  This is **distinct from** the per-OS `engine_platform.h` seam (capabilities
  over one shared device, not swappable backends). The FFI structs grew their
  final Part-2 shape, **inert** today: `le_config.backend`/`asio_driver`,
  `le_device_info.input_channels`/`output_channels` (`0`/unknown on WASAPI;
  `device_info_copy` zero-inits them to avoid a stack-garbage read),
  `le_snapshot.active_backend` (always WASAPI). Threaded through Dart with
  inert defaults (`AudioBackend` enum, `EngineConfig`/`AudioDevice`/
  `EngineSnapshot` new fields + hand-written equality). **Acceptance gate:
  invisibility** — all existing native + Dart tests pass unchanged. New tests:
  `test_select_backend_defaults_to_miniaudio`, `test_backend_struct_defaults`,
  enumeration asserts `input_channels == 0`, and Dart round-trip/equality for
  the new fields.
- **ASIO duplex backend (ASIO Part 2 — opt-in, off by default).** The real ASIO
  capture/playback backend behind Part 1's seam, so a pro interface runs at its
  **full channel count** (e.g. 18 in / 20 out) that WASAPI never exposes. New
  **`win_asio_device.cpp`** (`#if SEGNO_ENABLE_ASIO`) exposes
  `le_asio_backend`: load the driver → negotiate rate/buffer → run its real-time
  `bufferSwitch` feeding the **unchanged** `le_engine_process`. ASIO's
  per-channel native-format buffers are bridged to the engine's interleaved f32
  by the pure, unit-tested `le_deinterleave_in`/`le_interleave_out` (Int16/24/32,
  Float32 LSB) + `le_asio_pick_buffer` (snap-to-allowed-size); scratch is
  pre-allocated at open so the RT contract holds. `le_select_backend` returns
  `&le_asio_backend` under the `#if` (default build still links no ASIO symbol);
  `le_engine_start` **falls back to WASAPI** once on any ASIO open failure, and
  `le_snapshot.active_backend` reports the negotiated reality. New
  `le_enumerate_asio_drivers` FFI symbol (real probe in the `#if`, stub returning
  0 in `engine.c` otherwise) — **regen ffigen** (`dart run ffigen` + `dart
  format`; diff is just the one function). **R1 re-entrancy**: enumeration never
  probes while ASIO is the running backend (native reports the open driver; the
  cubit refuses to enumerate while `activeBackend == asio`); teardown clears the
  callback's engine pointer only after `ASIOStop` returns. Dart/UI: a **backend
  selector** + ASIO **driver picker** in audio setup, `AudioBackend`/`asioDriver`
  persistence (forward-compat name read), auto-start relaunch-into-ASIO, and a
  fallback status row. New tests: native bridge round-trips / `le_asio_pick_buffer`
  granularity / enumerate stub; Dart `enumerateAsioDrivers` duplex tagging,
  `StoredAudioConfig` round-trip + unknown-name guard, cubit
  `setBackend`/`setAsioDriver`/hydration/no-reprobe-while-asio, and audio-setup
  widget selector/driver-swap/fallback. **Hardware spike still required before
  merge** (real Focusrite: full count, audio integrity, fallback, persistence).
- **Sessions + WAV export** (Phase 4 slice): `session_repository` saves/restores
  `.segno` bundles (a JSON manifest + 32-bit-float stem WAVs + a mixdown) and
  exports mixdown / per-track stems. Native `le_engine_export_track` /
  `import_track` / `commit_session` move loop PCM in and out (control-thread copy
  into EMPTY tracks; a ring command flips them to PLAYING at their multiple, so
  the audio thread's RT contract is preserved). `SessionCubit` + a session menu
  (the `folder` `PopupMenuButton` in the Big Picture top bar — kept there, not in
  the settings route, because settings is pushed *above* the `LooperPage`
  providers so the cubit isn't reachable from it) drive it; the engine is shared
  (looper owns dispose). Load refuses a sample-rate mismatch (no resampling) or a
  newer manifest version — both are typed (`SessionSampleRateMismatch` /
  `SessionUnsupportedVersion`), classified by the cubit into `SessionError`, and
  rendered as localized human-readable text. Outcomes (success + error) surface
  in a `Semantics(liveRegion: true)` SnackBar (WCAG 4.1.3).
- **Unified input FX & routing** (plan
  `docs/plan/2026-06-22-feat-unified-input-fx-routing-plan.md`). Collapses the
  two FX surfaces into one: each hardware input now has a **single** live-monitor
  chain (output mask + volume + mute + effects), and that chain is **snapshot-
  copied onto a track lane at record** — the take plays back through the chain
  you monitored, while the recorded buffer stays clean (non-destructive; playback
  re-applies the snapshot). The copy is by value on the **control thread** (in
  `le_engine_record`, asserted RT-safe by a control-thread copy counter), so
  editing the input chain afterwards never alters an earlier take (D3). Native:
  `le_monitor_input` folded from N lanes to one chain;
  `LE_CMD_SET_MONITOR_LANE_*` retired for single-chain
  `LE_CMD_SET_MONITOR_INPUT_FX`/`…_FX_COUNT`/`…_OUTPUT`/`…_VOLUME`/`…_MUTE`. New
  **structural output gate** (`LE_CMD_SET_OUTPUT_ENABLED` + snapshot
  `output_enabled_mask`): a disabled output is skipped in the mix fan-out while
  its lane/monitor masks are preserved (re-enabling restores them) — distinct
  from a level mute, RT-safe mid-record, default-on, beyond-channel-count gates
  ignored. Dart: `InputMonitor` reshaped to a single chain (`MonitorLane`
  dropped), `MonitorCubit` single-chain API, `LooperRepository` single-chain
  monitor setters + `setOutputEnabled` + record-time lane-FX mirroring,
  `LooperState.outputEnabledMask`, `LooperOutputEnabledToggled` bloc event, and a
  **v2→v3 migration** (`monitor.migrated_v3`, after v2) that folds multi-lane
  monitor keys per **D9** (first non-empty chain — lane 0 preferred, NOT merged —
  OR-union of output masks, lane 0 vol/mute) and clears the dead keys. UI: the
  monitor graph folds to one node per input (no lane stack), recorded lanes show
  an FX-snapshot badge, and the routing graph renders gated-off outputs greyed +
  non-targetable (reusing `RoutingNode.excluded`) with a tap-to-toggle and a
  non-blocking "no active outputs" notice; accessibility labels on the gate
  toggle and disabled outputs. FFI regenerated (`dart format`, no churn).
- **Signal surface → three routing lists** (plan
  `docs/plan/2026-06-22-refactor-signal-three-list-surface-plan.md`, brainstorm
  `docs/brainstorm/2026-06-22-signal-list-surface-brainstorm-doc.md`, mockup
  `docs/design/signal-list-surface-mockup.html`). The node-and-wire Signal graph
  (below) tangled into unreadable spaghetti at ~16×16 and rendered per-track
  lanes as ambiguous duplicate "Lane 1"s, so its **presentation** was replaced
  by **three side-by-side scrolling lists** — Inputs | Tracks | Outputs — with
  **no wires**. `SignalRows` (pure, unit-tested) flattens `MonitorState` +
  `LooperState` into rows, **collapsing single-lane tracks to the track itself**
  (kills "Lane 1 ×8") and nesting multi-lane takes, tagging each row for trace.
  Routing is **output-hued chips** (`SignalRoutingChips`: lit = routed, "+"
  opens an output picker) → `setOutputMask` / `LooperLaneOutputChanged`.
  "What connects to what" comes from per-output colour + **tap-to-trace** (tap a
  row → its connections light across all panes, the rest dim; view-local
  `TraceState` recomputed from current rows each build, **no new cubit**). A
  take's `rec In N` badge re-assigns its captured input (`LooperLaneInputChanged`).
  Outputs show the structural gate + a derived "fed by" summary + the
  `liveRegion` no-active-outputs notice (now a `SurfaceTheme.warning` token for
  high-contrast a11y). Responsive: stacks to one column below
  `kSignalStackBreakpoint` (960px). **Keeps** the engine state + the
  instrument-panel dock/knob/style layer (`SignalInputDock` gained an additive
  FX-chip row to match `SignalLaneDock`, via a shared `_FxChipRow`); **retires**
  `SignalGraphLayout`, the node widgets, `SignalView`, and all canvas/wire usage.
  Old graph/layout/node tests removed; coverage migrated onto `signal_rows` /
  `signal_list_view` / `signal_routing_chips` tests. The bundled fonts + tokens
  from the prior pass carry over. `package:routing_graph` stays (still used by
  other surfaces; the Signal surface now uses only `FocusableTapTarget`).
- **Unified Signal surface — node graph** *(superseded by the three-list surface
  above; the engine wiring + dock/knob/style layer remain in use, the
  canvas/wires were removed)* (plan
  `docs/plan/2026-06-22-feat-unified-signal-surface-plan.md`, brainstorm +
  mockup in `docs/{brainstorm,design}/`). Replaced the three old node-and-wire
  surfaces (Audio Setup monitor graph, Big Picture settings Routing tab,
  per-track lane dialog) with ONE full-screen **Signal** canvas: hardware
  **inputs** on the left (rich node =
  on/off gate + the single live FX chain that records + level, reusing the kit's
  `EffectChainCard`s), every track's **lanes** in the middle (FX-snapshot badge
  per recorded lane), hardware **outputs** on the right (structural on/off gate,
  greyed when off, edges still drawn). One contextual bottom **dock** swaps by
  focus — the input's tone editor (`SignalInputDock`) or a lane's "this take"
  snapshot editor (`SignalLaneDock`). Bezier edges: capture (input→lane),
  playback (lane→output, fanned at a rail), and the focused input's live-monitor
  send (dashed + faded, focused-only for a calm canvas). Geometry is a pure,
  tested `SignalGraphLayout` composing `package:routing_graph` helpers; focus +
  selection are view-local. Capture-on-tap (D2b): focus a lane, tap an input to
  record it (`LooperLaneInputChanged`; re-tap un-captures). Reached from the
  performance view by a visible chrome button **and** the `G` shortcut;
  `showSignalPage` re-provides `LooperBloc` + `MonitorCubit` + `AudioSetupCubit`
  into the pushed route. Audio Setup keeps only device/SR/buffer/latency; the
  `LaneNode` moved into `signal_graph/`.
  **Superseded (#533):** Signal is a tray rail destination now — cards, a
  detail panel, an FX editor and an add dialog under
  `lib/looper/view/signal/`. `signal_graph/` and the FX dock were deleted
  whole; the chrome button and `G` open the tray at Signal. Built in 3 stacked phases (scaffold →
  rich node + dock → deletions); ~1.3k lines of old-surface tests removed with
  their load-bearing coverage migrated onto the `signal_*` tests.
- **Segno FX plugins** — Segno's own built-in effects, shipped *as* real,
  installable VST3 plugins for third-party DAWs (distinct from the plugin
  *host* above — this ships Segno's own DSP as third-party VST3 plugins).
  Seven native plugins share one `packages/segno_engine/vst3/` build —
  **Delay, Reverb, Echo, Drive, Filter, Tremolo, Octaver** — each wrapping
  the same engine DSP core the looper uses, so behavior can't drift from the
  in-app effect, checked by a **golden-parity audio-diff harness**. **macOS,
  Windows, and Linux all build and test all 7 plugins**, each via its own CI
  job (`vst3-plugins-macos`/`-windows`/`-linux`) running the shared CTest
  gate. Parts 15-17 (further effects/polish) are not yet started.
- **Performance recording** (12-part plan). Captures a full live performance
  to disk, sample-accurately: RT-safe audio-thread taps write into lock-free
  rings, a control-thread drain thread streams them to a per-run event log
  (`wav_codec` for the WAV side, new `performance_repository` for capture
  lifecycle — arm/finalize/recover-unfinalized/rename/discard), surfaced by a
  recorder UI + app state (record/play toolbar affordance).
- **Performance recording — pedal firmware parity.** The console's pedal board
  has no spare footswitch, so arm/disarm rides the existing MODE button via a
  tap-vs-long-press split (tap still toggles Rec/Play; a ≥500 ms hold
  arms/disarms). The armed state rides the wire but is **not** rendered on the
  pedal board: it once blinked the MODE LED red, dropped in #693 because armed
  already shows on the screens and blink-vs-solid was too fine a distinction on
  one LED at stage distance. The MODE LED now reports the interaction mode
  only — rec red / play green / FX blue, solid in every state — in
  `firmware/console_board` and on the on-screen `PedalFaceplate` simulator.
- **DAW export.** New `daw_export` package (pure Dart, no Flutter/engine
  dependency) turns a completed performance capture into a real **Ableton
  Live 12 `.als`** project: one audio track per non-empty track/live-input
  stem, arrangement-view clips at capture start, session-view loop clips per
  lane, and volume/mute **automation envelopes** thinned from the event log.
  Its newest piece (device-chain export) resolves a channel's per-lane
  effects into a single **real Segno VST3 device chain** embedded in the
  `.als` when every lane agrees on one representable chain, falling back to
  the wet-bounce stem export otherwise (mixed lanes, a third-party plugin, or
  an unrepresented effect type). **Known gap:** `PerformanceRepository.arm()`
  is not yet called with real per-lane chains at either call site
  (`performance_recorder_cubit.dart`, `control_cubit.dart`), so the shipped
  app always takes the wet-bounce fallback today — wiring real chains
  through is a small separate follow-up. Also **note:** the presentation
  layer (`PerformanceRecorderCubit`, `export_device_chain_summary.dart`)
  currently imports `daw_export` and does its own file I/O directly rather
  than going through `performance_repository` — an accepted, documented
  layering shortcut, not yet folded into the repository.

---

## Locked design decisions (don't re-litigate)

- **Record is exclusive** — one input stream, one capturer; chained hand-off.
- **Latency compensation** — comp write + live monitoring + auto-offset from the
  loopback measurement, persisted per device.
- **Undo/redo** — multi-level, per track, overdub layers only. A **user clear
  is undoable**: it leaves a per-track restore point (take + layers + FX chains
  + mutes) that undo brings back; a post-clear-all toast and `⌘⇧C` restore the
  whole rig at once (undo-clear-all, derived from live restore points).
  Session-load clears stay destructive. Immediate swap (tiny click on undo
  accepted).
- **#4 loop multiples** — **auto-round on stop** (record freely from the loop
  top; round track length up to the nearest whole multiple of the base loop).
  Free-running `loop_iteration`; track reads its `(iter-start_iter) % k` segment.
  New-track first pass always begins at the loop top (phase-locked multiples);
  per-track multi-loop phase is relative to each track's own start.
- **Fully free mode (no tempo)** — the looper is tempo-free: one master loop
  length set by the first recording, no metronome/click/count-in/tap-tempo, no
  loop↔tempo sync, no quantization. Captures start/stop immediately. BPM logic
  was deleted (not hidden) from engine → FFI → repo → bloc → UI. Loop multiples
  (#4), latency compensation, the waveform visualizer, Big Picture / two-window,
  and theming are retained. (Supersedes the earlier #2 loop↔tempo and #3
  quantize-start decisions, which were removed.) **Superseded in turn** by the
  tempo-aware engine (#263, #1179): tempo, click, count-in, quantization and
  the five looper modes are back, as `docs/handoff/segno-app/accepted-behavior.md`
  specifies.
- **Transport holds at the top when idle** — the master clock advances only
  while a track is active; otherwise it sits at 0. Play always resumes from the
  beginning, never mid-loop in silence.
- **8 slots, two banks of four** — the engine always carries 8 tracks; the bank
  toggle is **app-side presentation** (show 4 = bank A, or two banks of 4). The
  engine processes all 8 (empty ones are silent).
- **Keyboard map lives in the Big Picture `Focus`** — plain keys are consumed
  (no macOS beep); number keys map to the visible bank, auto-switching banks when
  a digit targets the other four.

---

## Roadmap (path forward)

**Full multichannel per-track I/O routing — SHIPPED.** The "last big feature" is
done in code: it landed as the multi-lane / dual-route rework (per-lane
input/output masks through the native engine `LE_CMD_SET_LANE_INPUT/OUTPUT` +
`le_lane_snapshot`, the `Lane` domain model + `setLaneInput/Output` repo methods,
`LooperLaneInput/OutputChanged` bloc events, and the `lane_graph_view.dart`
wiring UI). Plan: `docs/plan/2026-06-09-feat-multichannel-routing-plan.md`. Only
the **on-hardware end-to-end validation** (full-count interface plugged in)
remains open — see "On-hardware validations" below.

### Possible next steps (no hard dependency)
- **Per-track multi-loop phase alignment** — multi-loop tracks currently phase
  relative to their own start iteration; an absolute-parity option would align
  all k-loop tracks to the same base-loop downbeat. _(Not started.)_
- **Accessibility pass** — no `Semantics` coverage yet (theming + golden tests
  are done). Screen-reader labels, focus order, keyboard-nav a11y tests.
- **VST3 FX plugins — parts 15-17** — further built-in effects/polish beyond
  the 7 already shipped (Delay/Reverb/Echo/Drive/Filter/Tremolo/Octaver) and
  their Windows/Linux builds; brainstormed
  (`docs/brainstorm/2026-07-13-vst3-plugins-parts-15-17-brainstorm-doc.md`)
  but never planned or built. Epic #194 is closed, and the desktop targets
  went with #920.

### Deferred (need hardware / 2nd display)
- `midi_client` — real USB-MIDI binding **SHIPPED** (PRs #39/#40/#42): native
  `le_midi_*` capture seam → `MidiControllerSource` → `ControllerRepository`,
  with a device-selection UI. Hardware-gated only for a live DIN-MIDI smoke test.
- **VST3/CLAP plugin hosting on Linux.** Hosting is on by default only on
  macOS; the Linux CMake build leaves `SEGNO_ENABLE_PLUGINS` off unless the
  environment overrides it, since third-party plugins rarely ship for aarch64
  Linux.
- **Readout screen** — the console's 7″ runs as the second Flutter engine under
  ivi-homescreen, fed over the screen link (`lib/visualizer/screen_link.dart`,
  #1318, #1330); the on-device check is in `docs/HARDWARE_VALIDATION.md`.
- **Device hot-plug / reconnect — SHIPPED** (PR #41-era `feat/audio-device-a2`):
  `LooperRepository` reconnect supervisor (`_intendRunning` guard,
  `_attemptReconnect`, `_pinnedDevicesPresent`) + `devicePresent` UI banner.
- **Phase 4:** sessions save/load + WAV export ✅, theming ✅, golden tests ✅.
  Remaining: accessibility (see above).
- **Raspberry Pi GPIO backend — DROPPED** (2026-07-22): won't be built. No
  `gpio_client` / libgpiod package is planned, and `ControllerSourceKind` is
  MIDI-only (the once-planned `gpio` variant was never added).

### On-hardware validations still open
- Phase-1 **latency gate** (≤10 ms round-trip) — needs a class-compliant
  interface + a loopback cable; see `docs/HARDWARE_VALIDATION.md`.
- Audible tightness of latency compensation and undo/redo clicks.

---

## Test counts (last green)
native (all C tests: incl. mid-loop record, transport reset single- &
multi-track, loop multiples, loop-viz, per-track effects DSP, session
export/import roundtrip, **single-chain monitor + record-FX snapshot +
RT-safety + structural output gate**) · VST3 CTest gate (16 wired: 7
plugin-id + 7 parity + 2 wrapper, plus a per-plugin load-smoke check) ·
segno_engine (dart, the FFI/plugin layer — was labeled "plugin") 138 (~7
skipped) · controller_repository 18 · looper_repository 184 (~6 skipped) ·
settings_repository 65 · session_repository 57 · local_storage_client 1 ·
performance_repository 56 · pedal_repository 116 · midi_device_repository 22 ·
routing_graph 45 · wav_codec 5 · daw_export 79 · app 737 (~13 skipped) excl.
author-only `screenshots`-tagged goldens (auto-start/first-run, big-picture
settings + access, banks + A/B, performance keyboard, functional-settings,
**Signal three-list surface: SignalRows flatten + single-lane collapse +
tags, routing-chip toggle + picker, capture re-assign, tap-to-trace
dim/clear, output gate + a11y, no-active-outputs notice, responsive
stacking, contextual dock**, session menu, **performance recorder UI +
pedal arm/disarm**, **DAW device-chain export**). `flutter analyze` clean;
macOS app builds end-to-end. `LE_MAX_TRACKS = 8`, `LE_MAX_CHANNELS = 32`,
`LE_FX_MAX = 8`, `kMaxOutputs = 8`.

### 2026-09-07 — Supplier handoff packaging

Prepared `hardware/enclosure/out/segno_dinacut_2026-09-07.zip` with 22 unchanged,
previously reviewed CAD/drawing files plus Spanish text instructions and a hash
manifest. Eight fabricated pieces use seven distinct designs; the assembly STEP
is reference only. Added the request to qualify laser cutting of the lid
fastener holes; DRILL geometry and its current post-bend meaning are unchanged.
The complete enclosure stack is grouped separately by supplier in
`segno_archivos_completos_2026-09-07.zip`. Verified all five original archive
hashes and all 88 members against loose files, then checked the new packages.
Nothing was sent; supplier and physical acceptance remain open. Evidence:
`docs/reviews/sheetmetal-release-fixes/dinacut-handoff-verification.json`.

## Reversible-edits reconstruction (2026-09-15)

The accepted mode-rules and reversible-edits slice is reconstructed on the
reviewed Tracks/UART base (`09c8e9c2`), retaining original slice parent
`6cdfb9fb`. Tracking: #1060, part of #1012 and integration #1058.

The user approved refusing recovery of a completed recording that does not
fit the current loop mode. Audio, history, effects and transport stay intact;
the app explains how to select Free and retry. A pending clock or unfinished
capture asks for a retry instead. No automatic mode change is made. Partial
takes inside an established Multi cycle still retain the whole loop span,
with silence outside the recorded fragment.

Frozen-clear ownership/reset, grouped Undo/Redo metadata, confirmed-mode
persistence and callback mode-fit races are repaired. Final validation passed:
2,255 app tests, 1,610 package tests, native safety configurations, 150 FFI
symbols, analysis, Bloc lint and formatting. Five review roles have no
unresolved findings. The stacked PR still needs remote CI and its human merge
gate; recording timing and later implementation slices remain in progress.
Details and validation boundaries are in
`docs/reviews/design-edits-restack/review.md` and `validation.md`.

## Physical pedal state integration — October 1, 2026

PR #1031 now uses one authoritative ten-pedal activity/color frame through the
app, setup map and current Pico 2 renderer. UART v8 / STATE51 avoids the separate
published v6/v7 hardware formats; intermediate #1029/#1030 must not be installed
alone. Ten eight-pixel indicators and the forty-pixel ring preserve the sourced
optical/current limits. No legacy protocol fallback or device flash.

Full app: 2,346 passing, six existing skips, 91.126% coverage. Pedal package:
213 passing, 97.743%. Firmware fixtures, actual sketch tests and Pico 2 compile
pass. Independent source/five-role review and a separate adversary are clean.
[Validation and limits](reviews/design-pedal-led-restack/README.md) bind the exact
candidate. Palette editing is the next slice; hardware acceptance remains open.

## Reusable LED palette — October 1, 2026

PR #1032 adds the accepted LED colors editor to Layout A. All ten physical
indicators have saved hues, including fixed controls. Reusable custom colors
keep stable identities; Hue/Saturation/Brightness edit exact RGB. Draft
preview stays local until durable Save, and Cancel preserves the live setup.
Color-only saves preserve held actions, pending gestures and delayed native
receipts. Actual assignment changes still retire those gestures.

The palette is app-owned configuration on the existing protocol 8 frame; no
firmware, native engine or package changes are introduced. Malformed explicit
settings are refused through the existing recovery path. Clear and Restore
retain later palette edits. The saved Pen note and setup images record the
color context and non-overlapping placement beside the raised pedal row.

Verification and review are recorded in
[the palette report](reviews/design-led-palette-restack/README.md). Physical
color appearance and brightness remain appliance checks.

## Pedal artwork reconciliation — October 1, 2026

PR #1034 restores measured geometry in the existing pedal widget, preserving
its enclosing hit areas, labels and state-driven indicators. The source and
independent render reviews are clean; the app suite passes 2,374 tests with
90.069% coverage. See `docs/reviews/design-pedal-art-restack/` for the source
binding, saved Pen reference, author visuals and separate review evidence.
Published-head CI and the human merge gate remain required.
