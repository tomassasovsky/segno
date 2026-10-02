# M3.13 — shared Playback Loop/Once

Issue #1026; follows shared overdub decay PR #1095 at
`f186bb952d1d000522c5e8e55226bc2ee0931538`. Existing campaign implementation
and publication authority applies; human merge approval remains required.
This is the next bounded shared-control family, not a performance-mode redesign.

## Contract and authority

Accepted behavior section 2.2/2.5 and the accepted mapping catalogue define
Playback as Loop or Once, independently inherited for each track in all five
modes. Once finishes the current pass and stops that track; it does not change
speed, pitch, recorded samples/history, another track, or another capture cycle.
The accepted catalogue is `docs/design/mapping-parameter-targets.js` in the
owner design checkout: `playback.once`, choices false/true and normalized step1.

Expose nine fixed targets in the existing shared MIDI and External button/
expression catalogue: Loop defaults and Tracks 1–8, including empty tracks.
Use strict identities `DefaultOneShotTarget` → `{"ctl":"defaultOneShot"}` and
`TrackOneShotTarget(n)` → `{"ctl":"trackOneShot","index":n}`, integer n0–7.
Names, selection, bank and recording state do not change that identity.
No selected-track fallback, compatibility key or additional mapping envelope.

Normalized0/.49/.5/1 means Loop/Loop/Once/Once; reject non-finite input before
conversion. One relative step changes one choice. Accepted reads/pickup and
writes use the same two normalized endpoints. Use actual Loop/Once endpoint
choices in the existing value editor instead of an unlabeled percentage slider.
Keep the On/Off and Held/Released source behavior choices separate from the
mapped playback choice. New External buttons use current/current; expression
and MIDI keep0/1. Add/Save alone never changes playback. Reversed endpoints
work; repair preserves authored endpoint values for review.

Explicit track false stays Custom, even when the default is false. Only an
ordinary Use default action removes the override. A controller Released=false
is an explicit Loop override, not an inheritance marker. A later ordinary reset
wins over older held cleanup without resetting source contact/latch or sibling
controls. All existing Decay behavior remains intact and independently ready.

## Runtime and persistence

Extend the single application-owned PlaybackOptionsCubit with a narrow
`OneShotControl` port. Use immutable OneShotAddress/default-or-track snapshot,
result and session/device lifetime plus address revision, matching the proven
Decay ownership pattern. Provide nullable confirmed readiness, live and durable
Released snapshots, ordinary nullable changes and controller write results.
OneShot needs callback confirmation; Decay remains its existing atomic setter.
Do not manufacture a second Playback owner or general settings framework.

Both fields use the existing Playback serial queue. Initialization/readiness
is independent per field. Replace `runDecayExclusive` with one
`runPlaybackExclusive` gate that awaits both initializations before acquiring
that queue. Session lock order is Mixer → Click → Playback, with both durable
snapshots read directly inside it. Do not nest two methods on the same queue,
await Control cleanup from its lock, or add a compatibility alias. Existing
field-specific flush/recovery APIs remain meaningful for shutdown.

Replace ordinary default/track Once write paths with the same owner, including
LooperOneShotToggled and Use default. Track admitted writes for persistence
flush. Verified exact nullable bool checkpoints use existing Settings scalar
keys and serialized writer; preserve absent versus false and unrelated values.
Stage every default/track startup read before any publication. Malformed values
remain preserved and visibly refused, not repaired silently.

Repository setters must distinguish enqueue from acceptance. Verify
`AudioEngine.commandsSettled` and fresh raw `EngineSnapshot.tracks[].oneShot`;
projected LooperState and remembered maps are not receipts. Confirm effective
bits for all affected tracks. Default changes target inheritors only; an empty
inheritor mask is an honest owner-only change with no invented command. While
stopped, accept coherent deferred intent. Native refusal cannot create a holder
or publish a choice. Drained wrong bits or bounded timeout stop uncertain
processing, block unsafe replay and require explicit recovery. Preserve the
existing settlement policy (10ms polling, 50 attempts) unless a concrete
measurement requires changing it.

Store separate durable restart default/override membership. Start/reconnect
replays all eight effective bools, including false, and checks settlement.
Repository-owned receipt observation and a bounded deadline must also cover
synchronous startEngine callers, including bootstrap, run_segno, AudioSetupCubit
and autonomous AudioRecoveryCubit. Do not rely solely on an owner write or UI
polling to finish a reconnect receipt. Capture the effective expected vector,
affected mask and lifetime when admitting; later topology/default changes cannot
redefine an older receipt. A multi-command vector admission that partly refuses
must stop uncertain processing and retain the previous confirmed intent.

Replace applySession's separated default and per-track Once setters with one
final desired default/override vector and one settlement. Preserve its clear/
reset semantics and explicit false membership; a single-pending setter must not
turn the old sequential session calls into notReady failures. Initializer reads
stay outside the shared Playback queue; a runPlaybackExclusive operation reads
snapshots directly and never awaits a field flush or queued setter inside itself.

