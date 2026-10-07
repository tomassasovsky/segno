import 'package:bloc/bloc.dart';
import 'package:brightness_client/brightness_client.dart';
import 'package:equatable/equatable.dart';
import 'package:segno/appliance/display_role.dart';
import 'package:segno/appliance/software_brightness.dart';
import 'package:settings_repository/settings_repository.dart';

/// What each panel is set to and shows.
class DisplayBrightnessState extends Equatable {
  /// Creates a [DisplayBrightnessState].
  const DisplayBrightnessState({
    this.levels = const {
      DisplayRole.track: kDefaultDisplayBrightness,
      DisplayRole.main: kDefaultDisplayBrightness,
    },
    this.hardware = const {},
    this.dimmed = false,
  });

  /// Each panel's set brightness, `kMinDisplayBrightness..1`.
  final Map<DisplayRole, double> levels;

  /// The panels that take brightness over DDC/CI. Every other panel is
  /// dimmed by a software filter over its window.
  final Set<DisplayRole> hardware;

  /// Whether the console is idle-dimmed.
  final bool dimmed;

  /// [role]'s set brightness.
  double levelOf(DisplayRole role) => levels[role] ?? kDefaultDisplayBrightness;

  /// What [role]'s panel shows: its setting, or its idle dim.
  double shownOf(DisplayRole role) =>
      shownBrightness(levelOf(role), dimmed: dimmed);

  /// The software filter over [role]'s window: none where the panel dims
  /// itself, what it shows everywhere else.
  double softwareOf(DisplayRole role) =>
      hardware.contains(role) ? 1 : shownOf(role);

  /// A copy with the given fields replaced.
  DisplayBrightnessState copyWith({
    Map<DisplayRole, double>? levels,
    Set<DisplayRole>? hardware,
    bool? dimmed,
  }) => DisplayBrightnessState(
    levels: levels ?? this.levels,
    hardware: hardware ?? this.hardware,
    dimmed: dimmed ?? this.dimmed,
  );

  @override
  List<Object?> get props => [levels, hardware, dimmed];
}

/// Each panel's brightness, and the idle dim over both.
///
/// A panel whose connector answers DDC/CI is set through the host helper,
/// on that connector only; any other panel is dimmed in software over its
/// own window (the main window here, the Track display window through its
/// channel).
class DisplayBrightnessCubit extends Cubit<DisplayBrightnessState> {
  /// Creates a [DisplayBrightnessCubit].
  DisplayBrightnessCubit({
    required SettingsRepository settings,
    BrightnessClient client = const UnsupportedBrightnessClient(),
    DisplayOutputs outputs = const UnknownDisplayOutputs(),
  }) : _settings = settings,
       _client = client,
       _outputs = outputs,
       super(const DisplayBrightnessState());

  final SettingsRepository _settings;
  final BrightnessClient _client;
  final DisplayOutputs _outputs;
  Future<void>? _loadFuture;
  Map<DisplayRole, String> _connectors = const {};

  /// The latest value each hardware panel should show, and the panels with
  /// a helper call in flight: a drag sends one call at a time per panel and
  /// always ends on the last value, rather than queueing a call per frame.
  final _hardwareWanted = <DisplayRole, double>{};
  final _hardwareBusy = <DisplayRole>{};

  /// Restores each panel's level, finds its connector and probes DDC/CI.
  Future<void> load() => _loadFuture ??= _restore();

  Future<void> _restore() async {
    final levels = {
      for (final role in DisplayRole.values)
        role: await _settings.loadDisplayBrightness(role),
    };
    // The saved levels show at once, in software; probing a panel without
    // DDC/CI can take seconds.
    if (isClosed) return;
    emit(state.copyWith(levels: levels));
    _connectors = displayConnectors(await _outputs.appIdConnectors());
    final hardware = <DisplayRole>{};
    for (final MapEntry(key: role, value: connector) in _connectors.entries) {
      try {
        if (await _client.isSupported(connector)) hardware.add(role);
      } on Object {
        // Unprobed is unsupported: the software filter still applies.
      }
    }
    if (isClosed) return;
    emit(state.copyWith(hardware: hardware));
    for (final role in hardware) {
      await _applyHardware(role);
    }
  }

  /// Sets [role]'s panel to [value] (clamped into the range), shows it at
  /// once and saves it. Throws when the save fails; the panel keeps the new
  /// level either way.
  Future<void> setBrightness(DisplayRole role, double value) async {
    final clamped = clampDisplayBrightness(value);
    if (clamped != state.levelOf(role)) {
      emit(state.copyWith(levels: {...state.levels, role: clamped}));
    }
    await _applyHardware(role);
    await _settings.saveDisplayBrightness(role, clamped);
  }

  /// Dims both panels to their idle level, or brings them back.
  void setDimmed({required bool dimmed}) {
    if (dimmed == state.dimmed) return;
    emit(state.copyWith(dimmed: dimmed));
    for (final role in state.hardware) {
      // Not awaited: the software side already changed, and a panel's
      // helper call never blocks the other's.
      _applyHardware(role).ignore();
    }
  }

  /// DDC/CI drops the odd transaction; one retry before giving up a panel.
  Future<void> _setRetrying(String connector, double value) async {
    try {
      await _client.set(connector, value);
    } on Object {
      await _client.set(connector, value);
    }
  }

  Future<void> _applyHardware(DisplayRole role) async {
    final connector = _connectors[role];
    if (connector == null || !state.hardware.contains(role)) return;
    _hardwareWanted[role] = state.shownOf(role);
    if (!_hardwareBusy.add(role)) return;
    try {
      double? sent;
      while (_hardwareWanted[role] != sent && !isClosed) {
        final next = _hardwareWanted[role]!;
        sent = next;
        await _setRetrying(connector, next);
      }
    } on Object {
      // The panel stopped answering: dim its window in software instead,
      // so the setting still shows. Its backlight may be left at whatever
      // it last took (the idle level, say), under the software filter, so
      // ask once more for full before handing over.
      try {
        await _client.set(connector, 1);
      } on Object {
        // Unreachable: the software filter is all that is left.
      }
      if (!isClosed) {
        emit(state.copyWith(hardware: {...state.hardware}..remove(role)));
      }
    } finally {
      _hardwareBusy.remove(role);
    }
  }
}
