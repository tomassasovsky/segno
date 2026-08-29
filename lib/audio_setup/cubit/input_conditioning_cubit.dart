import 'package:bloc/bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:settings_repository/settings_repository.dart';

/// Per-hardware-input conditioning + loop-close restoration configuration
/// (#697).
///
/// [enabled] plus the five conditioning parameters drive the engine's fixed
/// zero-added-latency conditioning stage (HPF + mains-hum notches + downward
/// expander) on this input; the parameters are carried in their real units
/// (Hz / dB / ms / ratio), matching the engine's `le_cond_param` surface. The
/// two `restore*` flags are the offline loop-close restoration opt-in — held
/// and persisted here (the restoration worker and its loop-close trigger policy
/// land in later slices), never applied to the live audio path.
///
/// Every default matches both the plan's persistence table and the engine's own
/// defaults, so a never-configured input reads and behaves identically whether
/// or not it has ever been touched.
class InputConditioning extends Equatable {
  /// Creates an [InputConditioning] for [input].
  const InputConditioning({
    required this.input,
    this.enabled = false,
    this.hpfHz = 40,
    this.humHz = 50,
    this.humHarmonics = 4,
    this.expThresholdDb = -55,
    this.expRatio = 2,
    this.expReleaseMs = 150,
    this.restoreDeclip = false,
    this.restoreDenoise = false,
  });

  /// The hardware input this configuration applies to.
  final int input;

  /// Whether the conditioning stage runs on this input.
  final bool enabled;

  /// High-pass cutoff in Hz (`0` = HPF section off).
  final double hpfHz;

  /// Mains-hum base frequency in Hz — `50` / `60` (`0` = hum section off).
  final int humHz;

  /// Number of hum notches, base included (`1..8`).
  final int humHarmonics;

  /// Downward-expander threshold in dB.
  final double expThresholdDb;

  /// Downward-expander ratio (`1:N`).
  final double expRatio;

  /// Downward-expander release in ms.
  final double expReleaseMs;

  /// Whether loop-close de-clip restoration is opted in for this input.
  final bool restoreDeclip;

  /// Whether loop-close denoise restoration is opted in for this input.
  final bool restoreDenoise;

  /// The `input_restore.N` flag bitmask (`1` = denoise, `2` = declip).
  int get restoreFlags => (restoreDenoise ? 1 : 0) | (restoreDeclip ? 2 : 0);

  /// Returns a copy with the given overrides.
  InputConditioning copyWith({
    bool? enabled,
    double? hpfHz,
    int? humHz,
    int? humHarmonics,
    double? expThresholdDb,
    double? expRatio,
    double? expReleaseMs,
    bool? restoreDeclip,
    bool? restoreDenoise,
  }) => InputConditioning(
    input: input,
    enabled: enabled ?? this.enabled,
    hpfHz: hpfHz ?? this.hpfHz,
    humHz: humHz ?? this.humHz,
    humHarmonics: humHarmonics ?? this.humHarmonics,
    expThresholdDb: expThresholdDb ?? this.expThresholdDb,
    expRatio: expRatio ?? this.expRatio,
    expReleaseMs: expReleaseMs ?? this.expReleaseMs,
    restoreDeclip: restoreDeclip ?? this.restoreDeclip,
    restoreDenoise: restoreDenoise ?? this.restoreDenoise,
  );

  @override
  List<Object?> get props => [
    input,
    enabled,
    hpfHz,
    humHz,
    humHarmonics,
    expThresholdDb,
    expRatio,
    expReleaseMs,
    restoreDeclip,
    restoreDenoise,
  ];
}

/// The per-input conditioning + restoration configurations, keyed by hardware
/// input index. Inputs absent from [inputs] are not configured (a default,
/// stage-off [InputConditioning] synthesized by [forInput]).
class InputConditioningState extends Equatable {
  /// Creates an [InputConditioningState] from a map of input index to config.
  const InputConditioningState({this.inputs = const {}});

  /// The configured inputs, keyed by hardware input index.
  final Map<int, InputConditioning> inputs;

  /// The configuration for [input], or a default (stage-off) one when none is
  /// configured.
  InputConditioning forInput(int input) =>
      inputs[input] ?? InputConditioning(input: input);

  /// Whether [input] has a saved configuration, as opposed to the synthesized
  /// default [forInput] returns.
  bool hasInput(int input) => inputs.containsKey(input);

