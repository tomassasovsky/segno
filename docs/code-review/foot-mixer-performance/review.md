# Foot Mixer review

Issue #1123. Base: `a833c89c5b0d3964a855e72f35b5650bc53350f0` (#1129).
Human merge gate. Final source binding:
`100f5d990688dd6b6dd04d25cb5f9c5cfb35c060846f2753a8a2912883929713`.

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
mute readback; its fixture now models admitted state and asserts both the visible
mute cue and durable mute/unmute values. No production behavior was weakened.

PR-readiness review found no mechanical issues in the original feature. This is
not yet a complete delivery review: actual Claude review of this feature remains
pending. Prerequisite #1128 has a separately confirmed failed-Monitor-load retry
gap; preserving saved settings here does not solve that recovery flow. Prerequisite #1129 has two
independently reproduced findings repaired and locally re-reviewed; its Claude
re-review remains pending. Neither the
feature nor its prerequisite is declared ready to merge here.

## Observed validation

Frozen application and affected repository source passed:

- Application: 3,104 tests passed, 49 conditional skips; 92.38% coverage under the
  configured CI exclusions (90% required).
- Looper repository: 745 passed, zero skipped; 95.84% coverage (95% required).
  Five real-native sample tests confirm live gain/mute do not alter capture PCM,
  capture trim remains effective, and existing loop playback stays independent.
- Strict analyzer over lib, test and packages; explicit formatting of changed
  Dart paths; Bloc lint positively scanned 804 files; diff whitespace check.
- Rebased onto the repaired prerequisite without conflicts, then reran the full
  application and static gates. After the monitor-only save correction, another
  complete app and static pass verified the final 49-path source binding.
  Unchanged repository files retain the 745-test
  evidence above. Source and reused native-library hashes stayed unchanged
  throughout validation.
  No native API, implementation, binding or firmware source changed.

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
