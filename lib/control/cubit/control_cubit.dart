import 'dart:async';
import 'dart:developer' as dev;

import 'package:bloc/bloc.dart';
import 'package:controller_repository/controller_repository.dart';
import 'package:equatable/equatable.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:midi_device_repository/midi_device_repository.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:performance_repository/performance_repository.dart';
import 'package:segno/common/fx_chain_persistence.dart';
import 'package:segno/control/binding/binding_scope.dart';
import 'package:segno/control/binding/control_action.dart';
import 'package:segno/control/binding/control_value_resolver.dart';
import 'package:segno/control/binding/control_value_target.dart';
import 'package:segno/control/binding/controller_learn.dart';
import 'package:segno/control/binding/fx_binding_resolver.dart';
import 'package:segno/control/binding/fx_binding_target.dart';
import 'package:segno/control/binding/pedal_binding.dart';
import 'package:segno/control/binding/pedal_binding_set.dart';
import 'package:segno/control/binding/pedal_setup.dart';
import 'package:segno/control/control_projection.dart';
import 'package:segno/logging/app_log.dart';
import 'package:segno/looper/model/interaction_mode.dart';
import 'package:settings_repository/settings_repository.dart';

part 'control_state.dart';

/// The press/long-press state machine every gestural footswitch shares.
///
/// [press] arms a hold timer and remembers the tap action; holding past the
/// threshold runs `onHold` and RETIRES that action, so the matching [release]
/// stays silent. Releasing first runs it instead. Both callbacks are built at
/// press time, so anything a gesture must latch (the undo target channel) is
/// simply captured by the closures — a later on-screen change cannot retarget
/// the action the foot already committed to.
///
/// A gesture whose action fires on the press itself (the FX Stop panic) passes
/// no `onTap`: its release then only retires the pending hold, which is what
/// makes a synthetic release — the on-screen plate note-off'ing a held switch
/// as it leaves the tree — harmless.
///
/// The remembered tap action doubles as the armed flag: a release with nothing
/// pending is inert, so an unmatched release can never fire a stale gesture.
class _HoldGesture {
  Timer? _timer;
  void Function()? _onTap;

  /// The generation this press belongs to. A release is only the end of the
  /// gesture that started it; one carried over from a retired generation —
  /// the pedal was unbound, the mode changed, a take took the lock — is a
  /// stranger and runs nothing.
  int _generation = -1;

  void press({
    required Duration threshold,
    required int generation,
    required void Function() onHold,
    void Function()? onTap,
  }) {
    _onTap = onTap;
    _generation = generation;
    _timer?.cancel();
    _timer = Timer(threshold, () {
      _timer = null;
      _onTap = null; // handled as a hold: the release stays silent
      onHold();
    });
  }

  void release(int generation) {
    if (_generation != generation) {
      cancel();
      return;
    }
    _timer?.cancel();
    _timer = null;
    final onTap = _onTap;
    _onTap = null;
    onTap?.call();
  }

  /// Drops the pending hold and tap without running either.
  void cancel() {
    _timer?.cancel();
    _timer = null;
    _onTap = null;
    _generation = -1;
  }
}

/// Every pending footswitch gesture, so there is ONE place that retires them
/// all (accepted design, controls 3: "Cancel pending gestures on invalidating
/// navigation, disconnect or configuration").
///
/// Before this, each gestural switch owned a field of its own and nothing
/// could reach them together: unbinding the pedal released held momentaries
/// but left the hold timers armed to fire into a rig that no longer had a
/// pedal on it, and a press taken before a take locked the transport still
/// ran its latched tap when the foot came up.
///
/// [generation] is what makes a cancel stick. A pending hold can be dropped by
/// cancelling its timer, but a release already on its way cannot; bumping the
/// generation makes every gesture pressed before the cancel a stranger, so the
/// release that arrives after it runs nothing.
class _Gestures {
  final Map<PedalButton, _HoldGesture> _byButton = {};
  int _generation = 0;

  /// The generation a press starting now belongs to.
  int get generation => _generation;

  /// The gesture for [button], created on first use.
  _HoldGesture of(PedalButton button) =>
      _byButton.putIfAbsent(button, _HoldGesture.new);

  /// Ends [button]'s gesture, running its tap unless the gesture has been
  /// retired since the press.
  void release(PedalButton button) => _byButton[button]?.release(_generation);

  /// Drops every pending gesture without running it, and retires the
  /// generation so a release still in flight is ignored too.
  void cancelAll() {
    _generation++;
    for (final gesture in _byButton.values) {
      gesture.cancel();
    }
  }
}

/// The ONE control-surface interpreter and the ONE owner of stored user
/// intent ([ControlState]) — a single business-logic-layer unit, per the
/// layered architecture: repositories are composed at the bloc level, so
/// there is no domain-service orphan between the repositories and the blocs,
/// and no cubit ever depends on another cubit.
///
/// Inputs arrive only through repository streams and its own methods:
/// - `LooperRepository.looperState` drives [_reduce] — the invalidation
///   table every stored bit obeys (cursor clamps; excluded/parkedResume
///   members drop when their track empties) — plus the loop-top pulse and
///   the frame re-projection.
/// - `PedalRepository.events` delivers the decoded footswitches, which call
///   the SAME intent methods the keyboard and on-screen widgets call — the
///   surfaces cannot diverge in the command sequences they issue.
///
/// Outputs leave only through repositories: engine commands via
/// [LooperRepository], and the projected LED frame (`projectFrame`, a pure
/// function of `(LooperState × ControlState)`) diff-pushed via
/// [PedalRepository]. Derived state is never stored, so it can never go
/// stale.
class ControlCubit extends Cubit<ControlState> {
  /// Creates a [ControlCubit] over the shared repositories.
  ///
  /// [performance] backs the MODE-footswitch long-press gesture
  /// (arm/disarm performance recording, D-PEDAL) and the clear-while-armed
  /// persist-before-clear ordering — composed here rather than routed
  /// through `PerformanceRecorderCubit`, since cubits never call cubits;
  /// that cubit observes this repository's own status stream, so it reflects
  /// a pedal-triggered arm/disarm too.
  ///
  /// [currentChains] resolves the live lane/monitor chains + master-limiter
  /// state to stamp into the arm snapshot, read fresh at each arm — the same
  /// narrow function dependency `PerformanceRecorderCubit` takes for the
  /// toolbar path, so both arm gestures record the same rig. It is injected
  /// rather than mapped here: the mapping lives in the session feature, and a
  /// feature never imports another feature. Defaults to the empty snapshot
  /// (what this call site passed before it was wired).
  /// [controller] is the external-MIDI seam (part 7): its resolved binding
  /// events land at the same dispatch point the pedal's do, so a discrete CC
  /// stomps exactly like a footswitch. [midiDevices] supplies the connectivity
  /// this cubit needs to honour the release-all rule when the MIDI source
  /// itself disappears (B1). Both are optional — a build or test with no MIDI
  /// seam simply never receives external control.
  ///
  /// [simulatedSource] is the push seam that lets a mapping prove itself with
  /// no controller attached (#519): the same source the repository carries in
  /// its `sources` list, so a synthetic sweep/press enters exactly where a real
  /// CC would. [simulateTick] / [simulateSweepLeg] pace that synthetic sweep.
  ///
  /// [takeLocked] suppresses Rec / overdub / perf-arm while the power-off
  /// route is up, so a take cannot start behind the dialog.
  ControlCubit({
    required LooperRepository looper,
    required PedalRepository pedal,
    required SettingsRepository settings,
    required PerformanceRepository performance,
    ControllerRepository? controller,
    MidiDeviceRepository? midiDevices,
    SimulatedControllerSource? simulatedSource,
    Duration keepAliveInterval = const Duration(seconds: 1),
    Duration learnTimeout = const Duration(seconds: 15),
    Duration mappingsWriteDebounce = const Duration(milliseconds: 400),
    Duration simulateTick = const Duration(milliseconds: 60),
    Duration simulateSweepLeg = const Duration(milliseconds: 1500),
    PerformanceChains Function() currentChains = _noChains,
    bool Function() takeLocked = _neverLocked,
  }) : _looper = looper,
       _pedal = pedal,
       _settings = settings,
       _performance = performance,
       _controller = controller,
       _simulatedSource = simulatedSource,
       _learnTimeout = learnTimeout,
       _mappingsWriteDebounce = mappingsWriteDebounce,
       _simulateTick = simulateTick,
       _simulateSweepLeg = simulateSweepLeg,
       _currentChains = currentChains,
       _takeLocked = takeLocked,
       super(const ControlState()) {
    _looperSub = _looper.looperState.listen(_onLooperState);
    _eventsSub = _pedal.events.listen(_handleEvent);
    _statusSub = _pedal.statusChanges.listen(_onBindStatus);
    _perfStatusSub = _performance.captureStatus.listen(_onPerformanceStatus);
    _bindingSub = controller?.bindingEvents.listen(_onControllerBindingEvent);
    _midiSub = midiDevices?.connections.listen(_onMidiConnection);
    // Re-push the current frame on a slow heartbeat so the pedal can tell a
    // live link (frames still arriving) from a dropped one (USB unplugged / app
    // closed) and blank its LEDs. Only on-change pushes happen otherwise, so a
    // stopped, idle loop would look identical to a dead link without this.
    // Pass Duration.zero to disable (tests drive frames explicitly).
    if (keepAliveInterval > Duration.zero) {
      _keepAliveTimer = Timer.periodic(
        keepAliveInterval,
        (_) => _pushProjected(force: true),
      );
    }
  }

  /// The default `currentChains`: an empty rig, which is what
  /// [PerformanceRepository.arm] already assumes when given nothing.
  static PerformanceChains _noChains() => const PerformanceChains();

  static bool _neverLocked() => false;

  final LooperRepository _looper;
  final PedalRepository _pedal;
  final SettingsRepository _settings;
  final PerformanceRepository _performance;
  final ControllerRepository? _controller;

  /// The seam a synthetic controller event is pushed through (#519). The same
  /// object the repository carries in its `sources` list, so a simulated input
  /// is indistinguishable from a real one downstream. Null in a build/test with
  /// no simulation wired — [simulateMapping] and [simulateStatusRow] are then
  /// inert.
  final SimulatedControllerSource? _simulatedSource;
  final Duration _learnTimeout;
  final Duration _mappingsWriteDebounce;

  /// The cadence a simulated sweep advances on, and how long each LO→HI (and
  /// HI→LO) leg takes — the pen's "slow enough to watch". Injected like the
  /// repository's own smoothing durations, so tests drive the sweep under a
  /// fake clock instead of sleeping.
  final Duration _simulateTick;
  final Duration _simulateSweepLeg;
  final PerformanceChains Function() _currentChains;
  final bool Function() _takeLocked;

  late final StreamSubscription<LooperState> _looperSub;
  late final StreamSubscription<PedalEvent> _eventsSub;
  late final StreamSubscription<PedalBindStatus> _statusSub;
  late final StreamSubscription<PerformanceCaptureStatus> _perfStatusSub;
  StreamSubscription<ControllerBindingEvent>? _bindingSub;
  StreamSubscription<MidiConnection>? _midiSub;

  // Encoder accumulator: the engine exposes no master-gain read-back, so the
  // control layer tracks the value it last sent (unity until the first turn).
  static const double _encoderStep = 1 / 64;
  double _masterGain = 1;

  // The ONE hold threshold every gesture below arms with — undo/redo, the
  // MODE pair, the Rec/Play and track holds, the Stop restore and every bound
  // hold all share it — read at press time so a settings change lands on the
  // next stomp. Persisted as `pedal.long_press_ms`; 500 ms until the user
  // tunes it. One plate, one meaning of "held", whatever the hold does on
  // that switch.
  Duration _longPress = const Duration(milliseconds: 500);
  Timer? _keepAliveTimer;