  /// Returns a copy with [config] replacing its input's entry.
  InputConditioningState withInput(InputConditioning config) =>
      InputConditioningState(inputs: {...inputs, config.input: config});

  @override
  List<Object?> get props => [inputs];
}

/// Owns the per-input conditioning + restoration configuration: applies the
/// conditioning stage to the [LooperRepository] and persists everything via
/// [SettingsRepository] (#697 S4).
///
/// The live HOT / conditioning-active indicators a UI reads are NOT held here —
/// they ride `LooperState.status` (`EngineStatus.inputClipMask` /
/// `inputCondMask`, with the `isInputHot` helper), projected from the engine
/// snapshot on the render timer. This cubit owns the WRITE side (the config the
/// player sets) and the persistence.
class InputConditioningCubit extends Cubit<InputConditioningState> {
  /// Creates an [InputConditioningCubit] driving [repository], persisted
  /// through [settings].
  InputConditioningCubit({
    required LooperRepository repository,
    required SettingsRepository settings,
  }) : _repository = repository,
       _settings = settings,
       super(const InputConditioningState());

  final LooperRepository _repository;
  final SettingsRepository _settings;
  Future<void>? _loadFuture;

  /// Restores the persisted per-input conditioning + restoration configuration
  /// and applies the conditioning stage to the repository. Idempotent — the
  /// restore runs at most once.
  Future<void> load() => _loadFuture ??= _restore();

  Future<void> _restore() async {
    final restored = <int, InputConditioning>{};
    for (var input = 0; input < kMaxMonitoredInputs; input++) {
      final config = await _restoreInput(input);
      if (config != null) restored[input] = config;
    }
    if (isClosed) return;
    // Nothing persisted: keep the initial (empty) state rather than emitting an
    // equivalent one, so a fresh rig produces no state churn on boot.
    if (restored.isEmpty) return;
    emit(InputConditioningState(inputs: restored));
    // Apply only the CONDITIONING half to the engine (the restoration opt-in is
    // consumed by a later slice's loop-close trigger, not the live path). The
    // repository remembers the intent and re-applies it on every device
    // (re)start, so this boot-time push survives later reconfigures.
    restored.values.forEach(_applyConditioning);
  }

  /// Reads hardware [input]'s persisted configuration, or `null` when nothing
  /// was ever saved for it (neither a conditioning key nor the restore key), so
  /// an untouched input is never materialized into state.
  Future<InputConditioning?> _restoreInput(int input) async {
    final enabled = await _settings.loadInputConditioningEnabled(input);
    final hpfHz = await _settings.loadInputConditioningHpfHz(input);
    final humHz = await _settings.loadInputConditioningHumHz(input);
    final humHarmonics = await _settings.loadInputConditioningHumHarmonics(
      input,
    );
    final expThresholdDb = await _settings.loadInputConditioningExpThresholdDb(
      input,
    );
    final expRatio = await _settings.loadInputConditioningExpRatio(input);
    final expReleaseMs = await _settings.loadInputConditioningExpReleaseMs(
      input,
    );
    final restoreFlags = await _settings.loadInputRestore(input);

    final anySaved =
        enabled != null ||
        hpfHz != null ||
        humHz != null ||
        humHarmonics != null ||
        expThresholdDb != null ||
        expRatio != null ||
        expReleaseMs != null ||
        restoreFlags != null;
    if (!anySaved) return null;

    final flags = restoreFlags ?? 0;
    // Defaults live in the model's constructor — a null key reads as the
    // documented default rather than a magic number here.
    return InputConditioning(
      input: input,
      enabled: enabled ?? false,
      hpfHz: hpfHz ?? 40,
      humHz: humHz ?? 50,
      humHarmonics: humHarmonics ?? 4,
      expThresholdDb: expThresholdDb ?? -55,
      expRatio: expRatio ?? 2,
      expReleaseMs: expReleaseMs ?? 150,
      restoreDeclip: flags & 2 != 0,
      restoreDenoise: flags & 1 != 0,
    );
  }

