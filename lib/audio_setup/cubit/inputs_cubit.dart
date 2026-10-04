import 'package:bloc/bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/audio_setup/application/port_aliases.dart';
import 'package:segno/audio_setup/cubit/alias_rename_result.dart';
import 'package:settings_repository/settings_repository.dart';

part 'inputs_state.dart';

/// What the player calls each hardware input, per interface.
///
/// Modelled on `TracksCubit` because it is the same problem one level down the
/// signal path: the interface says input 2 and the player says "mic". Two
/// things are NOT copies of it:
///
/// **Names belong to the DEVICE**, not to the socket number. Input 1 on a
/// Scarlett and input 1 on the built-in pair are different jacks with different
/// things plugged into them, and one name for both describes whichever rig was
/// patched last. Keyed off the engine's reported device name, the same shape
/// `latency_offset.$device.$rate.$buffer` already uses.
///
/// **There is no ceiling.** An earlier version stopped at the engine constant
/// now called `LE_MAX_MONITORED_INPUTS`, on the reading that a socket past it
/// was unusable. It caps which inputs the monitor path covers — a
/// higher-numbered channel is still recordable, so it is still worth naming
/// (#558). The list follows whatever the device reports.
///
/// One persisted map and nothing else. Provided at app level and loaded once,
/// because an input is called what the player calls it on every surface that
/// shows one — the Audio face's input chips, the Tracks routing summary and the
/// per-track lane list all read the same names through `l10n.inputName`.
class InputsCubit extends Cubit<InputsState> {
  /// Creates an [InputsCubit] that follows [repository]'s open device.
  InputsCubit({
    required SettingsRepository settings,
    required LooperRepository repository,
  }) : super(const InputsState()) {
    _aliases = PortAliases(
      settings: settings,
      repository: repository,
      kind: PortAliasKind.input,
      probeCeiling: InputsState.probeCeiling,
      onChanged: (snapshot) => emit(
        InputsState(
          device: snapshot.device,
          names: snapshot.names,
          lifetime: snapshot.lifetime,
        ),
      ),
    );
  }

  late final PortAliases _aliases;

  /// Durably renames [input] for the current device opening.
  Future<void> rename(
    int input,
    String name, {
    int? expectedLifetime,
    void Function(AliasRenameResult)? onResult,
  }) async {
    final result = await _aliases.rename(
      input,
      name,
      expectedLifetime: expectedLifetime,
    );
    onResult?.call(result);
  }

  /// Re-reads one uncertain key before another edit may use it.
  Future<void> retryAliasRecovery(int input) =>
      _aliases.retryAliasRecovery(input);

  @override
  Future<void> close() async {
    await _aliases.close();
    await super.close();
  }
}