  // Every pending footswitch gesture, and the one place that retires them
  // all. The four system gestures below and every bound button's own live in
  // here, keyed by the switch they are on.
  //
  // - Undo: tap = undo, long-press = redo. The target channel is LATCHED at
  //   press time (captured by the callbacks) — an on-screen click mid-hold
  //   must not retarget the action the foot already committed to.
  // - MODE: the setup's own pair — tap enters `modePress`, hold enters
  //   `modeHold`, and either leaves that mode when the rig is already in it.
  //   Armed as a gesture only while a hold IS assigned; with none, the press
  //   acts on contact like any other plain switch.
  // - Rec/Play and the four track switches: the press acts on CONTACT and the
  //   hold is layered on top, so neither loses the immediate-contact
  //   behaviour the accepted design pins them to.
  // - The FX-mode Stop long-press (restore every Track chain). The panic half
  //   fires on the press, so that one arms no tap action — only the hold.
  //
  // BANK arms nothing: it pages the plate and nothing else.
  final _gestures = _Gestures();

  // The remap (part 6b) lives in ControlState — it is stored user intent, and
  // the surfaces that render it rebuild on emit. What stays here is only the
  // mid-gesture restore VALUES: the enabled state each held press captured,
  // which no surface renders and which must not survive a hot restart.
  //
  // Keyed by [PedalBindingKey] rather than by target, so two bindings on one
  // target each restore what THEY captured (last writer wins, per
  // [PedalBinding]'s doc). A button can only be held once, so the key is
  // unique for the lifetime of a press. Kept in lockstep with
  // `state.heldMomentary`, which is the same key set.
  final _heldRestore =
      <PedalBindingKey, ({FxBindingTarget target, bool prior})>{};

  // The mid-gesture restore values for MOMENTARY bindings held from an
  // external MIDI control: one entry per TARGET, carrying the state the first
  // press found and the set of controls currently holding it.
  //
  // Reference-counted rather than one slot per control, because two switches
  // can be mapped to one chain. A per-control capture would have the second
  // press record the state the FIRST press just enabled, and its release would
  // then write `true` back with no foot on either switch — a stuck momentary.
  // A per-target slot alone would let the first release end the second's hold.
  // Holding the first press's capture until the LAST control lets go is the
  // only reading with no stranded state and no early release.
  //
  // Kept apart from `_heldRestore` because their release-all triggers differ: a
  // MIDI momentary survives a mode change (external control is not mode-gated)
  // but must release when its device unplugs, which the pedal's own held
  // presses have no reason to care about.
  final _heldControllerRestore =
      <
        String,
        ({FxBindingTarget target, bool prior, Set<MappingTrigger> holders})
      >{};

  // The learn capture's timeout. A capture that nobody ever feeds must not
  // leave the MIDI stream swallowed forever — the repository suppresses ALL
  // events while learning.
  Timer? _learnTimer;

  // A simulation in flight (#519): the control its synthetic events target, the
  // values still to push (one per [_simulateTick]), and the ticker draining
  // them. One at a time — a new simulation drains the last so a switch's
  // release edge is never stranded, leaving a momentary enabled with no foot
  // on it (the same B1 hazard the release-all rule guards).
  MappingTrigger? _simulateTrigger;
  final List<int> _simulateQueue = [];
  Timer? _simulateTimer;

  // Which capture is current. Every `learnNext` future resolves — including
  // the null a SUPERSEDED one gets when the next capture replaces it — so a
  // callback has to prove it still speaks for the capture in flight. Without
  // that proof a stale null tore down the live capture's state and timeout
  // while the repository went on swallowing every controller event.
  int _learnGeneration = 0;

  // The mapping blob's pending write. A LO/HI knob reports continuously while
  // it is dragged, so the STATE and the repository follow every frame (the
  // sound has to track the finger) while the settings write is coalesced —
  // otherwise one drag costs ~60 JSON encodes and store writes a second.
  // Flushed by `close()`, so a quit mid-drag still persists.
  Timer? _mappingsWriteTimer;
  String? _pendingMappingsBlob;

  // Every controller binding's target, decoded ONCE per mapping-set change.
  // The dispatch path runs per smoothing tick, and re-parsing a canonical-JSON
  // string that only changes on an edit is pure waste on the hot path. A target
  // that does not decode is absent here, which reads as the same no-op a stale
  // one gets.
  final _controllerValueTargets = <String, ControlValueTarget>{};
  final _controllerSwitchTargets = <String, FxBindingTarget>{};

  // Whether the Clear footswitch is currently held down. Lights the Clear
  // LED (the `clearFadeActive` frame bit) for as long as it is pressed.
  bool _clearHeld = false;

  // Mirrors `PerformanceRepository.captureStatus` so the pedal frame can
  // render the armed LED without re-deriving it from the raw status stream on
  // every projection. Independent of `ControlState` (nothing routes through
  // stored intent), so a status change re-projects directly rather than
  // through `emit`.
  bool _performanceArmed = false;

  // Latest looper snapshot + diff state for the frame push.
  LooperState? _looperState;
  PedalStateFrame? _lastFrame;
  int? _lastPosition;

  Future<void>? _loadFuture;

  List<Track> get _tracks => _l.tracks;

  /// The looper truth every intent method reads: the last POLLED snapshot —
  /// the SAME one the frame projection and the invariant spec are defined
  /// over. `LooperRepository.state` is a live engine read; deciding intent
  /// from it while projecting from the polled copy let the two skew inside
  /// one emit whenever an engine change landed between polls (e.g. a record
  /// starting right before a mode toggle), tripping the projection-time
  /// invariant assert. Live read only before the first poll arrives.
  LooperState get _l => _looperState ?? _looper.state;

  Track? _trackAt(int channel) =>
      channel >= 0 && channel < _tracks.length ? _tracks[channel] : null;

  /// A track that exists and holds (or is finishing) a loop.
  bool _playable(Track? track) =>
      track != null && (track.hasContent || track.isCapturing);

  /// Content tracks whose playhead is RUNNING (playing or overdubbing),
  /// mute-ignored — what a park must freeze, and what it resumes.
  Set<int> _running() => {
    for (final t in _tracks)
      if (t.hasContent &&
          (t.state == TrackState.playing || t.state == TrackState.overdubbing))
        t.channel,
  };

  /// Restores the persisted boot-default mode (applying it — a `mute`
  /// default runs the same entry side effects as a live toggle) and the
  /// undo long-press threshold.
  Future<void> load() => _loadFuture ??= _restore();

  Future<void> _restore() async {
    _longPress = Duration(milliseconds: await _settings.loadPedalLongPressMs());
    final storedBindings = PedalBindingSet.decode(
      await _settings.loadPedalBindings() ?? '',
    );
    final storedControllerBindings = ControllerBindingSet.decode(
      await _settings.loadControllerMappings() ?? '',
    );
    // bootDefaultFromToken, not fromToken: a stored `'fx'` (hand-edited or
    // corrupted — no build writes it) falls back to record rather than booting
    // the dead FX surface (R12).
    final defaultMode = InteractionMode.bootDefaultFromToken(
      await _settings.loadDefaultInteractionMode(),
    );
    final setup = PedalSetup.decode(await _settings.loadPedalSetup() ?? '');
    if (isClosed) return;
    // The repository resolves inputs against the set, so it has to learn the
    // restored mappings too — otherwise external control stays dead until the
    // user happens to edit a row.
    _controller?.setBindings(storedControllerBindings);
    _cacheControllerTargets(storedControllerBindings);
    emit(
      state.copyWith(
        defaultMode: defaultMode,
        pedalSetup: setup,
        globalBindings: storedBindings,
        controllerBindings: storedControllerBindings,
      ),
    );
    setMode(defaultMode);
  }

  // ---------------------------------------------------------------------------
  // The looper reducer: the stored-intent invalidation table.
  // ---------------------------------------------------------------------------

  void _reduce(LooperState looper) {
    var next = state;

    // Cursor: always a valid channel.
    if (looper.tracks.isNotEmpty &&
        (state.cursor < 0 || state.cursor >= looper.tracks.length)) {
      final cursor = state.cursor.clamp(0, looper.tracks.length - 1);
      next = next.copyWith(
        cursor: cursor,
        activeBank: cursor ~/ ControlState.tracksPerBank,
      );
    }

    // Excluded / parkedResume: membership requires a track that still holds
    // (or is finishing) a loop. An emptied track (undo-to-empty, clear,
    // clear-all, session load) drops out, so no stored set can reference a
    // ghost.
    bool playable(int channel) {
      if (channel < 0 || channel >= looper.tracks.length) return false;
      final t = looper.tracks[channel];
      return t.hasContent || t.isCapturing;
    }

    if (state.excluded.any((c) => !playable(c))) {
      next = next.copyWith(excluded: state.excluded.where(playable).toSet());
    }
    if (state.parkedResume.any((c) => !playable(c))) {
      next = next.copyWith(
        parkedResume: state.parkedResume.where(playable).toSet(),
      );
    }

    if (next != state) emit(next);
  }

  // ---------------------------------------------------------------------------
  // Mode
  // ---------------------------------------------------------------------------

  /// Cycles Record -> Mute -> FX -> Record — the keyboard's `M` and the
  /// on-screen mode chip.
  ///
  /// A three-stop cycle, not a toggle: FX mode joins the same MODE footswitch
  /// rather than claiming a switch the hardware does not have. Side effects
  /// fire for the LANDED mode only — cycling PAST a mode never runs its entry
  /// work (A5), which falls out of [setMode] being the single entry point.
  ///
  /// Deliberately NOT driven by the pedal setup: that pair governs the
  /// PEDAL's MODE switch, which has a hold. The keyboard and the chip have no
  /// hold equivalent, so a setup that put FX behind the pedal's hold would
  /// leave FX unreachable from them the moment the pedal is unplugged.
  void toggleMode() => setMode(switch (state.mode) {
    InteractionMode.record => InteractionMode.mute,
    InteractionMode.mute => InteractionMode.fx,
    InteractionMode.fx => InteractionMode.custom,
    InteractionMode.custom => InteractionMode.record,
  });

  /// Replaces the built-in footswitch setup and persists it — the Pedals
  /// screen's Save.
  ///
  /// Effective on the next press, and it leaves the live mode where it is:
  /// the setup says what the switches MEAN, never which mode the rig is in.
  Future<void> setPedalSetup(PedalSetup setup) async {
    if (setup == state.pedalSetup) return;
    // Configuration: half the plate can mean something different on either
    // side of this, so a gesture pressed under the old setup must not finish
    // under the new one.
    _invalidateGestures();
    emit(state.copyWith(pedalSetup: setup));
    await _settings.savePedalSetup(setup.encode());
  }

