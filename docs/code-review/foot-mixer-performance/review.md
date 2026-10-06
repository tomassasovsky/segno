# Foot Mixer review

Issue #1123. Base: `35f28ee2eefb52b915a471d02cad5f9a2e6dd837` (#1129).
Human merge gate. Final source binding:
`8036abb0b6946c52576514b585c581d6c3545873a0cc399b966b2726b09ef7fa`.

## Scope

Adds the accepted foot-operated Mixer for recorded tracks and live inputs,
using the existing ten-pedal layout. Selection and four-channel paging are
local to Mixer; Record/Play retains the normal transport cursor. Channel Hold
changes mute; volume Press changes gain by five percentage points and Hold
resets gain alone to unity. A full step crossing a bound does nothing.

The existing Control owner interprets contacts. A small typed role table is
shared by dispatch and presentation. Stateless Mixer operations reuse the
existing mix transaction owner and confirmed mute persistence. Ordered relative
steps compose in the existing bounded pending map. No new persistence schema,
save queue, gesture timer, DSP, native API or firmware protocol is introduced.

The Tracks view integrates the flow behind the existing assignment catalogue.
Its larger diff includes formatter indentation around the new child choice;
the existing Track/Wave/Mixer column behavior remains the same.

## Review results

Independent architecture, conventions, simplicity and test-quality reviews found
and verified corrections for duplicated pedal role definitions, clipped Spanish
hints and competing screen/physical contacts. Both physical-first and screen-first
holds now use the existing Control ledger with origin identity. Each view contact
also retains its pointer or key identity, so another finger or key cannot release
it. Four widget cases failed before that correction and pass after it. Public
Cubit commands return void; presentation supplies an opaque origin token.

The prior architecture and simplicity reviews cover the shared owners; the final
conventions review additionally covers the last contact API change. The root
review traced gesture admission/release, removed Set membership guards, queue
ordering, source boundaries, persistence and native sample isolation. No unresolved
Foot Mixer finding remained in those completed local reviews. A subsequent
recovery trace found that input mute could overwrite saved routing and FX after
failed Monitor restoration. Input mute now writes only mute through the existing
queue, preserving any pending full-envelope save. Two regressions failed before
repair; five final cases cover both mute callers, refused storage and retry,
retained failed full saves, and overlapping full/mute writes through close.
Independent architecture, simplicity, bug and test-quality reviews found no
remaining issue in this correction. The full suite also caught a missing mock
mute status; its fixture now models admitted state and asserts both the visible
mute cue and durable mute-on and mute-off values. No production behavior was weakened.

Actual Claude review completed and identified two further presentation defects.
After incomplete Monitor restoration, Foot Mixer read from a withheld cache while
its controls changed accepted repository values. The view now observes the existing
repository stream and shares the dispatch projection. Normal restored gain already
updated correctly; that broader reviewer premise was disproved. No second cache,
owner or restore bypass was added.

Mixer's keyboard guard also swallowed focused button activation and modifier
shortcuts. It now preserves the existing shortcut handling and Material activation,
while ordinary transport keys remain isolated. The unused modulo track selection
was removed, and failure notices use the shared identifier registry.

Root independently reviewed the five production paths and four test files for
bugs, architecture, simplicity and test quality. Real composed App tests reproduce
the failed-restore mismatch; normal restore is a passing control. Focused Exit and
Settings activation, Ctrl/Cmd routing and plain transport isolation are verified.
The final full suite passes. Claude's correction review confirmed those repairs
and found one minor keyboard issue: Enter and Space escaped when the Tracks view
itself had focus. The handler now consumes those keys in that case and preserves
activation of focused controls. The extended regression failed with both escaped
keys before the repair; all five Foot Mixer cases pass afterward. Strict analysis,
formatting and Bloc lint pass for both changed Dart files. Current-head CI and the
final bounded review remain required. Prerequisites #1128 and #1129 have clean
reviews and passing CI; older stack reviews remain in progress. No merge readiness
claim is made here.

The combined regression confirms that a newly saved mute value survives Retry:
failed restore, accepted mute changes, then recovery restores the saved mode,
route and disabled nonempty FX chain while retaining the newer mute choice.
It checks the engine test seam, repository, display projection and exact
durable values. Actual native sample checks remain separate below.

## Observed validation

Frozen application and affected repository source passed:

- Application: 3,137 tests passed, 49 conditional skips; 92.64% coverage under the
  configured CI exclusions (90% required).
- Looper repository: 745 passed, zero skipped; 95.84% coverage (95% required).
  Five real-native sample tests confirm live gain/mute do not alter capture PCM,
  capture trim remains effective, and existing loop playback stays independent.
- Strict analyzer over lib, test and packages; explicit formatting of changed
  Dart paths; Bloc lint positively scanned 805 files; diff whitespace check.
- The final combined pass includes the upstream Retry repair and the scalar
  mute save, bound to 66 code, test and image paths. The only rebase conflicts
  were appended localization entries; both accepted sets were preserved.
  Repository and native inputs remain unchanged, so their earlier evidence is
  reused rather than described as newly executed. Source and native-library
  hashes stayed unchanged throughout validation. No native API, implementation,
  binding or firmware source changed.
- The preserved integration checkout passes 184 focused tests with six inherited
  skips. Its additional targeted scalar-save-to-Retry case passes independently;
  unrelated files and the existing index were preserved.

Focused author evidence also covers composed Custom/External/MIDI entry,
18-input paging, fresh bootstrap mute/gain persistence, Session recall, partial
refusal, pending-save ordering, stale controller ownership, and automatic monitor
gates. These focused totals overlap the combined suite and are not added to it.
Five Foot Mixer render checks include Spanish and the last input page. The pedal
picker golden was reviewed and updated only for the newly available Foot Mixer
choice. Screenshots remain author evidence, separate from CI.

An initial combined run detected the expected picker change and the old assumption
that every internal mode needs a new color. The retained regression checks unique
physical Record/Mute/FX/Custom colors and explicitly checks that Mixer uses the
Custom family, consistent with the existing firmware wire contract.

## Validation limits

Physical pedal feel, appliance LEDs, routing through the actual interface and
save/restart on the appliance still need device validation. Encoder detents edit
the selected level; complete physical encoder focus navigation is an existing
separate integration seam, not proved by keyboard navigation tests. Desktop
checks do not certify those hardware outcomes. No deployment or merge is
authorized by this report.
