import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:performance_repository/performance_repository.dart';
import 'package:segno/app/fx_chain_persistence.dart';
import 'package:segno/app/mix_settings_coordinator.dart';
import 'package:segno/appliance/power_off/power_off_cubit.dart';
import 'package:segno/appliance/power_off/power_off_host.dart';
import 'package:segno/control/control.dart';
import 'package:segno/looper/bloc/looper_bloc.dart';
import 'package:segno/looper/cubit/playback_options_cubit.dart';
import 'package:segno/looper/cubit/record_options_cubit.dart';
import 'package:segno/looper/cubit/tempo_cubit.dart';
import 'package:segno/looper/view/session_persistence_sync_listener.dart';
import 'package:segno/looper/view/tracks_view.dart';
import 'package:segno/session/session.dart';
import 'package:session_repository/session_repository.dart';
import 'package:settings_repository/settings_repository.dart';

/// Entry point for the looper feature.
///
/// Provides a [LooperBloc] backed by the shared [LooperRepository] and a
/// [SessionCubit] for save/load/export (backed by the shared
/// [SessionRepository]), then renders the Tracks view. The
/// `TracksCubit` is provided app-wide so the settings page can reach it.
class LooperPage extends StatelessWidget {
  /// Creates a [LooperPage].
  ///
  /// [exportDirectory] resolves the directory a mixdown / stems export is
  /// written to. Named sessions live under the repository's own catalog root.
  const LooperPage({required this.exportDirectory, super.key});

  /// Resolves the mixdown / stems export directory (a sibling of the named
  /// sessions catalog under the app documents folder).
  final Future<String> Function() exportDirectory;

  @override
  Widget build(BuildContext context) {
    return MultiBlocProvider(
      providers: [
        BlocProvider(
          create: (context) => LooperBloc(
            decayControl: context.read<PlaybackOptionsCubit>(),
            oneShotControl: context.read<PlaybackOptionsCubit>(),
            recordLengthControl: context.read<RecordOptionsCubit>(),
            repository: context.read<LooperRepository>(),
            mixSettings: context.read<MixSettingsCoordinator>(),
            fxPersistence: context.read<FxChainPersistence>(),
            settings: context.read<SettingsRepository>(),
            takeLocked: () {
              try {
                return context.read<PowerOffCubit>().state.isUiUp;
              } on ProviderNotFoundException {
                return false;
              }
            },
          ),
        ),
        BlocProvider(
          create: (context) => SessionCubit(
            repository: context.read<SessionRepository>(),
            looper: context.read<LooperRepository>(),
            performance: context.read<PerformanceRepository>(),
            mixSettings: context.read<MixSettingsCoordinator>(),
            fxPersistence: context.read<FxChainPersistence>(),
            mixPersistence: context.read<MixSettingsPersistence>(),
            runClickVolumeExclusive: context
                .read<TempoCubit>()
                .runClickVolumeExclusive,
            currentDurableClickVolume: () =>
                context.read<TempoCubit>().durableClickVolume,
            runPlaybackExclusive: context
                .read<PlaybackOptionsCubit>()
                .runPlaybackExclusive,
            currentDurableDecay: () =>
                context.read<PlaybackOptionsCubit>().durableDecaySnapshot,
            currentDurableOneShot: () =>
                context.read<PlaybackOptionsCubit>().durableOneShotSnapshot,
            runRecordExclusive: context
                .read<RecordOptionsCubit>()
                .runRecordExclusive,
            currentDurableRecordLength: () =>
                context.read<RecordOptionsCubit>().durableRecordLengthSnapshot,
            exportDirectory: exportDirectory,
            // The session's pedal remap (part 6b) crossing as an opaque
            // string. Narrow functions rather than a cubit-to-cubit link:
            // `ControlCubit` owns the binding model, and it is an ancestor
            // provider here, so this reads and writes it without either cubit
            // knowing the other exists.
            //
            // Saves the remap IN FORCE (`state.bindings`), not the session
            // copy: the live rig — not settings — is the truth a save
            // captures, exactly as `chainsFromLooper` reads chains off the
            // repository rather than off the stored envelope. Reading
            // `sessionBindings` here instead made the blob write-never (no
            // path populates it before the first load), so no session could
            // ever acquire a remap and the A12 session branch was dead.
            currentPedalBindings: () =>
                context.read<ControlCubit>().state.bindings.encode(),
            onPedalBindings: (encoded) => context
                .read<ControlCubit>()
                .applySessionBindings(PedalBindingSet.decode(encoded)),
            releaseHeldBindings: () =>
                context.read<ControlCubit>().releaseAllMomentary(),
          ),
        ),
      ],
      // A session load applies its monitors and its Loop/Track/Master chains
      // straight to the engine, bypassing the MonitorCubit (provided app-wide,
      // an ancestor here) and the LooperBloc provided just above; this listener
      // re-projects the cubit and re-persists the chains from the repository
      // afterwards, so the FX dock and every boot-restore key follow the loaded
      // session.
      child: const PowerOffHost(
        child: SessionPersistenceSyncListener(child: TracksView()),
      ),
    );
  }
}