  /// Applies [next] with its entry side effects; a no-op when already there.
  ///
  /// Entering Mute previews the whole content set: `parkedResume` = every
  /// track holding (or capturing) a loop, so Rec/Play resumes them all and
  /// the parked LEDs show it — including stopped and muted tracks, which
  /// pure `sounding` could never cover. A live capture survives THIS entry:
  /// the mode toggle is a view change, not a transport action.
  ///
  /// Entering FX cancels every PENDING record arm — quantized, sound-armed,
  /// or a Band section toggle. An arm is the one thing that could start a take
  /// the user never sees: it fires on its own, seconds later, in a mode whose
  /// transport controls are all inert. The cancel is unconditional
  /// (`LooperRepository.cancelArm`), so no engine setting can turn it into a
  /// press with different meaning.
  ///
  /// Entering FX then ENDS every live non-defining capture at the entry
  /// gesture (#405, `LooperRepository.finalizeTake`): the engine's immediate
  /// finalize ends the take exactly as a quantize-off record press would —
  /// rounded up to whole base loops, the tail staying silence, never
  /// off-grid — instead of letting a forgotten take grow toward the
  /// recording cap in a mode whose transport controls are all inert. (A
  /// record press could never do this: under quantize it ARMS a loop-top
  /// finalize instead — the withdrawn A5 attempt.) The DEFINING take — the
  /// one establishing the loop length — is the exception: the engine REFUSES
  /// it, because a mode switch must not be the gesture that sets the
  /// session's bar length, and the refusal is silently accepted — that
  /// capture survives into FX exactly as it survives Mute, ending when the
  /// user cycles back to Rec. A count-in in progress is aborted outright
  /// (nothing has been captured yet). Overdubs are out of scope: bounded and
  /// cycling, they ride on under FX exactly as under Mute.
  ///
  /// Any mode entry clears the stored mute-mode intent (the invalidation
  /// table).
  void setMode(InteractionMode next) {
    if (next == state.mode) return;
    // Leaving the mode the bindings live in strands any held momentary — the
    // release will arrive with the foot in a mode that no longer dispatches
    // it, or not at all. Restore first (B1), before the emit re-projects, and
    // retire the pending gestures with it: a hold that opened this mode must
    // not also act again when the foot comes up in it.
    _invalidateGestures();
    switch (next) {
      case InteractionMode.record:
        emit(
          state.copyWith(
            mode: InteractionMode.record,
            excluded: const <int>{},
            parkedResume: const <int>{},
          ),
        );
      case InteractionMode.mute:
        emit(
          state.copyWith(
            mode: InteractionMode.mute,
            excluded: const <int>{},
            parkedResume: {
              for (final track in _tracks)
                if (_playable(track)) track.channel,
            },
          ),
        );
      case InteractionMode.custom:
        // No entry side effects of its own. Custom mode changes what the
        // SWITCHES mean and nothing else — it arms nothing, cancels nothing
        // and moves no transport, so there is nothing here for a mode
        // change to undo later.
        emit(
          state.copyWith(
            mode: InteractionMode.custom,
            excluded: const <int>{},
            parkedResume: const <int>{},
          ),
        );
      case InteractionMode.fx:
        // Cancel arms BEFORE the emit so the projection that rides it already
        // describes the post-entry intent (the engine's own state follows one
        // poll later, as it does for every other command).
        //
        // Read LIVE engine truth, not the polled snapshot: an arm cancelled or
        // fired moments ago still reads `pending` for up to one poll, and the
        // cancel is cheap enough that a stale read costs only a no-op.
        final looper = _looper.state;
        for (final track in looper.tracks) {
          if (track.pending) _looper.cancelArm(channel: track.channel);
        }
        // Then end every live non-defining take at the entry gesture (#405).
        // AFTER the arm sweep by construction: the primitive refuses while a
        // pending arm is live on the channel, and the sweep is what retires
        // them. Refusals are silently accepted — that IS the defining-take
        // fallback (the capture survives, as documented above). RECORDING
        // only: an overdub rides on, exactly as under Mute.
        if (looper.transport.countingIn) {
          // A count-in is global transport state (no track is capturing yet),
          // so the addressed channel is irrelevant — any channel cancels it.
          _looper.finalizeTake(channel: 0);
        }
        for (final track in looper.tracks) {
          if (track.state == TrackState.recording) {
            _looper.finalizeTake(channel: track.channel);
          }
        }
        emit(
          state.copyWith(
            mode: InteractionMode.fx,
            excluded: const <int>{},
            parkedResume: const <int>{},
          ),
        );
    }
  }

  /// Sets and persists the default [mode] the system boots into, applying it
  /// to the live mode now.
  ///
  /// Ignores a mode outside [InteractionMode.bootDefaults] (R12): the settings
  /// picker never offers FX, and a boot into FX with no chains configured is a
  /// dead surface.
  Future<void> setDefaultMode(InteractionMode mode) async {
    // Loud in debug, defensive in release: a caller offering FX here has a
    // bug, but shipping a dead boot surface is the worse outcome.
    assert(
      InteractionMode.bootDefaults.contains(mode),
      '$mode is not a boot-eligible default mode',
    );
    if (!InteractionMode.bootDefaults.contains(mode)) return;
    emit(state.copyWith(defaultMode: mode));
    setMode(mode);
    await _settings.saveDefaultInteractionMode(mode.token);
  }

  // ---------------------------------------------------------------------------
  // Cursor / bank
  // ---------------------------------------------------------------------------

  /// Moves the shared cursor to [channel], following it into its bank (a
  /// cursor can never hide behind the other bank).
  void selectTrack(int channel) {
    if (channel < 0 || channel >= _channelCount) return;
    emit(
      state.copyWith(
        cursor: channel,
        activeBank: channel ~/ ControlState.tracksPerBank,
      ),
    );
  }

  /// Reveals [bank] WITHOUT moving the cursor — the browse flow (e.g. arming
  /// the other bank's tracks in mute mode).
  void browseBank(int bank) {
    if (bank < 0 || bank >= ControlState.bankCount) return;
    emit(state.copyWith(activeBank: bank));
  }

  /// Toggles the visible bank, moving the cursor to the new bank's first
  /// track — the pedal BANK footswitch / keyboard `B` semantics.
  void toggleBankWithCursor() =>
      selectTrack((state.activeBank == 0 ? 1 : 0) * ControlState.tracksPerBank);

  // ---------------------------------------------------------------------------
  // Rec/Play
  // ---------------------------------------------------------------------------

  /// The Rec/Play action under the current mode.
  ///
  /// INERT in FX mode (A4): the "act on the focused track" reading was
  /// rejected — focus has no on-pedal indicator, so an invisible target would
  /// be mis-stomped. The switch is reserved for a later part rather than given
  /// a guessable meaning.
  void recPlay() {
    if (_takeLocked()) return;
    switch (state.mode) {
      case InteractionMode.record:
        _recAdvance(state.cursor);
      case InteractionMode.mute:
        _muteRecPlay();
      case InteractionMode.fx:
      case InteractionMode.custom:
        // Inert. In FX the switch is reserved (A4); in custom it runs
        // whatever the setup assigned, dispatched at the press rather than
        // here, so this path must not also act.
        break;
    }
  }

  /// Rec mode: advance the cursor track through record / overdub / play. A
  /// muted track is first unmuted and brought back: overdub if its loop still
  /// runs, plain resume if it was parked (the engine unparks the rest of the
  /// loop with it — starting anything resumes everything).
  void _recAdvance(int channel) {
    final track = _trackAt(channel);
    if (track != null && track.muted) {
      _looper.setMute(muted: false, channel: channel);
      if (track.state == TrackState.stopped) {
        _looper.play(channel: channel); // parked -> resume, no overdub
      } else {
        _looper.record(channel: channel); // running -> unmute + overdub
      }
      return;
    }
    // The engine's cycling record() walks empty -> record, capturing -> play
    // (finalize), playing -> overdub.
    _looper.record(channel: channel);
  }

  /// Mute mode Rec/Play: resume while parked; while running, expand to the
  /// whole content set (a no-op when everything audible is already in).
  void _muteRecPlay() {
    if (isParked(_l)) {
      final resume = state.parkedResume.isNotEmpty
          ? state.parkedResume
          : {
              for (final track in _tracks)
                if (_playable(track)) track.channel,
            };
      if (resume.isEmpty) return; // nothing recorded yet
      // The engine unparks the ENTIRE loop on the first play (starting
      // anything resumes everything), so a deselected member must be muted
      // BEFORE any play rides the ring: it comes back running-but-silent —
      // exactly what its dark parked LED promised — and stays in phase for a
      // later unmute, instead of staying frozen. A CAPTURING track is not a
      // deselected member — it is a live take (isParked ignores `recording`,
      // so one can be running under a parked transport) and muting it would
      // punch it out; leave it alone.
      for (final track in _tracks) {
        if (_playable(track) &&
            !track.isCapturing &&
            !resume.contains(track.channel) &&
            !track.muted) {
          _looper.setMute(muted: true, channel: track.channel);
        }
      }
      for (final channel in resume) {
        _looper
          ..setMute(muted: false, channel: channel)
          ..play(channel: channel);
      }
      // Consumed: the resumed tracks are now sounding, so the derived armed
      // set carries them from here.
      emit(state.copyWith(parkedResume: const <int>{}));
      return;
    }
    // Running: expand to every content track unless the full audible set is
    // already in the mix (then the press is a no-op).
    final armed = armedTracks(_l, state);
    final all = {
      for (final track in _tracks)
        if (track.hasContent) track.channel,
    };
    final anyAudible = _tracks.any(
      (t) => armed.contains(t.channel) && !t.muted && isSounding(t),
    );
    if (anyAudible && armed.containsAll(all)) return;
    for (final channel in all) {
      _looper
        ..setMute(muted: false, channel: channel)
        ..play(channel: channel);
    }
  }

  // ---------------------------------------------------------------------------
  // Stop
  // ---------------------------------------------------------------------------

  /// The Stop action under the current mode (the pedal's Stop TAP; its
  /// long-press is [restoreAllTrackChains], handled at the press/release
  /// layer like undo/redo's).
  void stop() {
    switch (state.mode) {
      case InteractionMode.record:
        _recStop(state.cursor);
      case InteractionMode.mute:
        parkAll();
      case InteractionMode.fx:
        panicTrackChains();
      case InteractionMode.custom:
        // Inert here: the switch runs its assignment at the press.
        break;
    }
  }

  /// Rec mode: mute the cursor track (finalizing a capture first). Muting the
  /// only audible loop parks the whole transport.
  void _recStop(int channel) {
    final track = _trackAt(channel);
    if (track == null) return;
    if (track.isCapturing) _looper.record(channel: channel); // finalize first
    _looper.setMute(muted: true, channel: channel);
    if (track.state == TrackState.playing && _isLastAudibleTrack(channel)) {
      for (final t in _tracks) {
        _looper.stopTrack(channel: t.channel);
      }
    }
  }

  /// Parks the play transport: freezes EVERY running content track (muted
  /// ones too — mute silences, park freezes) and latches what Rec/Play brings
  /// back at INTENT time, before engine truth catches up with the stops.
  void parkAll() {
    final running = _running();
    if (running.isEmpty) return; // already parked: keep the resume set
    emit(
      state.copyWith(
        parkedResume: {...running}..removeWhere(state.excluded.contains),
      ),
    );
    for (final channel in running) {
      _looper.stopTrack(channel: channel);
    }
  }

  // ---------------------------------------------------------------------------
  // Track buttons (pedal semantics)
  // ---------------------------------------------------------------------------

  /// A track-button press on [channel] under the current mode — the pedal's
  /// footswitch semantics.
  void trackPressed(int channel) {
    if (state.mode == InteractionMode.record && _takeLocked()) return;
    switch (state.mode) {
      case InteractionMode.record:
        _recTrackPressed(channel);
      case InteractionMode.mute:
        _muteTrackPressed(channel);
      case InteractionMode.fx:
        toggleTrackChain(channel);
      case InteractionMode.custom:
        // Inert here: the switch runs its assignment at the press. Note the
        // on-screen surfaces still call this — selection happens at their
        // own call sites, so a tile tap in custom mode selects and stops.
        break;
    }
  }

  /// Rec mode: select the track, or hand off a live recording to it.
  void _recTrackPressed(int channel) {
    final capturing = _capturingChannel();
    if (capturing == null) {
      selectTrack(channel);
    } else if (capturing == channel) {
      _looper.record(channel: channel); // finish the loop
    } else {
      _looper
        ..record(channel: capturing) // finalize the running capture
        ..record(channel: channel); // start the pressed one
      selectTrack(channel);
    }
  }

