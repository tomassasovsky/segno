# Recovery expansion review

Completed September 9, 2026, against the September 8 plan under issue 919.
All six local prototype slices and their saved editable references are ready
for review. No unresolved actionable findings remain in the declared scopes.
No production, CI, PR, merge or appliance certification is implied.

[Plan](../../plan/2026-09-08-recovery-expansion-plan.md) ·
[Behavior and limits](../../design/2026-09-09-recovery-expansion-delivery.md) ·
[Review gallery](../../design/recovery-expansion-previews/index.html)

## Independent reviews

| Role | Report | Unresolved findings |
| --- | --- | --- |
| VGV and correctness | [Report](raw/vgv.md) | 0 |
| Architecture | [Report](raw/architecture.md) | 0 |
| Test quality | [Report](raw/test-quality.md) | 0 |
| Readiness | [Report](raw/pr-readiness.md) | 0 |
| Simplicity | [Report](raw/simplicity.md) | 0 |

The coordinator read and reconciled all five reports. Each reviewer disclosed
authored implementation/test exclusions; another reviewer covered those modules.
Final host-schema and publication/restart corrections were independently checked
on September 9. Raw reports bind source hashes and distinguish their independent
checks from author/coordinator screenshot evidence.

## Findings resolved

- Complete backup and recovery accepted damaged or reordered performance parts.
  They now consume the shared multipart validator, including referenced recorded
  performance descriptors.
- Malformed port collections could throw before the repair guard. Both the
  model and host preflight now reject invalid manifests without constructing or
  committing a candidate.
- Imported-audio repair left missing references in live/removed layers and
  Undo/Redo history. One shared traversal now repairs them together while
  preserving timing, gains, silent regions and history.
- The appliance host cached an archive after review. Final validation now reads
  the authoritative store again, detecting changed or removed packages.
- Restore omitted the last performance metadata and accepted missing preset
  collections. It now preserves the complete payload and refuses incomplete
  packages at both review and publication.
- Input between restore publication and reload could save the old rig over the
  restored setup. A synchronous restarting guard now stops old-state input,
  separate settings writers and timer updates. Independent deferred-restart
  replay verified all restored stores remain unchanged.
- Recording discard allocation and input stereo regrouping were checked through
  failed writes and reload. Capacity is released only on successful discard;
  grouping retains the exact physical member jacks and rolls back on failure.

## Verification

The combined model/controller run passed **143 tests**, with no failures or
skips. It included recorded recovery, appliance backup/storage transaction,
primary selection, preset audition, physical port repair, recording, session
recovery/ownership and media parity. Overlapping reviewer test totals are not
added to this number.

Chrome and Firefox passed:

- `verify_recorded_audio_recovery_browser.cjs`
- `verify_session_audio_port_repair_browser.cjs`
- `verify_appliance_backup_browser.cjs`
- `verify_primary_audition_browser.cjs`
- `verify_long_performance_recording_browser.cjs`
- `verify_input_binding_grouping_browser.cjs`

These exercise normal persisted state as well as prepared scenes, with Cancel,
actual browser storage failures, stale media/ports, retry and reload. Earlier
recording, session Library, control repair, connection repair, field ownership,
media recovery and performance recording/export journeys also pass. Applicable
JavaScript syntax, script/style dependencies and scoped whitespace checks pass.
No Dart, firmware, native engine or generated binding changes are part of this
pass; their build/tests are not substituted with browser evidence.

## Saved design evidence

Six new sections, 42–47, hold fifteen editable 1920 × 1080 screen references.
Native geometry checks report 495 aligned text positions and fifteen unclipped
encoder focus outlines, plus 1,095 matching element rectangles. All 47 current
section frames remain contained and non-overlapping. Every new native render
was inspected before export. Matching
browser references were captured at the full canvas size with no page errors.

The explicit native File → Save completed. Two on-disk checks returned
97,263,957 bytes and SHA-256
`b031cbb64477a2f1d5714565bf1aa48c8877636fb7fd0f7a78ed8779895e249a`
for `segno-ui.pen`, changed from the preceding saved design. The current gallery
and manifest contain 298 references, including these fifteen additions.
The new gallery resolves every local image/link and fits both 1440-pixel and
420-pixel viewports without horizontal overflow.

The checked main prototype remains SHA-256
`c821a23af292aafd32d08e7e88fc9f60c732d6bcb037f6e9682525d0979d9bb4`.
Those source reviews preceded the small presentation refinement described below.

## Recorded walkthrough refinement

The requested walkthrough records all six flows through real browser controls,
with assertions for cancellation and applied results. The combined silent H.264
video is 207.2 seconds at 1920 × 1200, including a recording-only caption strip;
the appliance canvas remains 1920 × 1080. All six paths passed a rehearsal and
their recorded executions. Chrome player checks pass metadata loading, six
chapter buttons, seeking, playback and a 420-pixel viewport without overflow.

Video inspection exposed flex compression of port-option explanation labels.
Two scoped CSS declarations now prevent option shrinking and allow the reason
to use the available width. The connection journey passes again in Chrome and
Firefox. Its browser capture, editable Pen reference and video chapter were
replaced. This coordinator-verified CSS refinement is subsequent to, and not
covered by, the original independent review snapshots above.

The current fifteen references contain 492 text positions with zero native
position mismatches. File → Save is verified on disk at 97,260,295 bytes and
SHA-256 `7fd2c9c4dfbaa9abb9db85634a4d6edf8a86294cb8b0ab6c55093338be554e9b`.
The main prototype HTML hash is unchanged. The chapter player loads the small
video as a Blob because the static preview server lacks HTTP range support.

## Boundaries

All workflows are silent simulations. Native byte copying/checksums, physical
port discovery, real free-space accounting, audio capture, filesystem atomicity
and crash/power-loss recovery require production implementation and device tests.
The browser multi-store transaction handles ordinary write failure but does not
claim power-loss atomicity. The user has not implicitly accepted every proposed
limit or policy by authorizing this build. Downstream tails, capture-tap choices
and the remainder of the broader audit stay separate.

## Connection summary clarity refinement

Owner feedback on the walkthrough requested less crowded text in Review
connections. The physical-port summary now uses structured source and replacement
labels in two columns, plus a route count. It no longer repeats the detailed
route list already shown in the picker. Apply, Cancel and the existing error,
reload and stereo cases pass in Chrome and Firefox.

The updated Pen reference is visually checked and saved; all fifteen references
now contain 494 aligned text positions and 1,101 element rectangles. The saved
file is 97,271,590 bytes, SHA-256
`ecfa11920932f91f53296991b58c22ce1508ff16a4e012473143414b06504c1c`.
The second video chapter was recorded again and packaged into the walkthrough.
Chapter seeking and playback checks pass. This narrow presentation refinement
is coordinator-verified, subsequent to the independent review snapshots.

## Owner acceptance

September 9, 2026: all six demonstrated flows and the compact connection
review are accepted. The gallery, delivery record and Pen sections 42–47 now
carry that status. This changes design acceptance, not native verification.
The saved Pen file is 97271806 bytes, SHA-256 `35798360a89fd759f2fb06b4b30701906876269acf7a7b27b7ac557ad7635d89`.
