import 'package:controller_repository/controller_repository.dart';
import 'package:equatable/equatable.dart';
import 'package:segno/control/binding/control_value_target.dart';

/// The MIDI mapping editor's unsaved edit.
///
/// A [MidiMapping] needs a source; a draft does not have one until Learn
/// hears a control, and the editor is open before that. Every edit here is
/// one the accepted editor makes, with the rule it follows, so the page only
/// decides WHEN to make one.
class MidiMappingDraft extends Equatable {
  /// Creates a [MidiMappingDraft] for a new mapping on [device].
  factory MidiMappingDraft({
    required String device,
    String? id,
    MidiSource? source,
    MidiBehavior behavior = MidiBehavior.continuous,
    List<MidiControl> controls = const [],
  }) => MidiMappingDraft._(
    device: device,
    id: id,
    source: source,
    behavior: behavior,
    controls: List.unmodifiable(controls.map(_settled)),
  );

  const MidiMappingDraft._({
    required this.device,
    required this.behavior,
    required this.controls,
    this.id,
    this.source,
  });

  /// A draft of the saved [mapping].
  factory MidiMappingDraft.of(MidiMapping mapping) => MidiMappingDraft(
    device: mapping.source.device,
    id: mapping.id,
    source: mapping.source,
    behavior: mapping.behavior,
    controls: mapping.controls,
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
    if (learned.device != device) return this;
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
    return _copy(
      source: MidiSource(
        device: learned.device,
        kind: learned.kind,
        number: learned.number,
        channel: channel,
        protocol: learned.protocol,
        parameter: learned.parameter,
        bank: learned.bank,
      ),
    );
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
      behavior: action && behavior == MidiBehavior.continuous && !isProgram
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

  /// Repoints an unavailable action in place, preserving its edge.
  MidiMappingDraft repointingAction(String key, String replacement) {
    if (key != replacement && controls.any((c) => c.key == replacement)) {
      return this;
    }
    return _copy(
      controls: [
        for (final control in controls)
          if (control is MidiActionControl && control.key == key)
            MidiActionControl(key: replacement, trigger: control.trigger)
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
  /// before a control is learned. Whether it is enabled is the power
  /// button's, not the editor's: a new mapping is on, and saving an existing
  /// one keeps what it was.
  MidiMapping? toMapping(String newId, {bool enabled = true}) {
    final learned = source;
    if (learned == null) return null;
    if (MidiMapping.problemFor(learned, behavior, controls) != null ||
        {for (final control in controls) control.key}.length !=
            controls.length) {
      return null;
    }
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
    final mapping = toMapping('draft');
    return mapping != null &&
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
  );

  /// A parameter control's endpoints as its target reads them: a level
  /// fader's literal 1.0 is unity at authoring, as it is at load.
  static MidiControl _settled(MidiControl control) =>
      switch ((control, ControlValueTarget.tryParse(control.key))) {
        (final MidiParameterControl parameter, final target?)
            when target.decodeEndpoint(parameter.low) != parameter.low ||
                target.decodeEndpoint(parameter.high) != parameter.high =>
          parameter.copyWith(
            low: target.decodeEndpoint(parameter.low),
            high: target.decodeEndpoint(parameter.high),
          ),
        _ => control,
      };

  @override
  List<Object?> get props => [device, id, source, behavior, controls];
}