  /// Mute mode: while parked, toggle resume membership (arming a muted track
  /// unmutes it so it reads green). While running, a live track toggles its
  /// mute — muting the last audible one parks everything with an empty
  /// resume set (Rec/Play then brings back ALL content) — and a track out of
  /// the mix joins it (un-exclude, unmute, play).
  void _muteTrackPressed(int channel) {
    final track = _trackAt(channel);
    if (!_playable(track)) return;
    final t = track!;
    if (isParked(_l)) {
      if (!state.parkedResume.contains(channel) && t.muted) {
        _looper.setMute(muted: false, channel: channel);
      }
      final next = {...state.parkedResume};
      if (!next.remove(channel)) next.add(channel);
      emit(state.copyWith(parkedResume: next));
      return;
    }
    final live =
        armedTracks(_l, state).contains(channel) &&
        t.state == TrackState.playing;
    if (live) {
      final muting = !t.muted;
      _looper.setMute(muted: muting, channel: channel);
      if (muting && _isLastAudibleArmed(channel)) {
        // Muting the last audible track parks the loop with nothing latched:
        // the next Rec/Play resumes the whole content set.
        for (final c in _running()) {
          _looper.stopTrack(channel: c);
        }
        emit(state.copyWith(parkedResume: const <int>{}));
      }
    } else {
      // Joining is the explicit un-exclude.
      if (state.excluded.contains(channel)) {
        emit(
          state.copyWith(excluded: {...state.excluded}..remove(channel)),
        );
      }
      _looper
        ..setMute(muted: false, channel: channel)
        ..play(channel: channel);
    }
  }

  // ---------------------------------------------------------------------------
  // FX mode (Track-stage chains)
  // ---------------------------------------------------------------------------

  /// Toggles track [channel]'s Track-stage chain (FX mode's track-button
  /// action, shared with the keyboard's digit keys).
  ///
  /// Per-CHAIN, not per-effect: a stomp is a whole-chain bypass (R15,
  /// "disabled == dry through the bus"); per-effect bits and remapped
  /// bindings are a later part.
  void toggleTrackChain(int channel) {
    if (channel < 0 || channel >= _channelCount) return;
    _setTrackChain(channel, enabled: !_looper.trackChainEnabled(channel));
  }

  /// FX panic: every Track-stage chain off in one gesture (Stop in FX mode) —
  /// the eyes-free way out of a chain that has run away mid-song. Restored by
  /// [restoreAllTrackChains] (Stop long-press).
  void panicTrackChains() => _sweepTrackChains(enabled: false);

  /// Puts every Track-stage chain back on (Stop LONG-PRESS in FX mode) — the
  /// undo for [panicTrackChains]. Deliberately "all on" rather than a restore
  /// of the pre-panic pattern: eyes-free on a dark stage, a known end state
  /// beats one the performer has to remember.
  void restoreAllTrackChains() => _sweepTrackChains(enabled: true);

  /// Flips Track-stage chains across every channel, ASYMMETRICALLY on empties.
  ///
  /// Disabling skips a track with no chain: its flag says nothing audible
  /// either way, and writing it would persist a bypass the boot restore
  /// replays forever, silently muting the effects the user adds to that track
  /// later. Skipping also keeps one Stop stomp proportional to the rig — the
  /// repository re-snapshots the engine and re-emits per call, so sweeping all
  /// eight channels cost eight engine snapshots, pedal frames and settings
  /// writes for a rig that usually has one or two chains.
  ///
  /// ENABLING sweeps everything, empties included. Clearing a bypass is always
  /// safe, and a chain-less track can genuinely be carrying a stale one — the
  /// FX dock can disable a chain and then empty it — which is exactly the
  /// silent-dry state this restore exists to undo. A "restore all" that could
  /// not reach it would leave the only pedal-side cure unreachable.
  void _sweepTrackChains({required bool enabled}) {
    for (var channel = 0; channel < _channelCount; channel++) {
      if (!enabled && _looper.trackEffects(channel).isEmpty) continue;
      _setTrackChain(channel, enabled: enabled);
    }
  }

  /// Applies one Track-chain flag and persists the envelope, skipping a no-op
  /// so a panic over already-off chains costs no settings writes.
  ///
  /// Reads the repository's remembered intent rather than the polled
  /// [LooperState]: chain-enabled is set synchronously here (no engine
  /// round-trip), so two fast stomps must not both see the same pre-poll
  /// value. The LEDs still follow the polled snapshot, exactly like mute.
  void _setTrackChain(int channel, {required bool enabled}) {
    if (_looper.trackChainEnabled(channel) == enabled) return;
    _looper.setTrackChainEnabled(channel: channel, enabled: enabled);
    // The same envelope `LooperBloc` writes for the on-screen path — a cubit
    // never calls a bloc, so both call the shared helper instead of one
    // routing through the other.
    persistTrackFxChain(settings: _settings, looper: _looper, channel: channel);
  }

  // ---------------------------------------------------------------------------
  // Clear-all / undo / redo / encoder
  // ---------------------------------------------------------------------------

  /// The whole-rig reset, unified across surfaces: every track holding
  /// content OR a redo history is cleared and re-armed (unmuted, persisted),
  /// and the overlay returns home (record mode, cursor 0). Undone-to-empty
  /// tracks must be included — only clear wipes their resurrect path, and the
  /// master grid resets once everything is empty.
  ///
  /// While performance recording is armed (D-CLEAR), awaits
  /// [PerformanceRepository.persistLiveLanes] first: a track mid-capture is
  /// frozen and erased by the engine clear below (its take stays restorable),
  /// so its performance-recording bundle would otherwise lose that pass
  /// entirely rather than the persisted-then-cleared PCM the repository
  /// itself already knows how to skip.
  Future<void> clearAll() async {
    if (_performanceArmed) await _performance.persistLiveLanes();
    // Whether any track we cleared held content: only a content clear leaves a
    // restore point behind (an undone-to-empty redo-only track's does not), so
    // this is the gate on offering whole-rig undo below.
    var restorable = false;
    final cleared = <int>[];
    for (final track in _tracks) {
      if (!track.hasContent && !track.canRedo) continue;
      if (track.hasContent) restorable = true;
      cleared.add(track.channel);
    }
    // One grouped edit (accepted design, slice 2): the repository remembers
    // the group, so the next Undo on any member restores every member.
    _looper.clearAll(cleared);
    for (final track in _tracks) {
      if (!cleared.contains(track.channel)) continue;
      _looper.setMute(muted: false, channel: track.channel);
      final lanes = track.lanes.isEmpty ? 1 : track.lanes.length;
      for (var lane = 0; lane < lanes; lane++) {
        unawaited(
          _settings.saveLaneMute(track.channel, lane, muted: false),
        );
      }
    }
    // The persist above is an await, so the surface may have been torn down
    // while it ran. The engine clear still happens — it is what the user asked
    // for and the looper outlives this cubit — but the overlay state and the
    // LED frame belong to a console that is no longer there.
    if (isClosed) return;
    emit(
      state.copyWith(
        mode: InteractionMode.record,
        cursor: 0,
        activeBank: 0,
        excluded: const <int>{},
        parkedResume: const <int>{},
        // Offer whole-rig undo only when a cleared take can actually come back:
        // bump the pulse so a surface (the tracks view's toast) can react.
        // Derived, not remembered — [undoClearAll] re-reads live `clearRestore`
        // — so the pulse only needs to say "a content clear-all just happened".
        clearAllPulse: restorable ? state.clearAllPulse + 1 : null,
      ),
    );
    // The clear may be a state no-op (already home) while the held-LED bit
    // still needs to reach the wire.
    _pushProjected();
  }

  /// Whole-rig recovery from a clear-all: undoes every track that still holds
  /// a clear restore point ([Track.clearRestore]), putting its erased take
  /// back — with the layers, FX chains and mutes the repository snapshotted
  /// and re-persists per channel.
  ///
  /// Derived from the live snapshot, never a remembered set: a restore point
  /// the engine has already retired (a fresh take overwrote the cleared slot,
  /// or a take redefined the master grid) is simply not in the set, so this
  /// never resurrects a track the engine let go, and it does the right thing
  /// in the partial case (clear-all, then a new take on one track →
  /// undo-clear-all restores the others and leaves the fresh take alone). A
  /// no-op when nothing is pending — the toast never shows and ⌘⇧C is inert.
  ///
  /// Emits nothing mode-related: unlike [clearAll] it does not re-home the
  /// overlay — the user is recovering the rig they had, cursor and mode
  /// included.
  void undoClearAll() => _looper.undoClearAll();

  /// Undoes the latest overdub pass on [channel] (per-layer all the way
  /// down; past the base recording the track empties, redo-ably).
  void undo(int channel) => _looper.undo(channel: channel);

  /// Redoes the last undone layer on [channel] (including resurrecting an
  /// undone-to-empty track).
  void redo(int channel) => _looper.redo(channel: channel);

  /// An encoder detent turn: accumulates into the master output gain.
  void encoderTurned(int delta) {
    _masterGain = (_masterGain + delta * _encoderStep).clamp(0.0, 1.0);
    _looper.setMasterGain(_masterGain);
    // Push a fresh frame so the pedal ring reflects the new gain (the volume
    // meter is driven by the frame value, not a local echo).
    _pushProjected();
  }

  // ---------------------------------------------------------------------------
  // Inbound pedal events -> the same intent methods (via PedalRepository)
  // ---------------------------------------------------------------------------

  void _handleEvent(PedalEvent event) {
    switch (event) {
      case ButtonPressed(:final button):
        _onPress(button);
      case ButtonReleased(:final button):
        if (button == PedalButton.clear) _onClearRelease();
        if (_takeLocked()) {
          // The lock reaches the release, not only the press. A press taken
          // before a take started leaves a gesture armed, and running its
          // latched tap when the foot comes up is exactly the mid-take edit
          // the lock exists to refuse. The held momentary still restores: a
          // target left enabled by a press whose release was swallowed is the
          // wedge (B1), and the lock is not a reason to strand one.
          _gestures.of(button).cancel();
        } else {
          // Every gesture on this switch, system or bound, ends here. A
          // release from a retired generation runs nothing (see [_Gestures]).
          _gestures.release(button);
        }
        // Unconditional: a momentary is keyed to the button, so this finds
        // the held one (if any) whatever else that button's release did.
        _releaseBinding(button);
      case EncoderDelta(:final delta):
        _log('encoder $delta');
        encoderTurned(delta);
    }
  }

