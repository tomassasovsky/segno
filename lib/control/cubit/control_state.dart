part of 'control_cubit.dart';

/// The CLOSED inventory of stored user intent — the only control-surface
/// state that is not derivable from a `LooperState` snapshot. Everything else
/// (the armed set, every LED, the ring) is a pure function of
/// `(LooperState × ControlState)` — see `control_projection.dart`.
///
/// Every field here has a written invalidation rule (the table in
/// docs/brainstorm/2026-07-04-control-state-robustness-brainstorm-doc.md),
/// implemented in ONE place: [ControlCubit]'s looper reducer plus the
/// explicit intent methods. Nothing else may store control state.
class ControlState extends Equatable {
  /// Creates a [ControlState].
  const ControlState({
    this.mode = InteractionMode.record,
    this.defaultMode = InteractionMode.record,
    this.modeSwitchStyle = ModeSwitchStyle.cycleThree,
    this.cursor = 0,
    this.activeBank = 0,
    this.excluded = const <int>{},
    this.parkedResume = const <int>{},
    this.globalBindings = PedalBindingSet.empty,
    this.sessionBindings = PedalBindingSet.empty,
    this.heldMomentary = const <PedalBindingKey>{},
    this.controllerBindings = ControllerBindingSet.empty,
    this.controllerLearn,
    this.clearAllPulse = 0,
  });

  /// Tracks per bank.
  static const int tracksPerBank = 4;

  /// The number of banks.
  static const int bankCount = 2;

  /// The system-wide record/mute mode — every surface (pedal footswitch, `M`
  /// key, on-screen chip) toggles and reads this ONE field. Changed only by
  /// explicit mode actions (clear-all counts: a whole-rig reset → record).
  final InteractionMode mode;

  /// The persisted mode the system boots into.
  final InteractionMode defaultMode;

  /// How the MODE footswitch reaches the three interaction modes (#632): the
  /// original three-stop tap cycle (the default), or a Record ↔ Mute tap
  /// cycle with FX behind the MODE hold. Per-rig, persisted under
  /// `pedal.mode_switch_style` and restored at boot. Invalidation rule: only
  /// an explicit edit ([ControlCubit.setModeSwitchStyle]) writes it — engine
  /// truth never can.
  final ModeSwitchStyle modeSwitchStyle;

  /// The ONE track cursor, shared by every surface (`0..7`). Rec-mode
  /// Rec/Play, Stop, Undo and Redo target it. Clamped to a valid channel by
  /// the looper reducer; reset by clear-all.
  final int cursor;

  /// The visible bank (`0` = A, `1` = B). A stored bit: bank BROWSE without
  /// moving the cursor is a real flow (arming the other bank's tracks in mute
  /// mode). Any cursor write also sets `bank = cursor ~/ 4`, so the cursor
  /// can never hide behind the other bank.
  final int activeBank;

  /// Mute-mode opt-outs: tracks the user deliberately pulled out of the mix.
  /// A sounding track outside this set is ALWAYS armed —
  /// `armed = sounding ∖ excluded` — so redo / an on-screen play re-enters
  /// the mix with no reconciliation. Cleared when the track empties, on
  /// clear-all, on mode entry, and on session load. (No surface writes it
  /// yet: the pedal's mute-mode track press mutes rather than excludes; the
  /// representation exists so a future disarm affordance cannot re-create
  /// the stale-armed-set bug class.)
  final Set<int> excluded;

  /// What Rec/Play resumes while parked: latched at PARK-INTENT time from the
  /// then-derived armed set (Stop-park), set to ∅ by mute-last-track park
  /// (Rec/Play then falls back to ALL content), and set to all content tracks
  /// on mode entry into Mute. Members drop when their track empties; cleared
  /// on clear-all, mode entry, session load, and consumed by the next resume.
  final Set<int> parkedResume;

  /// The GLOBAL pedal remap (part 6b), restored from settings at boot and
  /// edited by the assignment screen.
  ///
  /// Stored intent, so it lives here rather than in a cubit field: the Signal
  /// surface's stomp chips and the assignment screen both read it through
  /// `context.watch`, and an edit has to reach them. Invalidation rule: only
  /// an explicit edit writes it — nothing about engine truth can invalidate a
  /// binding, since a target that no longer exists goes INERT rather than
  /// being dropped (R25).
  final PedalBindingSet globalBindings;

  /// The loaded session's own remap; empty when it carries none. Replaced
  /// wholesale on session load, never merged per button (A12).
  final PedalBindingSet sessionBindings;

  /// Which controls are currently holding a MOMENTARY binding down.
  ///
  /// The captured restore VALUES stay in the cubit — they are a mid-gesture
  /// implementation detail no surface renders. What is stored here is the set
  /// a surface needs: the chips mark a chain as held-from-the-pedal, which is
  /// the one FX state on screen the user cannot undo by clicking. Invalidation
  /// rule: emptied at the single release-all point (B1) and on each release.
  final Set<PedalBindingKey> heldMomentary;

  /// The external-MIDI mapping set (part 7), restored from the global
  /// `controller.mappings` settings blob at boot and edited by the MIDI-learn
  /// settings section.
  ///
  /// GLOBAL-ONLY (R19): no session carries a copy, because expression hardware
  /// belongs to the rig rather than the song. Invalidation rule: same as the
  /// pedal remap — only an explicit edit writes it, and a target that no
  /// longer exists goes INERT rather than being dropped.
  final ControllerBindingSet controllerBindings;

