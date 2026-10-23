import 'package:bloc/bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/audio_setup/application/port_aliases.dart';
import 'package:segno/audio_setup/cubit/alias_rename_result.dart';
import 'package:settings_repository/settings_repository.dart';

part 'outputs_state.dart';

/// What the player calls each destination of the open interface.
///
/// Like input aliases, names belong
/// to the DEVICE, because outputs 3 and 4 on a Scarlett and on the built-in
/// pair drive different things.
///
/// The one difference is the unit. An input is a jack; a destination is a
/// PAIR of jacks (bus `k` = outputs `2k` and `2k+1`), which is what the player
/// patches, names and sends a track to. Naming the jacks separately would ask
/// for two names for one cable pair and leave every routing surface to guess
/// which of them to show.
class OutputsCubit extends Cubit<OutputsState> {
  /// Creates an [OutputsCubit] that follows [repository]'s open device.
  OutputsCubit({
    required SettingsRepository settings,
    required LooperRepository repository,
  }) : super(const OutputsState()) {
    _aliases = PortAliases(
      settings: settings,
      repository: repository,
      kind: PortAliasKind.output,
      probeCeiling: OutputsState.probeCeiling,
      onChanged: (snapshot) => emit(
        OutputsState(
          device: snapshot.device,
          names: snapshot.names,
          lifetime: snapshot.lifetime,
        ),
      ),
    );
  }

  late final PortAliases _aliases;

  /// Durably renames [bus] for the current device opening.
  Future<void> rename(
    int bus,
    String name, {
    int? expectedLifetime,
    void Function(AliasRenameResult)? onResult,
  }) async {
    final result = await _aliases.rename(
      bus,
      name,
      expectedLifetime: expectedLifetime,
    );
    onResult?.call(result);
  }

  /// Re-reads one uncertain key before another edit may use it.
  Future<void> retryAliasRecovery(int bus) => _aliases.retryAliasRecovery(bus);

  @override
  Future<void> close() async {
    await _aliases.close();
    await super.close();
  }
}