  void _onPress(PedalButton button) {
    if (_takeLocked()) return;
    _log(
      'press ${button.name}  [mode=${state.mode.name} '
      'cursor=${state.cursor}]',
    );
    // Custom controls: the switch runs whatever the setup put on it, and
    // nothing else. MODE and BANK fall through to their own arms below —
    // the binding model refuses to hold an assignment on either, so they
    // keep being the way out and the way to the other four track switches.
    if (state.mode == InteractionMode.custom &&
        !PedalBindingKey.unbindable.contains(button)) {
      _armCustom(button);
      return;
    }
    final fx = state.mode == InteractionMode.fx;
    // A remap overrides its button's contextual DEFAULT, and only in FX mode —
    // the other two modes are transport surfaces a binding must never shadow.
    // MODE and Bank can never appear here: the binding model refuses to hold
    // one (B12), so their handling below is unreachable from a binding.
    if (fx) {
      final binding = state.bindings.lookup(button, bank: state.activeBank);
      if (binding != null) {
        if (binding.hasHold) {
          // A switch carrying both moves its PRESS to the release: until the
          // threshold passes neither half is known to be the one the foot
          // meant, and the accepted design is explicit that holding must not
          // first execute the short action (controls 3). Firing the hold
          // retires the tap, so the release after it stays silent — the same
          // rule that keeps every other gesture from acting twice.
          _armBoundHold(binding);
        } else {
          _pressBinding(binding);
        }
        // Stop keeps its restore-all HOLD even when bound: a remap overrides
        // contextual defaults but never the long-press system gestures, and
        // the panic's only undo must stay reachable from the plate whatever
        // the user mapped onto the tap. A bound hold can never be here —
        // `PedalBindingKey.holdable` is the four track switches.
        if (button == PedalButton.stop) _armStopRestore();
        return;
      }
    }
    switch (button) {
      case PedalButton.undo:
        // INERT in FX mode until the #219 toggle-undo contract exists: an
        // undo that silently means "the last overdub" while the foot is in a
        // chain-editing mode is the surprise this matrix exists to prevent.
        if (!fx) _armUndo();
      case PedalButton.recPlay:
        recPlay(); // inert in FX mode (A4)
        // The press already fired on contact — the accepted design pins
        // Record / Play to that — so the hold is layered on top rather than
        // deferring anything.
        _armRecordHold();
      case PedalButton.stop:
        // FX mode splits Stop into tap = panic / long-press = restore, so the
        // action waits for the release; the other modes act on the press, as
        // they always have.
        if (fx) {
          _armStop();
        } else {
          stop();
        }
      case PedalButton.mode:
        _armMode();
      case PedalButton.bank:
        // Paging, and nothing else. BANK is the only way to reach the other
        // four track switches, so it carries no second meaning that could
        // delay or shadow it.
        toggleBankWithCursor();
      case PedalButton.clear:
        // INERT in FX mode, LED included (A2): clear is the one irreversible
        // stomp on the plate, and a stray one must never erase the set.
        if (!fx) _onClear();
      case PedalButton.track1:
      case PedalButton.track2:
      case PedalButton.track3:
      case PedalButton.track4:
        final channel = state.bankBaseChannel + _trackIndex(button);
        trackPressed(channel);
        // Same shape as Record / Play: selection keeps its immediate contact
        // and the configured hold rides above it.
        _armTrackHold(button, channel);
    }
  }

  /// Arms a Custom-controls switch's press/hold pair.
  ///
  /// The pair is read and LATCHED at press time, like every other gesture
  /// here. The latch is belt-and-braces rather than the enforcement: every
  /// setup edit goes through [setPedalSetup], which retires the pending
  /// gestures outright, so an edit mid-gesture leaves nothing to retarget.
  /// It is kept because a gesture that reads live state at dispatch would be
  /// one exception to a rule this file otherwise holds everywhere.
  ///
  /// A switch with nothing on it arms nothing and does nothing — custom mode
  /// has no contextual defaults to fall back on, which is what "fully
  /// user-defined" costs.
  void _armCustom(PedalButton button) {
    final pair = state.pedalSetup.customFor(button, bank: state.activeBank);
    final hold = pair.hold;
    if (hold == null) {
      // Press only: act on contact, like every plain switch.
      final press = pair.press;
      if (press != null) _runAction(press);
      return;
    }
    _gestures
        .of(button)
        .press(
          generation: _gestures.generation,
          threshold: _longPress,
          onHold: () => _runAction(hold),
          // Deferred to the release: until the threshold passes neither half
          // is known to be the one the foot meant.
          onTap: () {
            final press = pair.press;
            if (press != null) _runAction(press);
          },
        );
  }

  /// Runs one catalogue action.
  ///
  /// The single dispatch point for the shared vocabulary: the built-in
  /// switches reach it here, and the external and MIDI surfaces will reach
  /// the same method rather than growing interpreters of their own.
  void _runAction(ControlAction action) {
    _log('action ${action.key}');
    switch (action) {
      case ModeAction(:final mode):
        _enterMode(mode);
      case CommandAction(:final command):
        _runCommand(command);
      case TrackPedalAction(:final channel):
        selectTrack(channel);
        _recAdvance(channel);
      case SelectTrackAction(:final channel):
        selectTrack(channel);
      case TrackOperationAction(:final operation, :final scope):
        for (final channel in _channelsIn(scope)) {
          _runTrackOperation(operation, channel);
        }
    }
  }

  void _runCommand(ControlCommand command) {
    switch (command) {
      // The TRACKS-mode transport action, not the current mode's: the
      // current mode is custom, where both switches are inert, so "the
      // current mode's" would resolve to nothing.
      case ControlCommand.recordPlay:
        _recAdvance(state.cursor);
      case ControlCommand.stop:
        _recStop(state.cursor);
      case ControlCommand.undo:
        undo(state.cursor);
      case ControlCommand.redo:
        redo(state.cursor);
      case ControlCommand.clearAll:
        unawaited(clearAll());
      case ControlCommand.cutSound:
        _looper.cutSound();
      case ControlCommand.recordPerformance:
        togglePerformanceRecord();
      case ControlCommand.nextBank:
        toggleBankWithCursor();
    }
  }

  /// The channels [scope] resolves to, ONCE, at dispatch.
  ///
  /// A selected-track action fires on whatever the cursor holds at the moment
  /// the foot commits; a fixed-track one never follows the bank, which is the
  /// whole point of naming a track.
  Iterable<int> _channelsIn(ActionScope scope) => switch (scope) {
    SelectedTrackScope() => [state.cursor],
    AllTracksScope() => [for (var c = 0; c < _channelCount; c++) c],
    FixedTrackScope(:final channel) => [channel],
  };

  void _runTrackOperation(TrackOperation operation, int channel) {
    final track = _trackAt(channel);
    switch (operation) {
      case TrackOperation.mute:
        if (track == null) return;
        _looper.setMute(muted: !track.muted, channel: channel);
      case TrackOperation.solo:
        _looper.setTrackSolo(
          channel: channel,
          solo: !_looper.trackSoloed(channel),
        );
      case TrackOperation.clear:
        _looper.clear(channel: channel);
      case TrackOperation.undo:
        undo(channel);
      case TrackOperation.redo:
        redo(channel);
    }
  }

  /// Arms a bound switch's press/hold pair.
  ///
  /// Both halves are built at press time and act on the binding the foot
  /// committed to, so an assignment edited mid-gesture cannot retarget it —
  /// the same latching every system gesture uses. The generation is what
  /// makes a configuration change retire this one rather than letting it
  /// land somewhere else.
  void _armBoundHold(PedalBinding binding) {
    _gestures
        .of(binding.key.button)
        .press(
          generation: _gestures.generation,
          threshold: _longPress,
          onHold: () => _pressBinding(binding, hold: true),
          onTap: () => _pressBinding(binding),
        );
  }

  void _onClear() {
    // Light the Clear LED while the footswitch is held (cleared on release).
    _clearHeld = true;
    unawaited(clearAll());
  }

  /// Clear footswitch released: darken the Clear LED (the clear itself
  /// already happened on press — this only ends the held-button light).
  void _onClearRelease() {
    if (!_clearHeld) return;
    _clearHeld = false;
    _pushProjected();
  }

  void _armUndo() {
    final channel = state.cursor; // latched at press by both closures
    _gestures
        .of(PedalButton.undo)
        .press(
          generation: _gestures.generation,
          threshold: _longPress,
          onHold: () {
            _log('redo ch=$channel  (long-press)');
            redo(channel);
          },
          onTap: () {
            _log('undo ch=$channel  (tap)');
            undo(channel);
          },
        );
  }

  /// The FX-mode Stop gesture: the PANIC fires on the press itself, and a
  /// hold past the threshold follows it with the restore.
  ///
  /// Panic-on-press, not on release, for two reasons. A panic is an emergency
  /// control — a performer stomping it wants the chains out now, not when
  /// their foot comes up. And a release is not proof of a gesture: the
  /// on-screen plate injects a synthetic note-off for every held switch when
  /// it leaves the tree (so it never strands a note), which as a
  /// release-triggered action would have bypassed and PERSISTED every chain
  /// for a stomp the user never finished. Acting on the press makes the
  /// release inert, so a synthetic one can do no harm.
  ///
  /// The hold therefore reads as panic-then-restore, which lands on the same
  /// end state the restore promises on its own: every chain on.
  void _armStop() {
    _log('fx panic (press)');
    panicTrackChains();
    _armStopRestore();
  }

  /// Arms the Stop restore-all hold on its own, without the panic.
  ///
  /// Split out because a BOUND Stop runs its binding on the press instead of
  /// the panic, but still owes the performer the restore gesture (B12): the
  /// remap overrides the contextual default, never the long-press system
  /// gesture layered above it.
  void _armStopRestore() {
    // No `onTap`: whatever fired on the press already did, so the release is
    // inert.
    _gestures
        .of(PedalButton.stop)
        .press(
          generation: _gestures.generation,
          threshold: _longPress,
          onHold: () {
            // Only while the foot is still in the mode it committed to: cycling
            // MODE mid-hold leaves the pedal showing cursor/armed LEDs, where a
            // silent rewrite of every chain would be invisible.
            if (state.mode != InteractionMode.fx) return;
            _log('fx chains restored (long-press)');
            restoreAllTrackChains();
          },
        );
  }

  // ---------------------------------------------------------------------------
  // Performance recording (D-PEDAL)
  // ---------------------------------------------------------------------------

  /// Arms or disarms performance recording, mirroring the toolbar's own
  /// dispatch (`PerformanceRecorderCubit.toggleArm` calls the same
  /// repository methods, including the guarded `disarm()` — not
  /// `disarmAndFinalize()`, which is reserved for `SessionCubit`'s
  /// unguarded auto-disarm-before-load) — the repository's own double-press
  /// guard covers a rapid re-press identically here, so it is not
  /// duplicated in this cubit.
  void togglePerformanceRecord() {
    if (_takeLocked()) return;
    if (_performanceArmed) {
      unawaited(_performance.disarm());
    } else {
      unawaited(_performance.arm(chains: _currentChains()));
    }
  }

  void _onPerformanceStatus(PerformanceCaptureStatus status) {
    final armed = status == PerformanceCaptureStatus.armed;
    if (armed == _performanceArmed) return;
    _performanceArmed = armed;
    _pushProjected();
  }

  /// Arms the MODE gesture — the PEDAL's mode switch, whose meaning the
  /// Pedals setup owns.
  ///
  /// A press enters `modePress`; a hold enters `modeHold`. Either one LEAVES
  /// that mode when the rig is already in it, which is what makes MODE
  /// unstrandable: whatever a performer stomps, there is always a way back to
  /// Tracks, and the accepted design's Exit is exactly this.
  ///
  /// With no hold assigned the press acts on CONTACT — no gesture is armed at
  /// all, so nothing waits for a release. With one assigned the press moves to
  /// the release, because until the threshold passes neither half is known to
  /// be the one the foot meant and a hold must never first run the short
  /// action. The hold fires AT the threshold (so the mode — and the LED frame
  /// the emit projects — flips the moment it commits) and retires the tap, so
  /// the release after it stays silent.
  void _armMode() {
    final setup = state.pedalSetup;
    final hold = setup.modeHold;
    if (hold == null) {
      _log('mode ${setup.modePress.name} (press)');
      _enterMode(setup.modePress);
      return;
    }
    _gestures
        .of(PedalButton.mode)
        .press(
          generation: _gestures.generation,
          threshold: _longPress,
          onHold: () {
            _log('mode ${hold.name} (long-press)');
            _enterMode(hold);
          },
          onTap: () {
            _log('mode ${setup.modePress.name} (tap)');
            _enterMode(setup.modePress);
          },
        );
  }

  /// Enters [mode], or returns to Tracks when the rig is already in it.
  void _enterMode(InteractionMode mode) =>
      setMode(state.mode == mode ? InteractionMode.record : mode);