  /// The MIDI-learn capture in progress, or `null` when nothing is listening.
  /// Invalidation rule: cleared when the capture applies, is cancelled, or
  /// times out — never by engine truth.
  final ControllerLearn? controllerLearn;

  /// A monotonic pulse bumped each time a [ControlCubit.clearAll] leaves at
  /// least one track holding a clear restore point. NOT stored intent — an
  /// emitted-once cue a surface listens for (the tracks view's post-clear-all
  /// undo toast), the same one-shot-in-state shape `SessionState.outcome`
  /// uses. It carries no set: undo-clear-all is derived from live
  /// `Track.clearRestore`, so the pulse only needs to say "it happened".
  /// Never invalidated — a sequence number, only ever incremented.
  final int clearAllPulse;

  /// The remap actually in force: the session's when it has ANY bindings, the
  /// globals otherwise (A12). Derived, never stored — so the two copies can
  /// never disagree about which one applies.
  PedalBindingSet get bindings =>
      globalBindings.resolveAgainst(sessionBindings);

  /// The binding reaching the chain at [address], if any, and whether a
  /// momentary is holding it right now — what the Signal surface's stomp chip
  /// renders (R25).
  ///
  /// Matches on the target's CHAIN address, so a binding on one slot inside a
  /// chain still marks that chain as pedal-reachable: the chip answers "can I
  /// stomp this from the plate", which a per-slot binding does satisfy. A
  /// STALE binding never matches — its target does not decode to an address at
  /// all, so it marks nothing, which is the same silence its unlit LED gives
  /// the performer.
  /// When several controls reach one chain, a HELD one wins the report. The
  /// held marker explains an enabled state the user cannot undo by clicking,
  /// so answering with a different, unheld binding would leave exactly that
  /// state unexplained; which control gets named matters less than whether a
  /// foot is on one.
  ({PedalBinding binding, bool held})? stompFor(FxAddress address) {
    PedalBinding? first;
    for (final binding in bindings.bindings) {
      if (binding.decodeTarget()?.address != address) continue;
      if (heldMomentary.contains(binding.key)) {
        return (binding: binding, held: true);
      }
      first ??= binding;
    }
    return first == null ? null : (binding: first, held: false);
  }

  /// The first channel of the visible bank (`0` for A, `4` for B).
  int get bankBaseChannel => activeBank * tracksPerBank;

  /// Whether [channel] falls within the visible bank.
  bool bankContains(int channel) =>
      channel >= bankBaseChannel && channel < bankBaseChannel + tracksPerBank;

  /// The binding carried by the footswitch that sits over [channel]'s cell, or
  /// null when the cell is off the visible bank or its switch is unbound.
  ///
  /// The plate has four per-track footswitches, so a cell's channel maps
  /// BANK-LOCALLY onto `track1..4` — the same map [ControlCubit] presses
  /// through. This is the ONE answer to "what does this cell drive?", shared
  /// by every surface that asks: the FX-mode cell's dressing, its tap, and the
  /// `1`–`8` keys. Resolving it twice is how a cell comes to draw one chain
  /// and flip another (#884).
  PedalBinding? fxCellBinding(int channel) {
    final button = switch (channel - bankBaseChannel) {
      0 => PedalButton.track1,
      1 => PedalButton.track2,
      2 => PedalButton.track3,
      3 => PedalButton.track4,
      _ => null,
    };
    return button == null ? null : bindings.lookup(button, bank: activeBank);
  }

  /// Returns a copy with the given fields replaced.
  ControlState copyWith({
    InteractionMode? mode,
    InteractionMode? defaultMode,
    ModeSwitchStyle? modeSwitchStyle,
    int? cursor,
    int? activeBank,
    Set<int>? excluded,
    Set<int>? parkedResume,
    PedalBindingSet? globalBindings,
    PedalBindingSet? sessionBindings,
    Set<PedalBindingKey>? heldMomentary,
    ControllerBindingSet? controllerBindings,
    ControllerLearn? controllerLearn,
    bool clearControllerLearn = false,
    int? clearAllPulse,
  }) => ControlState(
    mode: mode ?? this.mode,
    defaultMode: defaultMode ?? this.defaultMode,
    modeSwitchStyle: modeSwitchStyle ?? this.modeSwitchStyle,
    cursor: cursor ?? this.cursor,
    activeBank: activeBank ?? this.activeBank,
    excluded: excluded ?? this.excluded,
    parkedResume: parkedResume ?? this.parkedResume,
    globalBindings: globalBindings ?? this.globalBindings,
    sessionBindings: sessionBindings ?? this.sessionBindings,
    heldMomentary: heldMomentary ?? this.heldMomentary,
    controllerBindings: controllerBindings ?? this.controllerBindings,
    // `clearControllerLearn` exists because a capture ENDING is a real edit:
    // `??` alone could never write the null that "nothing is listening" is.
    controllerLearn: clearControllerLearn
        ? null
        : controllerLearn ?? this.controllerLearn,
    clearAllPulse: clearAllPulse ?? this.clearAllPulse,
  );

  @override
  List<Object?> get props => [
    mode,
    defaultMode,
    modeSwitchStyle,
    cursor,
    activeBank,
    excluded,
    parkedResume,
    globalBindings,
    sessionBindings,
    heldMomentary,
    controllerBindings,
    controllerLearn,
    clearAllPulse,
  ];
}
