# Part 2: shared stopped launch (#1026)

Depends on [part 1](2026-10-03-feat-count-in-part-1-plan.md).
Status: reviewed design; rebind source and freeze its oracle before implementation.

## Result and contract

Stopped Record, Play and overdub requests share one Count-in deadline. A later
track joins that deadline without restarting it. Repeating a track's request
cancels that member; Stop cancels all. Running additions use Record timing.

Retain sample-accurate countdown and frozen tempo/signature math. Replace the
single channel with a fixed maximum-eight-member table and bounded insertion
order. Each member owns its action and prepared image generation. No callback
allocation or dynamic queue. Existing-master stopped rigs also count in; when
there is no usable tempo, preserve the explicit immediate-start behavior.

At the deadline, clear memberships before calling existing start bodies so they
cannot re-arm. Start valid members at one sample boundary, in pending insertion
order. Cancel/requeue goes to the end. Song/Band exclusivity and the existing
single-capture policy remain. Simultaneous capture requests end with the last
pending admitted capture, with no zero-length layer or master. Test channels
6→1 and 6→1→cancel6→requeue6 so track index cannot accidentally be the oracle.

Preserve stopped-transport resume behavior but delay its effects until the
downbeat. Countdown frames are not captured and establish no master length.
Only completed real capture establishes length/tempo. Fixed completion, Once,
history, non-defining alignment and capture FX ownership remain intact.

Replace blanket counting-in fast paths with target membership before plugin
preparation. Canceling an existing member prepares nothing; a different valid
track joining prepares its own image. Clear, Undo, mode/FX changes and structural
guards must retire only the correct resources. Audit all single-channel fields.

Near-commit cancellation keeps cancel-wins protection for one callback drain,
now per member/action. It may cancel only that new launch. It must not erase
older audio, globally Undo, manufacture a tiny master or cancel another member.
Playback cancellation restores its prior stopped state without deleting audio.

## Delivery and validation

1. Freeze a native oracle using literal sample positions and distinguish
   preparation, pending, capture and audible playback. Include positive starts.
2. One native owner changes scheduler, guards, snapshots/API and repository
   preparation. Regenerate bindings if the public header changes. Coordinate
   integration surfaces with the coordinator; no parallel shared-file edits.
3. Independent adversary checks later joins, cancel/requeue, Stop, same-value
   preference changes, boundary races, nonnumeric order, Song/Band and resource
   cleanup. No PCM before the deadline; first intended sample on the downbeat.
4. Freeze source/library and run required native variants, shim, engine/Looper,
   recording/history regressions, App/static/coverage and exact-head CI. Reuse
   only unchanged source-bound evidence; keep hardware claims separate.

No Count-in mapping target ships in this part. External-clock Receive still has
no producer; retain its future bypass requirement without inventing a receiver.
The future capture journal must extend admission before it ships. No parallel
capture, changed pitch/speed or compatibility path is introduced.