  /// Arms the configured Record / Play hold, if any.
  ///
  /// The channel is latched at press time like undo's: an on-screen click
  /// mid-hold must not retarget what the foot committed to. Never armed in FX
  /// mode, where the press itself is inert (A4) and a hold that acted would
  /// be the only thing the switch did there.
  void _armRecordHold() {
    if (state.mode == InteractionMode.fx) return;
    final hold = state.pedalSetup.recordHold;
    if (hold == RecordHold.none) return;
    final channel = state.cursor;
    _gestures
        .of(PedalButton.recPlay)
        .press(
          generation: _gestures.generation,
          threshold: _longPress,
          // No `onTap`: the press already ran on contact, so the release is
          // inert.
          onHold: () {
            _log('undo recording ch=$channel  (long-press)');
            undo(channel);
          },
        );
  }

  /// Arms the configured track-switch hold on [button] for [channel], if any.
  ///
  /// Never in FX mode: there the four track switches carry the remap, whose
  /// own press/hold gestures are armed by [_armBoundHold] on these same
  /// switches, and two gestures on one switch is one too many.
  void _armTrackHold(PedalButton button, int channel) {
    if (state.mode == InteractionMode.fx) return;
    final hold = state.pedalSetup.trackHold;
    if (hold == TrackHold.none) return;
    _gestures
        .of(button)
        .press(
          generation: _gestures.generation,
          threshold: _longPress,
          onHold: () => _runTrackHold(hold, channel),
        );
  }

  void _runTrackHold(TrackHold hold, int channel) {
    switch (hold) {
      case TrackHold.none:
        return;
      case TrackHold.armOverdub:
        // Only on a track that HAS a loop. On an empty one the engine's
        // cycling record() would start a take, and "arm overdub" that
        // sometimes means "record" is the surprise a hold must not hold.
        final track = _trackAt(channel);
        if (track == null || !track.hasContent) return;
        _log('arm overdub ch=$channel  (long-press)');
        _looper.record(channel: channel);
      case TrackHold.clearTrack:
        _log('clear track ch=$channel  (long-press)');
        _looper.clear(channel: channel);
    }
  }

  // ---------------------------------------------------------------------------
  // Pedal remap (part 6b): bindings, momentary hold, release-all
  // ---------------------------------------------------------------------------

  // The remap is READ off `state` (`state.bindings` / `.globalBindings` /
  // `.sessionBindings` / `.stompFor`) — the cubit exposes only the writers
  // below. No pass-through getters: a cubit's public surface is its commands,
  // and the state object is already the read surface every widget watches.

  /// Replaces the global remap and persists it (the assignment screen's edit
  /// path).
  ///
  /// Releases every held momentary FIRST: the binding the foot is holding may
  /// not survive the edit, and a target left enabled with no binding to
  /// release it is exactly the wedge (B1) the release-all rule exists to
  /// prevent.
  Future<void> setGlobalBindings(PedalBindingSet next) async {
    if (next == state.globalBindings) return;
    _invalidateGestures();
    emit(state.copyWith(globalBindings: next));
    await _settings.savePedalBindings(next.encode());
  }

  /// Applies the remap carried by a loaded session (or clears it when the
  /// bundle has none). Called from the session apply seam; releases held
  /// momentaries on the same rule as [setGlobalBindings].
  void applySessionBindings(PedalBindingSet next) {
    if (next == state.sessionBindings) return;
    _invalidateGestures();
    emit(state.copyWith(sessionBindings: next));
  }

  /// Retires every pending gesture, and every held momentary with it.
  ///
  /// The accepted rule (controls 3): pending gestures are cancelled on
  /// invalidating navigation, disconnect or configuration. All three mean the
  /// same thing here — the rig the foot committed to is not the rig the
  /// release will land in, so neither half of the gesture may still run.
  ///
  /// Cancelling a timer is not enough on its own: a release already on its way
  /// up the wire cannot be recalled, so [_Gestures] retires the generation and
  /// the stale release runs nothing when it lands.
  void _invalidateGestures() {
    _gestures.cancelAll();
    releaseAllMomentary();
  }

  /// Restores every held momentary to the state its press captured — the ONE
  /// enforcement point (B1).
  ///
  /// Every path that can strand a press without its release funnels here:
  /// mode exit ([setMode]), a binding-set change ([setGlobalBindings] /
  /// [applySessionBindings], which covers the assignment screen's live edits
  /// AND a session load), and pedal disconnect ([_onBindStatus]). A physical
  /// release goes through [_releaseBinding] instead, which restores just that
  /// one — but both write the captured state, so no target can be left
  /// enabled by a press whose release never arrived.
  void releaseAllMomentary() {
    if (_heldRestore.isEmpty) return;
    for (final held in _heldRestore.values) {
      _looper.setBindingEnabled(held.target, enabled: held.prior);
    }
    _log('released ${_heldRestore.length} held momentary binding(s)');
    _heldRestore.clear();
    emit(state.copyWith(heldMomentary: const <PedalBindingKey>{}));
  }

  /// Runs [binding] instead of its button's contextual FX-mode default.
  ///
  /// A stale binding — one whose target string no longer parses, or names a
  /// chain/slot the rig no longer has — is a NO-OP (R25). It writes nothing
  /// and lights nothing; the assignment screen is where the user learns it is
  /// broken, not a mid-song stomp that silently bypasses the wrong thing.
  void _pressBinding(PedalBinding binding, {bool hold = false}) {
    final target = _scoped(
      hold ? binding.decodeHoldTarget() : binding.decodeTarget(),
      hold ? binding.holdScope : binding.scope,
    );
    final prior = target == null ? null : _looper.bindingEnabled(target);
    if (target == null || prior == null) {
      final half = hold ? 'hold' : 'press';
      _log('binding $half on ${binding.key.button.name} is stale — no-op');
      return;
    }
    switch (hold ? binding.holdBehavior : binding.behavior) {
      case BindingBehavior.toggle:
        _log('binding toggle ${binding.key.button.name} -> ${!prior}');
        _looper.setBindingEnabled(target, enabled: !prior);
      case BindingBehavior.momentary:
        _log('binding momentary ${binding.key.button.name} (was $prior)');
        // Capture on the FIRST press only. A repeated press with no release
        // between them — a dropped NoteOff, or the on-screen plate re-emitting
        // a down — would otherwise re-capture the state THIS binding just
        // enabled, and the eventual release would restore `true` and strand
        // the target on: the stuck momentary (B1) with no foot on the switch.
        _heldRestore.putIfAbsent(
          binding.key,
          () => (target: target, prior: prior),
        );
        _looper.setBindingEnabled(target, enabled: true);
        emit(
          state.copyWith(heldMomentary: {...state.heldMomentary, binding.key}),
        );
    }
    _pushProjected();
  }

  /// [target] pointed at the track [scope] names, resolved NOW.
  ///
  /// Resolved at dispatch, never at press. That is the whole of the accepted
  /// "target following" rule: a pending hold acts on the newly selected track
  /// because it reads the cursor when it fires, and it stays attached to what
  /// it resolved because the momentary restore captures the RESOLVED target.
  /// A switch carrying a hold defers its press to the release, so both halves
  /// resolve at the instant they act.
  FxBindingTarget? _scoped(FxBindingTarget? target, BindingScope scope) {
    if (target == null || scope == BindingScope.fixed) return target;
    final address = resolveBindingAddress(target.address, scope, state.cursor);
    if (address == target.address) return target;
    return switch (target) {
      FxChainTarget() => FxChainTarget(address),
      FxSlotTarget(:final slotId) => FxSlotTarget(
        address: address,
        slotId: slotId,
      ),
    };
  }

  /// Restores the momentary [button] is holding, if any.
  ///
  /// Matched by BUTTON rather than by the live bank's key: the performer can
  /// stomp Bank while a track momentary is down, and the release must still
  /// find the binding that was actually pressed. A button holds at most one
  /// momentary at a time, so the match is unambiguous.
  void _releaseBinding(PedalButton button) {
    for (final key in _heldRestore.keys) {
      if (key.button != button) continue;
      final held = _heldRestore.remove(key)!;
      _log('binding momentary ${button.name} released -> ${held.prior}');
      _looper.setBindingEnabled(held.target, enabled: held.prior);
      emit(
        state.copyWith(heldMomentary: {...state.heldMomentary}..remove(key)),
      );
      return;
    }
  }

  // ---------------------------------------------------------------------------
  // External MIDI control (part 7): mappings, learn, dispatch, release-all
  // ---------------------------------------------------------------------------

  /// Replaces the external-MIDI mapping set, applies it to the repository, and
  /// persists it to the GLOBAL `controller.mappings` blob (R19 — no session
  /// carries a copy).
  ///
  /// Releases every held MIDI momentary FIRST, on the same rule the pedal remap
  /// obeys: the binding a foot is holding may not survive the edit, and a
  /// target left enabled with nothing able to release it is exactly the wedge
  /// (B1) the release-all rule exists to prevent.
  Future<void> setControllerBindings(ControllerBindingSet next) async {
    if (next == state.controllerBindings) return;
    // A capture relearning a row this edit removes has nothing left to render
    // it: its row is gone, and the add-row only shows a capture that is not
    // relearning anything. Ending it here is what keeps the repository from
    // swallowing every controller event behind a UI that shows nothing.
    // Before the emit below, since cancelling emits on its own.
    final learn = state.controllerLearn;
    final relearning = learn?.replacingKey;
    if (relearning != null &&
        !next.bindings.any((binding) => binding.key == relearning)) {
      _log('midi learn cancelled: the row it was relearning was removed');
      cancelControllerLearn();
    }
    _releaseControllerMomentariesMissingFrom(next);
    _controller?.setBindings(next);
    _cacheControllerTargets(next);
    emit(state.copyWith(controllerBindings: next));
    _scheduleMappingsWrite(next.encode());
  }

  /// Releases the held momentaries [next] no longer carries — the edit half of
  /// the release-all rule (B1).
  ///
  /// Scoped to the holds the edit actually strands: a control whose mapping is
  /// gone, whose target moved, or which is no longer momentary at all. A
  /// mapping that survived the edit keeps its hold, because an unrelated row's
  /// range says nothing about the switch under someone's foot — and a LO/HI
  /// drag runs this once per pointer frame, so releasing everything here would
  /// drop a held chain mid-song the moment any knob moved.
  void _releaseControllerMomentariesMissingFrom(ControllerBindingSet next) {
    if (_heldControllerRestore.isEmpty) return;
    final live = <(MappingTrigger, String)>{
      for (final binding in next.bindings)
        if (binding is DiscreteBinding &&
            binding.behavior == BindingBehavior.momentary)
          binding.key,
    };
    var released = 0;
    for (final entry in _heldControllerRestore.entries.toList()) {
      entry.value.holders.removeWhere(
        (trigger) => !live.contains((trigger, entry.key)),
      );
      if (entry.value.holders.isNotEmpty) continue;
      _heldControllerRestore.remove(entry.key);
      _looper.setBindingEnabled(entry.value.target, enabled: entry.value.prior);
      released++;
    }
    if (released == 0) return;
    _log('released $released held MIDI momentary(s) the edit stranded');
    _pushProjected();
  }

  /// Decodes every binding's target once, for the dispatch path to look up.
  void _cacheControllerTargets(ControllerBindingSet bindings) {
    _controllerValueTargets.clear();
    _controllerSwitchTargets.clear();
    for (final binding in bindings.bindings) {
      switch (binding) {
        case ContinuousBinding():
          final target = ControlValueTarget.tryParse(binding.target);
          if (target != null) _controllerValueTargets[binding.target] = target;
        case DiscreteBinding():
          final target = FxBindingTarget.tryParse(binding.target);
          if (target != null) _controllerSwitchTargets[binding.target] = target;
      }
    }
  }

  /// Coalesces the settings write for [blob] (see [_mappingsWriteTimer]).
  ///
  /// A zero debounce writes straight through and arms no timer at all — what
  /// tests pass so a pumped frame does not have to outlive a pending write.
  void _scheduleMappingsWrite(String blob) {
    _pendingMappingsBlob = blob;
    _mappingsWriteTimer?.cancel();
    if (_mappingsWriteDebounce <= Duration.zero) {
      _flushMappingsWrite();
      return;
    }
    _mappingsWriteTimer = Timer(_mappingsWriteDebounce, _flushMappingsWrite);
  }