  /// Pushes [config]'s conditioning parameters, then its enable flag, to the
  /// repository (parameters first so the enable establishes the stage with its
  /// values already in place). The restoration opt-in is deliberately NOT
  /// pushed — it drives an offline pass, not the live audio path.
  void _applyConditioning(InputConditioning config) {
    final input = config.input;
    _repository
      ..setInputConditioningParam(
        input: input,
        param: InputConditioningParam.hpfHz,
        value: config.hpfHz,
      )
      ..setInputConditioningParam(
        input: input,
        param: InputConditioningParam.humHz,
        value: config.humHz.toDouble(),
      )
      ..setInputConditioningParam(
        input: input,
        param: InputConditioningParam.humHarmonics,
        value: config.humHarmonics.toDouble(),
      )
      ..setInputConditioningParam(
        input: input,
        param: InputConditioningParam.expThresholdDb,
        value: config.expThresholdDb,
      )
      ..setInputConditioningParam(
        input: input,
        param: InputConditioningParam.expRatio,
        value: config.expRatio,
      )
      ..setInputConditioningParam(
        input: input,
        param: InputConditioningParam.expReleaseMs,
        value: config.expReleaseMs,
      )
      ..setInputConditioningEnabled(input: input, enabled: config.enabled);
  }

  /// Enables or disables [input]'s conditioning stage, applying and persisting
  /// the change.
  Future<void> setEnabled(int input, {required bool enabled}) async {
    emit(state.withInput(state.forInput(input).copyWith(enabled: enabled)));
    _repository.setInputConditioningEnabled(input: input, enabled: enabled);
    await _settings.saveInputConditioningEnabled(input, enabled: enabled);
  }

  /// Sets and persists [input]'s conditioning high-pass cutoff in Hz.
  Future<void> setHpfHz(int input, double hz) async {
    emit(state.withInput(state.forInput(input).copyWith(hpfHz: hz)));
    _repository.setInputConditioningParam(
      input: input,
      param: InputConditioningParam.hpfHz,
      value: hz,
    );
    await _settings.saveInputConditioningHpfHz(input, hz);
  }

  /// Sets and persists [input]'s conditioning mains-hum base frequency in Hz.
  Future<void> setHumHz(int input, int hz) async {
    emit(state.withInput(state.forInput(input).copyWith(humHz: hz)));
    _repository.setInputConditioningParam(
      input: input,
      param: InputConditioningParam.humHz,
      value: hz.toDouble(),
    );
    await _settings.saveInputConditioningHumHz(input, hz);
  }

  /// Sets and persists [input]'s conditioning hum-notch count (base included).
  Future<void> setHumHarmonics(int input, int count) async {
    emit(state.withInput(state.forInput(input).copyWith(humHarmonics: count)));
    _repository.setInputConditioningParam(
      input: input,
      param: InputConditioningParam.humHarmonics,
      value: count.toDouble(),
    );
    await _settings.saveInputConditioningHumHarmonics(input, count);
  }

  /// Sets and persists [input]'s conditioning expander threshold in dB.
  Future<void> setExpThresholdDb(int input, double db) async {
    emit(state.withInput(state.forInput(input).copyWith(expThresholdDb: db)));
    _repository.setInputConditioningParam(
      input: input,
      param: InputConditioningParam.expThresholdDb,
      value: db,
    );
    await _settings.saveInputConditioningExpThresholdDb(input, db);
  }

  /// Sets and persists [input]'s conditioning expander ratio (`1:N`).
  Future<void> setExpRatio(int input, double ratio) async {
    emit(state.withInput(state.forInput(input).copyWith(expRatio: ratio)));
    _repository.setInputConditioningParam(
      input: input,
      param: InputConditioningParam.expRatio,
      value: ratio,
    );
    await _settings.saveInputConditioningExpRatio(input, ratio);
  }

  /// Sets and persists [input]'s conditioning expander release in ms.
  Future<void> setExpReleaseMs(int input, double ms) async {
    emit(state.withInput(state.forInput(input).copyWith(expReleaseMs: ms)));
    _repository.setInputConditioningParam(
      input: input,
      param: InputConditioningParam.expReleaseMs,
      value: ms,
    );
    await _settings.saveInputConditioningExpReleaseMs(input, ms);
  }

  /// Sets and persists [input]'s loop-close restoration opt-in. Persisted and
  /// held only — the offline restoration worker and its loop-close trigger are
  /// later slices, so nothing is pushed to the live audio path here.
  Future<void> setRestore(
    int input, {
    required bool declip,
    required bool denoise,
  }) async {
    final next = state
        .forInput(input)
        .copyWith(restoreDeclip: declip, restoreDenoise: denoise);
    emit(state.withInput(next));
    await _settings.saveInputRestore(input, next.restoreFlags);
  }
}
