# Mixer integration review

Issue #1016, PR #1021, campaign #1009. Local verification completed October 1,
2026. Remote CI and the existing human merge gate remain separate requirements.

## Behavior

Mixer appears alongside Tracks and Wave through the existing view menu. The
active bank retains four columns; switching bank or view changes neither the
selected track nor playback. Tracks keeps its single whole-track meter. Mixer
shows stereo signal, pan, independent Mute and multi-track Solo, and a gain
marker over each meter. The gain axis spans silence through +6.02 dB; the side
dBFS scales describe measured signal. Small windows keep all strips readable.

Touch and encoder edits remain local until committed. Selection, editor,
confirmed external values or session changes cancel the unfinished edit,
including a stationary touch that has not become a drag. Double tap restores
unity gain or centered pan without an intermediate write. Reset asks first,
then restores all eight levels and pans while preserving mute, Solo, FX,
routing, original recordings and audio history. Hold Solo clears all Solos.

Rapid Solo presses resolve against ordered shared intent. Temporary Solo
changes remain available when a neighboring durable volume save fails. The
existing atomic mix owner retains exact checkpoint rollback and session
ownership; there is no second control or persistence owner.

## Verification

The full app run passed 2,381 tests, with six existing skips and one outdated
Mixer golden. The last gesture-lifetime repair changed one anti-aliased meter
edge after golden generation. Both Mixer images were refreshed from final
source and inspected; the unchanged golden test then passed in comparison
mode, yielding 2,382 passing tests with no unresolved failure. No production
or test code changed after the aggregate run. The original failed run remains
in the evidence rather than being described as green.

App coverage is 93.27% against the 90% floor. Strict analysis, formatting,
whitespace and the actual 637-file Bloc scan pass. Unchanged native and six
package results were reused only after comparing complete source/test path
sets and hashes with the verified routing base; all coverage floors pass.

Independent review includes 18 shared ordering/reset probes, eight gain,
identity and double-tap probes, and four interrupted-touch probes. Expected
Solo membership comes from a sequential set model rather than the production
queue. Reset refusal checks preserve exact existing and absent checkpoints.
Original failing gestures remain preserved and pass unchanged after repair.
Conventions, architecture, test quality, simplicity and readiness are separate
review roles. Authors did not approve their own implementations.

The actual macOS app passed Mute/multi-Solo, pan/gain edits, Reset Cancel,
confirmed reset across both banks and double-tap defaults. Temporary controls
were restored. Final 1920×1080 and 800×600 goldens are inspected. The updated
implementation note is saved in the owner Pen file with a verified disk hash;
unrelated owner design edits are not copied into this branch.

Final source/test/golden fingerprint:
`98456297337b09093c12647dea17f4d15c9c4cee12cc36f8d46b9f0768d148df`.

## Remaining owners and limits

The current FX control changes real chain bypass. Direct FX editing arrives
with slice 3f. Backing/click controls belong to media integration; foot Mixer
uses the shared performance action model in M3/M4. These dependencies remain
on the campaign, without placeholder actions or a fourth firmware mode.

Desktop verification does not establish physical encoder timing, appliance
readability or audible hardware behavior. CI must pass on the published head
before ready-to-merge. The human merge gate remains; no deployment or flashing
is authorized by these checks.
