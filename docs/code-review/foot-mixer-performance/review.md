# Foot Mixer review

Issue #1123. Base: `029245043b4b6247b1835261932dee7cdaf161ba` (#1129).
Human merge gate. Final source binding:
`15e0e4b3601ef4fb616bb8876836b81586d398e0d192afd63f83a056af04e205`.

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

PR-readiness review found no mechanical issues in the original feature. The
actual Claude review of this feature stopped at its session quota before a
verdict; it remains incomplete. Prerequisite #1128 now supplies explicit Retry
for failed Monitor restoration and has passed local independent reviews and its
full app checks. Its additional Claude re-review remains pending. Prerequisite
#1129 passed actual Claude re-review before this restack; its PR delta is byte
identical afterward. Current-head CI and all outstanding reviews remain required.
Neither this feature nor the whole stack is declared ready to merge here.

The combined regression confirms that a newly saved mute value survives Retry:
failed restore, accepted mute changes, then recovery restores the saved mode,
route and disabled nonempty FX chain while retaining the newer mute choice.
It checks native state, repository, display projection and exact durable values.

## Observed validation

Frozen application and affected repository source passed:

- Application: 3,127 tests passed, 49 conditional skips; 92.40% coverage under the
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