  void _flushMappingsWrite() {
    _mappingsWriteTimer?.cancel();
    _mappingsWriteTimer = null;
    final blob = _pendingMappingsBlob;
    if (blob == null) return;
    _pendingMappingsBlob = null;
    unawaited(_settings.saveControllerMappings(blob));
  }

  /// Commits a pending mappings write now. Called on a clean halt so a
  /// debounce that was still armed at press is not lost.
  void flushMappings() => _flushMappingsWrite();

  /// Replaces one mapping in place (an edited range, threshold, behavior or
  /// target), preserving its row position.
  Future<void> updateControllerBinding(
    ControllerBinding binding,
    ControllerBinding next,
  ) => setControllerBindings(state.controllerBindings.replace(binding, next));

  /// Removes one mapping.
  Future<void> removeControllerBinding(ControllerBinding binding) =>
      setControllerBindings(state.controllerBindings.without(binding));

  /// Starts a MIDI-learn capture for [target].
  ///
  /// [continuous] picks the trigger shape a NEW mapping takes; when
  /// [replacing] is given the shape and ranges of that mapping are carried
  /// over instead, so relearning which control drives a parameter never resets
  /// the travel the user dialed in.
  ///
  /// The capture ends in one of four ways: a control moves and binds; a control
  /// moves onto a CC that is already mapped, which parks the capture on
  /// [ControllerLearn.awaitingConfirm] until [confirmControllerLearn]; the user
  /// cancels; or the learn timeout elapses. The repository swallows ALL
  /// controller input while a capture is pending, which is why every one of
  /// those paths ends it.
  void learnControllerBinding({
    required String target,
    bool continuous = true,
    ControllerBinding? replacing,
  }) {
    final controller = _controller;
    if (controller == null) return;
    // A pending capture SWALLOWS every controller input, the release edge of a
    // held momentary included — so a foot still on a switch when a learn starts
    // would never be released, and the target would stay enabled with nothing
    // able to turn it off. Release first: the same B1 rule every other
    // stranding path obeys.
    releaseAllControllerMomentary();
    _learnTimer?.cancel();
    _learnTimer = Timer(_learnTimeout, cancelControllerLearn);
    emit(
      state.copyWith(
        controllerLearn: ControllerLearn(
          target: target,
          // A relearn keeps the shape it already has; only a NEW mapping is
          // free to take the caller's.
          continuous: switch (replacing) {
            ContinuousBinding() => true,
            DiscreteBinding() => false,
            null => continuous,
          },
          replacingKey: replacing?.key,
        ),
      ),
    );
    final generation = ++_learnGeneration;
    unawaited(
      controller.learnNext().then(
        (input) => _onLearnCaptured(generation, input),
      ),
    );
  }

  /// Confirms replacing the existing mapping(s) on the captured control (R28).
  /// A no-op unless a capture is parked on the confirmation.
  Future<void> confirmControllerLearn() async {
    final learn = state.controllerLearn;
    final captured = learn?.captured;
    if (learn == null || captured == null) return;
    await _applyLearn(learn, captured, replaceExisting: true);
  }

  /// Ends a capture without binding anything — the row's cancel action, the
  /// timeout, and the "keep what I had" half of the replace confirmation.
  void cancelControllerLearn() {
    _learnTimer?.cancel();
    _learnTimer = null;
    // Retire the capture BEFORE cancelling it, so the null completion this
    // triggers cannot act on whatever comes next.
    _learnGeneration++;
    _controller?.cancelLearn();
    if (isClosed || state.controllerLearn == null) return;
    emit(state.copyWith(clearControllerLearn: true));
  }

  /// The mapping [key] names in the LIVE set, or `null` when the row it
  /// pointed at has since been removed.
  ControllerBinding? _liveBinding((MappingTrigger, String)? key) {
    if (key == null) return null;
    return state.controllerBindings.bindings
        .where((binding) => binding.key == key)
        .firstOrNull;
  }

  void _onLearnCaptured(int generation, RawControllerInput? input) {
    // A superseded or cancelled capture completes with null too, and its
    // callback must not touch the capture that replaced it — nor cancel the
    // timeout that is the only thing rescuing a capture nobody feeds.
    if (isClosed || generation != _learnGeneration) return;
    final learn = state.controllerLearn;
    if (learn == null) return;
    _learnTimer?.cancel();
    _learnTimer = null;
    if (input == null) {
      emit(state.copyWith(clearControllerLearn: true));
      return;
    }
    // The CHANNEL-scoped identity: the same CC number on two channels is two
    // controls, so the capture records which one it heard (B8).
    final trigger = input.channelTrigger;
    // Exempt the row being relearned as it stands NOW: against a stale value,
    // re-teaching a row the control it already has would read as a conflict
    // with itself.
    if (state.controllerBindings.isTriggerBound(
      trigger,
      except: _liveBinding(learn.replacingKey),
    )) {
      _log('midi learn caught an already-mapped control: $trigger');
      emit(state.copyWith(controllerLearn: learn.withCaptured(trigger)));
      return;
    }
    unawaited(_applyLearn(learn, trigger, replaceExisting: false));
  }

  Future<void> _applyLearn(
    ControllerLearn learn,
    MappingTrigger trigger, {
    required bool replaceExisting,
  }) async {
    // Resolve the row being relearned from the LIVE set: its knobs and its
    // Remove button stay usable while a capture listens, so it may have been
    // edited or deleted outright since the capture started. Rebuilding from
    // what is there now is what keeps a relearn from resurrecting a removed
    // mapping — `replace` would silently fall back to adding one — or from
    // writing back the ranges the user just dialed away.
    final replacing = _liveBinding(learn.replacingKey);
    if (learn.replacingKey != null && replacing == null) {
      _log('midi learn dropped: the row it was relearning is gone');
      emit(state.copyWith(clearControllerLearn: true));
      return;
    }
    final next = switch (replacing) {
      ContinuousBinding(:final lo, :final hi) => ContinuousBinding(
        trigger: trigger,
        target: learn.target,
        lo: lo,
        hi: hi,
      ),
      DiscreteBinding(:final threshold, :final behavior) => DiscreteBinding(
        trigger: trigger,
        target: learn.target,
        threshold: threshold,
        behavior: behavior,
      ),
      null =>
        learn.continuous
            ? ContinuousBinding(trigger: trigger, target: learn.target)
            : DiscreteBinding(trigger: trigger, target: learn.target),
    };
    var bindings = state.controllerBindings;
    if (replaceExisting) {
      bindings = bindings.withoutTrigger(trigger, except: replacing);
    }
    bindings = replacing == null
        ? bindings.withBinding(next)
        : bindings.replace(replacing, next);
    _log('midi learn bound $trigger -> ${learn.target}');
    emit(state.copyWith(clearControllerLearn: true));
    await setControllerBindings(bindings);
  }

  /// Applies one resolved external-MIDI binding event.
  ///
  /// The SAME enforcement point the pedal's own bindings pass through (VGV):
  /// no second control-surface interpreter grows inside a repository package,
  /// so a discrete CC means here exactly what a footswitch binding means.
  ///
  /// Unlike a pedal binding, external control is NOT gated on FX mode: a
  /// mapping the user made explicitly, on hardware whose only job is that
  /// mapping, has no contextual default it could be shadowing.
  void _onControllerBindingEvent(ControllerBindingEvent event) {
    switch (event) {
      case ControllerValueEvent(:final target, :final value):
        _applyControllerValue(target, value);
      case ControllerSwitchEvent(
        :final target,
        :final trigger,
        :final behavior,
        :final pressed,
      ):
        _applyControllerSwitch(target, trigger, behavior, pressed: pressed);
    }
  }

  /// Writes a continuous binding's value. Last-writer-wins against the
  /// on-screen controls and against any other mapping on the same target — the
  /// CC simply writes, exactly as a knob drag does.
  void _applyControllerValue(String target, double value) {
    final decoded = _controllerValueTargets[target];
    if (decoded == null) return; // undecodable string: inert, never a guess
    if (!_looper.writeValueTarget(decoded, value)) return;
    if (decoded is MasterGainTarget) {
      // Keep the accumulator the encoder and the pedal's ring meter read in
      // step with what MIDI just wrote, or the next detent turn would jump
      // back to the value the encoder last set.
      _masterGain = value.clamp(0.0, 1.0);
      _pushProjected();
    }
  }

  void _applyControllerSwitch(
    String target,
    MappingTrigger trigger,
    BindingBehavior behavior, {
    required bool pressed,
  }) {
    final decoded = _controllerSwitchTargets[target];
    final prior = decoded == null ? null : _looper.bindingEnabled(decoded);
    if (decoded == null || prior == null) {
      // Stale mapping: a no-op, like a stale pedal binding (R25). Its row is
      // where the user learns it is broken, not a mid-song stomp.
      // A target that went stale WHILE held still has to be put back: the
      // capture is the only record of what it was before the press.
      final captured = _heldControllerRestore.remove(target);
      if (captured == null) return;
      _looper.setBindingEnabled(captured.target, enabled: captured.prior);
      _pushProjected();
      return;
    }
    switch (behavior) {
      case BindingBehavior.toggle:
        // Latching: only the ON edge acts, so the control's release does not
        // undo the stomp it just made.
        if (!pressed) return;
        _log('midi toggle -> ${!prior}');
        _looper.setBindingEnabled(decoded, enabled: !prior);
      case BindingBehavior.momentary:
        final entry = _heldControllerRestore[target];
        if (pressed) {
          // Capture on the FIRST hold only — a repeated ON edge with no release
          // between them, or a second control joining the hold, must not
          // re-capture the state the hold itself enabled.
          if (entry == null) {
            _heldControllerRestore[target] = (
              target: decoded,
              prior: prior,
              holders: {trigger},
            );
          } else {
            entry.holders.add(trigger);
          }
          _looper.setBindingEnabled(decoded, enabled: true);
        } else {
          if (entry == null) return;
          entry.holders.remove(trigger);
          // Another control is still holding this target down.
          if (entry.holders.isNotEmpty) return;
          _heldControllerRestore.remove(target);
          _log('midi momentary released -> ${entry.prior}');
          _looper.setBindingEnabled(entry.target, enabled: entry.prior);
        }
    }
    _pushProjected();
  }

  /// Restores every MIDI-held momentary to the state its press captured — the
  /// external-control half of the ONE release-all rule (B1).
  ///
  /// Reached from MIDI-source disconnect ([_onMidiConnection]) and from the
  /// start of a learn capture, which swallows the release edge. A mapping EDIT
  /// releases only what it strands — see
  /// [_releaseControllerMomentariesMissingFrom].
  ///
  /// A held momentary whose device unplugs will never see its OFF edge, so
  /// without this the target would stay enabled with no control able to
  /// release it. CONTINUOUS bindings are deliberately
  /// the opposite: an unplug mid-song leaves the value exactly where the last
  /// sweep put it, because snapping a filter back to a stored value the moment
  /// a cable wobbles is the louder failure.
  void releaseAllControllerMomentary() {
    if (_heldControllerRestore.isEmpty) return;
    for (final held in _heldControllerRestore.values) {
      _looper.setBindingEnabled(held.target, enabled: held.prior);
    }
    _log('released ${_heldControllerRestore.length} held MIDI momentary(s)');
    _heldControllerRestore.clear();
    _pushProjected();
  }

  void _onMidiConnection(MidiConnection connection) {
    if (connection.status == MidiConnectionStatus.connected) return;
    releaseAllControllerMomentary();
  }

