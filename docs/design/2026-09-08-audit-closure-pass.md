# Audit closure design pass

September 8, 2026. The owner authorized the next pass of the
[183-item closure plan](../plan/2026-09-08-audit-closure-plan.md). This report
records local prototype changes and independent review. It does not mark the
production application or the assembled appliance complete.

## Ready to review in the main prototype

| Audit item | Implemented interaction | Focused evidence |
|---|---|---|
| LX-003 | Rename from a track heading; Cancel preserves the name and a blank name shows Track plus its number. The Mixer track number still selects the track. | `verify_closure_design.cjs` |
| LX-028 | Mixer opens Backing & click with their shared volume and pan controls. Touch, encoder, Cancel and double-tap reset use the same values as other control surfaces. | `verify_closure_design.cjs` |
| LX-038 | Tempo offers 1 BPM or 0.01 BPM encoder steps and direct fractional adjustment. The existing capture and external-clock restrictions remain. | `verify_closure_design.cjs`, `verify_loop_journeys.cjs` |
| LX-063 | Transpose bypass preserves the stored pitches and selection; re-enabling restores their effect. Reset remains a separate action. | `pedal-closure.test.cjs`, `verify_pedal_closure.cjs` |
| LX-075 | Track FX pages expose the same track Solo state as Mixer, with a return to the initiating view. | `verify_closure_design.cjs` |
| LX-084 | Import and export presets through Internal or USB, with package selection, naming, review, cancellation, storage errors and drive removal. The old desktop file-picker path is removed. | `media-closure-study.test.cjs`, `verify_media_closure.cjs` |
| LX-089 | Clear custom assignments across both banks with confirmation, Cancel, Save and Restore. Fixed controls and LED settings survive. | `pedal-closure.test.cjs`, `verify_pedal_closure.cjs` |
| LX-095 | Direct assignments for all five loop modes use the existing compatibility checks and foot-operated stop/switch confirmation. | `verify_mapping_parity.cjs`, `verify_pedal_closure.cjs` |
| LX-168 | Storage estimates recording time from available space, reserve and format. Applying a different device sample rate changes the estimate; unknown capacity stays unknown. | `media-closure-study.test.cjs`, `verify_media_closure.cjs` |

LX-181 is partially improved: expression, external-switch and MIDI parameter
mappings now share a destination/control repair sheet, endpoint review and return
to the source editor. Apply repairs the draft; the source's Save commits it.
Failed Save retains the draft, including pending rack activation changes, while
the previous saved rig remains active. Broader repair across missing media,
device ports and complete session dependencies remains open.

The accepted Tracks appearance and physical ten-pedal arrangement are preserved.
The owner accepted this UI pass in the follow-up review. That acceptance covers
the presented designs; the separate behavior and scope proposals below remain
unsettled. All audio, USB, capacity and hardware behavior in these browser
journeys is simulated.

## Validation and review

The focused interaction journeys run in Chrome and Firefox. They cover touch,
encoder, foot gestures, cancellation, state sharing, reload, stale targets,
USB replacement and rejected persistence. Existing Mixer, mapping, Stage, Wave,
external-control and Storage suites provide regression checks. The loop journey
also checks the 1920 × 1080 canvas and minimum touch sizes.

Independent review found and resolved an auxiliary slider fill mismatch, a
failed external-pedal Save that could report success, missing Mixer selection
after adding rename, and repeated package validation during rendering. A combined
failure regression now verifies that repaired settings and pending FX bindings
commit together or remain pending together. No whole-prototype coverage or CI
claim is inferred from these author-side checks.

Detailed source reports:

- [Pedal controls](2026-09-08-pedal-closure-pass.md)
- [Preset media, Storage and target repair](2026-09-08-media-closure-pass.md)
- [Independent review records](../reviews/2026-09-08-audit-closure/raw)

## What still needs evidence or a decision

The [reference follow-up](../research/segno-looper-x-comparison/2026-09-08-recheck/reference-closure-pass.md)
contains concrete proposals for the shared clock, count-in, incompatible partial
take recovery, Clear All during capture, audio processing and session ownership.
These are not silently adopted behavior changes. It also recommends explicit
scope dispositions for double-press Solo, extended MIDI protocols, direct
removable-media recording and screen lock; owner decisions remain pending.

The extraction identifies 302 distinct factory WAV filenames and expected sizes,
but the WAV files belong to a content partition absent from the supplied data.
Native FX translator metadata gives a targeted route to further investigation;
it does not establish the 239 unresolved parameter domains, physical units or
factory defaults. Those seven reference gates stay open.

Actual audio processing, persistence, Linux UI integration and real appliance
tests remain in the production work packages. Nine rows can progress from a
prototype gap to production work; LX-181 remains a partial prototype gap. The
original audit remains unchanged, with every row retained in the updated
[closure inventory](../research/segno-looper-x-comparison/2026-09-08-recheck/closure-items.csv).

## Saved design evidence

Seventeen existing Pen frames were updated and nine added within their existing
flow sections. All 35 current groups remain separate with no hidden tiles or
section overlap. The 26 changed frames are exported at 1920 × 1080 in the
[257-screen gallery](fx-ux-previews/pen-sizing/index.html).

Native checks covered 2,365 element bounds, 1,076 text positions and 26 encoder
focus outlines, with no discrepancies in those checks. Selected native renders
were inspected, including the export filename control and the auxiliary slider
padding. The bulk reparent operation timed out; direct fitting and final native
inspection completed successfully. No timeout is counted as passing evidence.

The saved `segno-ui.pen` is 88,302,899 bytes; SHA-256:
`55ed0e2761bf8c76150ebd4911deb804418ef5d1c7e7d8b5852a53bb5e52e4ab`. The [frame manifest](fx-ux-previews/pen-sizing/manifest.json)
records changed frames and verification. Final source validation is recorded in
[the combined results](../reviews/2026-09-08-audit-closure/final-validation.md).
No production, hardware, commit, publication or merge is claimed by this pass.


Owner review: the new designs were accepted as looking good; the follow-up requested the remaining work and next recommended slice. This is UI approval, not production or hardware certification.