Session replacement adopts saved Once values, not startup preferences or an old
Held value. Capture origin before queuing source work and fence every await.
Successful compensation of a stale read/write returns superseded; failed
compensation still blocks until exact storage repair. Retry cannot apply an old
rig's payload or claim a failed native restart succeeded. Session saving while
held records Released while current playback stays Held.

Shutdown cuts source ingress first, drains admitted ordinary/controller work,
retires Held values and checks both playback fields. Failure stays on and offers
Retry/Keep playing; retry repairs then retires owed cleanup again. Dispose waits
admitted writes and closes Control before Playback. No firmware, new FFI or
native DSP change is expected: current native Once already covers all modes.
Correct the stale EngineSnapshot documentation claiming Free/Song-only behavior.

## Ownership and sequence

1. Independent plan review: simplicity, VGV conventions and vertical scope.
   Adversary freezes accepted literal/native/failure expectations before writers.
2. Runtime writer owns new pure OneShot port; PlaybackOptions, Control dispatch,
   LooperRepository receipts/replay, Settings bool checkpoints and focused tests.
   Freeze port before model/UI writer. Root owns integration files separately.
3. Model/UI writer owns target/resolver/catalogue/labels/readouts and endpoint
   choice widgets in MIDI/External, model/page tests and proposed render fixtures.
Shared endpoint widgets must remain small and use established tokens/focus.
   Preserve Escape cancellation explicitly: the existing choice button does not
   implement the slider's opening-value restore behavior. Verify focused-choice
   Escape and page Cancel on all three mapping surfaces.
4. Root owns App/bootstrap, LooperBloc/Loop playback page, Session mapping/gate,
   locales, legacy constructor fixtures, saved Pen references and integration.
   Coordinate explicit transfers if a file crosses those boundaries.
5. Freeze source; independent harness and negative control; repair only confirmed
   findings. Final aggregate/static/coverage/native/design gates, five quality
   perspectives, root bug review, exact-head CI and stacked publication.

Maximum two product writers and two test processes. No recursive delegation.
Retain failed runs and changed-fixture reasons. No unchanged suite reruns absent
new source, a changed dependency or a concrete unproven concern. The inherited
M5 live-Control full Session Load failure remains separate; do not claim that
Save, owner adoption or restart alone closes it.

## Observable acceptance and verification

- Strict keys and literal0/.49/.5/1 conversion; reversed ranges, relative steps,
  fixed Track8 identity, invalid coordinates and non-finite refusal.
- Default false plus explicit false remains Custom after default true. Ordinary
  same-value Use default removes only the targeted override and defeats old
  cleanup, retaining source contact/latch/siblings.
- Hold callback pumping: enqueue/storage completion stays pending until actual
  raw snapshot confirms. Refusal, drained wrong bits and timeout retain prior
  accepted state or explicit recovery; validate exact scalar absence/false.
- MIDI/External two-source orderings, ordinary-before/during-held, non-held
  takeover, refused release, retirement/reconnect and missing siblings.
- Save, restart, session replacement and shutdown use durable Released. Pending
  storage/receipt cannot cross replacement lifetime or poison new flush. Retry
  preserves the new rig and repairs only the outstanding scalar obligation.
- Native evidence in all five modes: targeted Once completes the current pass
  then stops, Loop continues, siblings/capture cycles and audio/history remain.
  Mutating or bypassing receipt confirmation in an isolated copy must fail a
  previously declared pending/native assertion without modifying the oracle.
- UI Add/Save/Cancel/Escape and repair preserve endpoint choices without audio
  preview. False readiness is not unavailable; Once and Decay initialize
  independently. Test actual App shutdown and serialized Session bundle output.

Focused suites will include target/catalogue/UI tests, a new Once transaction
and dispatch suite, repository receipt/restart and Settings checkpoint tests,
plus actual App and Session integration. Run the ordinary full app aggregate,
affected package suites with unchanged coverage floors, explicit-file format,
strict analysis, positive-scope Bloc lint, standard native tests and author-only
render/Pen verification. Public evidence binds tested source and records limits;
all required CI jobs must pass on the reviewed head before ready-to-merge.

## Exclusions

Record length/timing, Tempo/Hear click/Count-in, Fade, Follow/Pitch, backing,
instruments, physical controller validation and production deployment remain
separate campaign work. They are not waived or guessed by this slice.

## Pre-implementation review outcome

Three read-only reviewers covered VGV/runtime feasibility, simplicity and
vertical scope. No split is needed. The two runtime refinements above require
autonomous restart receipt observation and a single final session vector. The
UI refinement preserves Escape when replacing a slider with discrete choices.
All are incorporated before implementation; no product decision remains open.
The independent behavioral oracle was frozen before writers at SHA-256
`d2057da82dc1e7e8e0b2ccf9ec12471b6444e4611302b853d07fead15b364d05`.
This records plan readiness, not implementation or test completion.