  // ---------------------------------------------------------------------------
  // Simulate input (#519): a mapping proves itself with no controller attached
  // ---------------------------------------------------------------------------

  /// Runs [binding]'s synthetic sequence through the real pipeline: a
  /// [ContinuousBinding] sweeps LO→HI→LO, a [DiscreteBinding] presses and
  /// releases. The events enter through [_simulatedSource], so the binding's
  /// OWN range / curve / threshold / behaviour apply downstream exactly as they
  /// would to a real pedal — this method never pre-applies any of that; the
  /// repository owns the math.
  ///
  /// Resolved against the LIVE set by [binding]'s key: the row's calibration
  /// stays editable while a simulation could be requested, so what runs is the
  /// range that is there NOW, not a stale snapshot.
  void simulateMapping(ControllerBinding binding) {
    final live = _liveBinding(binding.key) ?? binding;
    final values = switch (live) {
      ContinuousBinding() => _sweepValues,
      DiscreteBinding() => _switchValues,
    };
    _startSimulation(live.trigger, values);
  }

  /// The global "Simulate input" affordance: routes a synthetic event where a
  /// real one would land — a listening learn capture first, else the open row
  /// [openKey], else nothing (the button renders dimmed with no route).
  void simulateStatusRow((MappingTrigger, String)? openKey) {
    if (state.controllerLearn != null) {
      // A representative move the pending capture binds, exactly as a real one
      // would — an expression control (mod wheel), not the pedal's own encoder
      // CC, so `learnIgnore` never swallows it. Straight to the source, not the
      // paced ticker: a capture ends on the first input it accepts.
      _simulatedSource?.push(
        const RawControllerInput(
          kind: ControllerSourceKind.midiCc,
          id: 1,
          value: 127,
        ),
      );
      return;
    }
    final open = _liveBinding(openKey);
    if (open != null) simulateMapping(open);
  }

  /// CC values a sweep pushes: 0 → 127, a brief dwell at 127, then 127 → 0, one
  /// per [_simulateTick], each leg spanning [_simulateSweepLeg]. The endpoints
  /// are exact (0 and 127) so the bound value reaches both edges of its range;
  /// the dwell lets the smoothing ramp settle AT the top before the descent, so
  /// the target is seen to reach HI rather than only turn around near it.
  List<int> get _sweepValues {
    final n = _sweepSteps;
    int cc(int i) => (127 * i / n).round();
    return [
      for (var i = 0; i <= n; i++) cc(i), // LO → HI
      for (var i = 0; i < _sweepDwell; i++) 127, // settle at HI
      for (var i = n - 1; i >= 0; i--) cc(i), // HI → LO
    ];
  }

  /// How many extra ticks a sweep holds at HI before descending — enough for
  /// the smoothing ramp to land on the endpoint even when the tick and the ramp
  /// run at the same cadence.
  static const int _sweepDwell = 2;

  /// A switch's press then release, with a couple of held ticks between so a
  /// momentary is visibly held before it lets go (a toggle ignores the release
  /// edge, so the same sequence flips it once). Above then below any threshold:
  /// 127 is on for every threshold `<= 127`, 0 is off for every threshold.
  List<int> get _switchValues => const [127, 127, 127, 0];

  /// How many ticks a sweep leg takes — at least one, mirroring the
  /// repository's own smoothing-step flooring so a leg shorter than a tick
  /// still lands on the endpoint.
  int get _sweepSteps {
    final steps = _simulateTick.inMicroseconds <= 0
        ? 1
        : (_simulateSweepLeg.inMicroseconds / _simulateTick.inMicroseconds)
              .round();
    return steps < 1 ? 1 : steps;
  }

  void _startSimulation(MappingTrigger trigger, List<int> values) {
    // Finish any prior sequence first (a switch mid-hold, a sweep mid-ramp), so
    // replacing it cannot strand a held momentary.
    _drainSimulation();
    _simulateTrigger = trigger;
    _simulateQueue
      ..clear()
      ..addAll(values);
    // Push the first now so the target moves without waiting a tick.
    _tickSimulation();
    if (_simulateQueue.isEmpty) {
      _simulateTrigger = null;
      return;
    }
    _simulateTimer = Timer.periodic(_simulateTick, (_) => _tickSimulation());
  }

  void _tickSimulation() {
    final trigger = _simulateTrigger;
    if (trigger == null) return;
    if (_simulateQueue.isEmpty) {
      _simulateTimer?.cancel();
      _simulateTimer = null;
      _simulateTrigger = null;
      return;
    }
    _pushSimulated(trigger, _simulateQueue.removeAt(0));
  }

  /// Pushes whatever a running simulation has left immediately, then clears
  /// it — so a switch's release edge always fires when a NEW simulation cuts
  /// the ticker short, rather than stranding a momentary the prior press
  /// enabled. Safe only while the cubit is alive to receive those pushed
  /// events; teardown uses [_cancelSimulation] instead.
  void _drainSimulation() {
    _simulateTimer?.cancel();
    _simulateTimer = null;
    final trigger = _simulateTrigger;
    if (trigger == null) return;
    while (_simulateQueue.isNotEmpty) {
      _pushSimulated(trigger, _simulateQueue.removeAt(0));
    }
    _simulateTrigger = null;
  }

  /// Stops a running simulation without pushing what is left — teardown, where
  /// the binding-event subscription is about to be cancelled and a drained
  /// event would never be delivered anyway (the app is going away).
  void _cancelSimulation() {
    _simulateTimer?.cancel();
    _simulateTimer = null;
    _simulateTrigger = null;
    _simulateQueue.clear();
  }

  void _pushSimulated(MappingTrigger trigger, int value) {
    _simulatedSource?.push(
      RawControllerInput(
        kind: trigger.kind,
        id: trigger.id,
        value: value,
        // Omni triggers carry no channel; a real message still lands on one,
        // so the synthetic one does too (channel 0, the default a capture
        // records).
        midiChannel: trigger.midiChannel ?? 0,
      ),
    );
  }

  /// What each BOUND track switch's own target currently reads, by channel.
  ///
  /// Only in FX mode, because that is the only mode a binding overrides — the
  /// other two are transport surfaces a remap must never shadow, and their
  /// LEDs mean something else entirely.
  ///
  /// A present null is a binding that no longer resolves. It stays in the map
  /// rather than being dropped, so the LED can go dark: R25 says a stale
  /// binding writes nothing and lights nothing, and dropping it here would
  /// fall back to this channel's track chain — lighting for a chain the switch
  /// does not drive.
  Map<int, bool?> _boundChains() {
    if (state.mode != InteractionMode.fx) return const {};
    final bound = <int, bool?>{};
    for (final button in const [
      PedalButton.track1,
      PedalButton.track2,
      PedalButton.track3,
      PedalButton.track4,
    ]) {
      final binding = state.bindings.lookup(button, bank: state.activeBank);
      if (binding == null) continue;
      final target = binding.decodeTarget();
      bound[_trackIndex(button)] = target == null
          ? null
          : _looper.bindingEnabled(target);
    }
    return bound;
  }

  int _trackIndex(PedalButton button) => switch (button) {
    PedalButton.track1 => 0,
    PedalButton.track2 => 1,
    PedalButton.track3 => 2,
    PedalButton.track4 => 3,
    _ => throw ArgumentError('not a track button: $button'),
  };

  // ---------------------------------------------------------------------------
  // Outbound frame projection (via PedalRepository)
  // ---------------------------------------------------------------------------

  void _onLooperState(LooperState looperState) {
    _looperState = looperState;
    _reduce(looperState);
    _detectLoopTop(looperState);
    _pushProjected();
  }

  void _onBindStatus(PedalBindStatus status) {
    // A fresh bind has no last frame on the pedal — force the next push (it
    // reads the CURRENT state, so a mode/cursor changed while unplugged
    // shows correctly on replug).
    if (status == PedalBindStatus.bound) {
      _lastFrame = null;
      _pushProjected();
      return;
    }
    // Unplugged mid-hold: the release note-off is never coming, so a held
    // momentary would leave its target enabled forever (B1), and an armed
    // hold would fire into a rig with no pedal on it. Retire both now.
    _invalidateGestures();
  }

  void _detectLoopTop(LooperState s) {
    final position = s.transport.masterPositionFrames;
    final previous = _lastPosition;
    if (previous != null &&
        position < previous &&
        s.transport.masterLengthFrames > 0) {
      _pedal.sendLoopTop();
    }
    _lastPosition = position;
  }

  /// Projects and pushes the current LED frame. Diffs against the last push so
  /// steady state is silent; [force] re-sends unchanged (the keep-alive uses it
  /// so the pedal's link watchdog keeps seeing frames while idle).
  void _pushProjected({bool force = false}) {
    // Project from `_l` — the last streamed state, or the repository's current
    // snapshot when no LooperState has streamed in yet. Reading `_l` (not the
    // raw `_looperState`) lets the keep-alive light the pedal on bind even
    // before the first stream event: an idle engine emits no LooperState, so
    // gating on a null `_looperState` left the LEDs dark until some audio
    // activity happened to push a state.
    final looperState = _l;
    final frame = projectFrame(
      looperState,
      state,
      clearFadeActive: _clearHeld,
      performanceArmed: _performanceArmed,
      masterGain: _masterGain,
      boundChains: _boundChains(),
    );
    if (!force && frame == _lastFrame) return; // diff: only push on change
    _lastFrame = frame;
    _pedal.pushState(frame);
  }

  // ---------------------------------------------------------------------------
  // Snapshot helpers
  // ---------------------------------------------------------------------------

  int? _capturingChannel() {
    for (final track in _tracks) {
      if (track.isCapturing) return track.channel;
    }
    return null;
  }

  /// Whether muting [channel] would leave no audible armed track.
  bool _isLastAudibleArmed(int channel) {
    final armed = armedTracks(_l, state);
    return !armed.any((c) {
      if (c == channel) return false;
      final track = _trackAt(c);
      return track != null && !track.muted && track.state == TrackState.playing;
    });
  }

  /// Whether muting [channel] would silence every track (the Rec-mode
  /// sole-track case).
  bool _isLastAudibleTrack(int channel) => !_tracks.any(
    (t) =>
        t.channel != channel &&
        !t.muted &&
        t.hasContent &&
        t.state == TrackState.playing,
  );

  int get _channelCount => ControlState.tracksPerBank * ControlState.bankCount;

  void _log(String message) {
    dev.log(message, name: 'control');
    // Skip high-frequency encoder deltas — they would flood the rotating log.
    if (!message.startsWith('encoder ')) {
      AppLog.info('control: $message');
    }
  }

  @override
  void emit(ControlState state) {
    super.emit(state);
    // Every stored-intent change re-projects the pedal frame (the diff in
    // [_pushProjected] keeps the wire quiet when the LEDs are unaffected).
    // After super.emit — onChange fires BEFORE the state field updates, and
    // a projection of the outgoing state trips the invariant assert.
    _pushProjected();
  }

  @override
  Future<void> close() async {
    _keepAliveTimer?.cancel();
    _learnTimer?.cancel();
    // Stop any simulation in flight — its ticker must not outlive the cubit.
    _cancelSimulation();
    // A capture outlives this cubit otherwise: the controller repository is
    // app-scoped, and while it is learning it swallows EVERY input — including
    // the transport events another bloc consumes — with the timeout that would
    // have rescued it already cancelled above.
    _controller?.cancelLearn();
    // Commit whatever the debounce was still holding, so a quit mid-edit does
    // not lose the mapping the user just made.
    _flushMappingsWrite();
    _gestures.cancelAll();
    await _looperSub.cancel();
    await _eventsSub.cancel();
    await _statusSub.cancel();
    await _perfStatusSub.cancel();
    await _bindingSub?.cancel();
    await _midiSub?.cancel();
    return super.close();
  }
}
