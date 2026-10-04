# Part 1: confirmed recording-start pair (#1026)

Depends on shared Hear click, PR #1099. See the [delivery plan](2026-10-03-feat-count-in-plan.md).
Status: approved engineering direction; freeze the independent oracle before edits.

## Result

Count-in and Sound-start form one confirmed pair. Every existing touch/encoder
surface, startup, Session and shutdown observes that pair. A rejected change
leaves sound, preferences and pending recording actions intact; uncertainty
presents recovery. This part retains the existing single-destination native
countdown. Shared stopped launches belong to part 2, mappings to part 3.

## Exact behavior

- Choices are Off/1/2/4 bars. Missing both settings means `(1,false)` without
  writing defaults to storage. Explicit zero stays Off. Missing count with
  explicit Sound true means `(0,true)`. Explicit positive count with Sound true,
  invalid types or unsupported counts remain untouched and require recovery.
- Count-in above zero disables Sound. Count-in zero preserves the current Sound
  choice. Enabling Sound sets Count-in to zero; disabling it preserves count.
- Actual recording and overdub refuse edits. Arms and countdown alone allow
  edits. Refusal never stops a track or cancels its existing request.
- Any accepted Count-in edit cancels a running countdown, including same-value
  edits; only a positive Count-in cancels Sound arms. Count-in zero preserves
  an existing Sound arm. Sound true cancels countdown; Sound false cancels Sound
  arms but preserves a nonzero countdown. Restore clears transient requests.
- Sound can be selected before choosing inputs. Actually arming an empty track
  requires a usable selected recording source. Otherwise show the affected
  track and “Choose recording inputs”; create no image, layer or pending arm.

## Ownership and interfaces

TempoCubit owns the pair independently of Hear click, click volume and generic
tempo initialization. Use its existing serial queue, renamed
`runTempoExclusive` everywhere, with no compatibility alias. Lock order remains
Mixer → Tempo → Playback → Record length → Record timing. Stage initialization
reads outside exclusive operations; never enqueue recursively under the gate.

The app's pure `RecordStartSettings` validates count and Sound together.
`RecordStartControl` and `RecordStartSnapshot` live with it in
`lib/looper/model/record_start.dart`; the snapshot is nullable before
initialization or during recovery. A separate
nullable confirmed readout retains the prior choice on page remount. Typed
outcomes distinguish applied, rejected, superseded and recovery-required.
Do not add unused controller/Released arguments before part 3.

SettingsRepository accepts named primitive fields and returns the structural
checkpoint `({int? countInBars, bool? soundStart})`. Validate both raw fields
before mutation. Write and read back both values; compensation restores both
old keys including exact absence. Partial failure or failed compensation must
not overwrite malformed data or be mistaken for successful acceptance.

LooperRepository exposes the confirmed pair and restart intent as structural
records. Its typed setter takes primitive count/Sound and RecordStartEditKind
from the engine package. It provides settlement, failure, recovery and readiness
signals. Neither lower package imports an app-defined type. Remove old scalar
writers once their callers migrate; retain no second cache of desired state.

One native typed command carries the pair, edit kind and revision. Edit kinds
CountIn/Sound/Restore preserve the distinct transient semantics above. Reject
invalid values, a second unpublished request, and raw command-post bypass.
The callback checks capture before any mutation and publishes a result even on
refusal. Use a 64-bit command reservation and the existing 32-bit receipt
revision convention. The coherent packed pair is sampled only after acquired
commands-settled publication; no await or reentrant writer may intervene.
No allocation, locks, I/O or unbounded spinning in the callback.

Persist verified intent, submit native change, then accept its matching receipt.
Known refusal compensates exact storage. Unknown completion or failed rollback
blocks readiness and flush until explicit recovery. A compensated ordinary
refusal does not poison healthy shutdown. Bound autonomous settlement to the
existing 10 ms / 50-attempt pattern; publish readiness even when values match.
Session replacement retires old lifetime obligations. A delayed old read error
must not poison a newer accepted Session; device-only replacement still checks
the saved preference. Configure preserves the accepted pair and resets receipt
reservations before durable replay.

Fresh acquisition is fenced before plugin/image preparation while pair state is
pending or recovering. Owned cancellation, finishing and Stop remain usable.
For no-source Sound, inspect actual routing, exclusions and negotiated input
availability; never substitute channel zero. Native direct callers get the
same no-source refusal. Repository emits one channel-specific repair event;
the app localizes it. A selected-source positive control must genuinely arm
and trigger, proving that the refusal is not a blanket disabled path.

## Integration

Move Recording page, both Audio settings surfaces and the Loop settings hub
summary to Tempo's confirmed pair. Remove RecordOptions.autoRecord and its
setter/load/mirror once the complete caller scan is empty; preserve its separate
record sequence and Record length responsibilities. Any remaining LooperBloc
start-setting event delegates to the same owner and flush barrier.

Startup validates the pair before opening audio and awaits replay on both
start paths. Session capture takes confirmed intent under the Tempo gate;
apply stages one pair and awaits its receipt, never two independent commands.
Shutdown stops Control ingress, flushes owners and offers Retry/Keep playing
on failure. Retry repairs then flushes retiring controls again before halt.
Close Control before Tempo. Pending state cannot falsely satisfy save or halt.

## Tasks and proof

1. Freeze independent literal expectations and negative controls from accepted
   behavior; bind this base and relevant source. Agree the app/repository port.
2. Native writer implements receipt, refusal, direct no-source guard and FFI;
   regenerate bindings. Prove boundaries, freeze an immutable native library.
3. Same runtime owner implements Settings/Looper/Tempo and focused failure tests.
   Coordinator integrates existing surfaces, App, Session and obsolete removal.
   At most two writers, with explicit non-overlapping files.
4. Independent review executes publication, storage, acquisition and lifetime
   cases. Mutants must fail independently stated assertions; preserve red logs.
5. Frozen candidate receives native variants/shim, engine and affected package
   suites, App coverage, fatal-info analysis, explicit formatting and positive
   Bloc lint. Review visuals separately; current-head CI precedes merge readiness.

Acceptance includes both absent keys, mixed absence, explicit Off/Sound,
contradictory storage, first/second write and compensation faults, queue refusal,
same-value timeout, counter rollover and paused callback publication. Sound
without a source must refuse before preparation; selecting a valid source must
arm and respond only to that source. Cancel still works. Test Save/Save As with
actual files, old/new Session lifetimes, no-op value readiness, App Retry and
all four UI surfaces during capture/recovery. No test may derive expected pair
transformations from production helpers.

Non-goals: shared launch scheduler, mappings, Held projections, external-clock
Receive, capture-journal implementation, parallel capture, generic transaction
frameworks, migrations or redesigning unrelated tempo controls.
