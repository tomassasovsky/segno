import 'package:controller_repository/controller_repository.dart';
import 'package:equatable/equatable.dart';

/// The MIDI mapping editor's unsaved edit.
///
/// A [MidiMapping] needs a source; a draft does not have one until Learn
/// hears a control, and the editor is open before that. Every edit here is
/// one the accepted editor makes, with the rule it follows, so the page only
/// decides WHEN to make one.
class MidiMappingDraft extends Equatable {
  /// Creates a [MidiMappingDraft] for a new mapping on [device].
  const MidiMappingDraft({
    required this.device,
    this.id,
    this.source,
    this.behavior = MidiBehavior.continuous,
    this.controls = const [],
    this.enabled = true,
  });

  /// A draft of the saved [mapping].
  factory MidiMappingDraft.of(MidiMapping mapping) => MidiMappingDraft(
    device: mapping.source.device,
    id: mapping.id,
    source: mapping.source,
    behavior: mapping.behavior,
    controls: mapping.controls,
    enabled: mapping.enabled,
  );

  /// The device the mapping listens to.
  final String device;

  /// The saved mapping this edits, or `null` for a new one.
  final String? id;

  /// The learned control, or `null` before Learn has heard one.
  final MidiSource? source;

  /// How its messages drive the [controls].
  final MidiBehavior behavior;

  /// Everything it drives, in the order it was added.
  final List<MidiControl> controls;

  /// Whether the saved mapping dispatches. The editor keeps what it was.
  final bool enabled;

  /// Whether a control in [protocol] can run an action. A 14-bit, NRPN or
  /// relative control carries a position, not a press.
  static bool carriesActions(MidiProtocol protocol) =>
      protocol == MidiProtocol.standard || protocol == MidiProtocol.bankProgram;

  /// Whether any control is an action.
  bool get drivesActions => controls.any((c) => c is MidiActionControl);

  /// Whether the learned control is a Program Change.
  bool get isProgram => source?.kind == ControllerSourceKind.midiProgram;

  /// Whether the editor offers Knob / fader or Button: only a plain CC can be
  /// either.
  bool get offersKnobOrButton =>
      source?.protocol == MidiProtocol.standard &&
      source?.kind == ControllerSourceKind.midiCc;

  /// Whether the editor offers Momentary or Toggle: a button that is not a
  /// Program, which has no release to hold for.
  bool get offersButtonBehavior =>
      source != null && behavior != MidiBehavior.continuous && !isProgram;

  /// This draft reading the control Learn heard.
  ///
  /// The behavior starts again from what the control fits. A Program has no
  /// release, so every action it drives runs on the press.
  MidiMappingDraft learned(MidiSource learned) {
    final program = learned.kind == ControllerSourceKind.midiProgram;
    return _copy(
      source: learned,
      behavior: MidiMapping.defaultBehavior(
        learned,
        drivesActions: drivesActions,
      ),
      controls: [
        for (final control in controls)
          if (program && control is MidiActionControl)
            MidiActionControl(key: control.key)
          else
            control,
      ],
    );
  }

  /// This draft on [channel] `0..15`, or on All when `null`.
  MidiMappingDraft withChannel(int? channel) {
    final learned = source;
    if (learned == null) return this;
    return _copy(source: learned.withChannel(channel));
  }

  /// This draft with [behavior].
  MidiMappingDraft withBehavior(MidiBehavior behavior) =>
      _copy(behavior: behavior);

  /// This draft driving [control] as well. A key it already drives is not
  /// added twice. An action makes a knob a button, since an action needs a
  /// press; on a Program it runs on the press.
  MidiMappingDraft withControl(MidiControl control) {
    if (controls.any((c) => c.key == control.key)) return this;
    final action = control is MidiActionControl;
    return _copy(
      controls: [
        ...controls,
        if (action && isProgram)
          MidiActionControl(key: control.key)
        else
          control,
      ],
      behavior: action && behavior == MidiBehavior.continuous
          ? MidiBehavior.momentary
          : behavior,
    );
  }

  /// This draft with the parameter [key] pointed at [replacement], keeping its
  /// place and its range — Change control and Repair control.
  MidiMappingDraft repointing(String key, String replacement) {
    if (key != replacement && controls.any((c) => c.key == replacement)) {
      return this;
    }
    return _copy(
      controls: [
        for (final control in controls)
          if (control is MidiParameterControl && control.key == key)
            MidiParameterControl(
              key: replacement,
              low: control.low,
              high: control.high,
            )
          else
            control,
      ],
    );
  }

  /// This draft without the control [key].
  MidiMappingDraft without(String key) => _copy(
    controls: [
      for (final c in controls)
        if (c.key != key) c,
    ],
  );

  /// This draft with the parameter [key]'s range moved.
  MidiMappingDraft withRange(String key, {double? low, double? high}) => _copy(
    controls: [
      for (final control in controls)
        if (control is MidiParameterControl && control.key == key)
          control.copyWith(low: low, high: high)
        else
          control,
    ],
  );

  /// This draft running the action [key] on [trigger].
  MidiMappingDraft withTrigger(String key, MidiEdge trigger) => _copy(
    controls: [
      for (final control in controls)
        if (control is MidiActionControl && control.key == key)
          MidiActionControl(key: key, trigger: trigger)
        else
          control,
    ],
  );

  /// The mapping this draft saves as, given [newId] for a new one, or `null`
  /// before a control is learned.
  MidiMapping? toMapping(String newId) {
    final learned = source;
    if (learned == null) return null;
    return MidiMapping(
      id: id ?? newId,
      source: learned,
      behavior: behavior,
      controls: controls,
      enabled: enabled,
    );
  }

  /// The saved mapping in [set] this draft's control overlaps, other than the
  /// one it edits, or `null`.
  MidiMapping? conflictIn(MidiMappingSet set) {
    final learned = source;
    if (learned == null) return null;
    return set.conflictWith(learned, exceptId: id);
  }

  /// Whether Save can be offered against [set]: a control is learned, it
  /// overlaps nothing, and the mapping it makes can be saved as it stands.
  bool canSaveIn(MidiMappingSet set) {
    final mapping = toMapping(set.nextId);
    return mapping != null &&
        mapping.problem == null &&
        set.conflictWith(mapping.source, exceptId: id) == null;
  }

  MidiMappingDraft _copy({
    MidiSource? source,
    MidiBehavior? behavior,
    List<MidiControl>? controls,
  }) => MidiMappingDraft(
    device: device,
    id: id,
    source: source ?? this.source,
    behavior: behavior ?? this.behavior,
    controls: List.unmodifiable(controls ?? this.controls),
    enabled: enabled,
  );

  @override
  List<Object?> get props => [device, id, source, behavior, controls, enabled];
}
