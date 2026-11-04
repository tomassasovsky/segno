import 'dart:async';

import 'package:equatable/equatable.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:looper_repository/looper_repository.dart'
    show EngineReopened, FxAddress, FxStage, LooperState, ReopenOutcome;
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:segno/app/app_notices.dart';
import 'package:segno/app/segno_navigator.dart';
import 'package:segno/audio_setup/audio_setup.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/logging/app_log.dart';
import 'package:segno/looper/bloc/looper_bloc.dart';
import 'package:segno/looper/cubit/tracks_cubit.dart';
import 'package:segno/looper/model/fx_destination.dart';
import 'package:segno/notices/notices.dart';

/// Raises the console's standing conditions as must-act messages, and clears
/// each the moment it is over (#1562). The top bar of whatever screen is up
/// shows the one that matters most, so a lost interface is on every screen,
/// the performance views and the settings pages included, and the stage
/// itself never moves for it.
///
/// - The pinned audio interface is gone, or the boot waits for it: critical,
///   with Open setup (#453).
/// - It came back and the engine cleared every loop: critical, with Library
///   (#1140).
/// - The engine is stopped with a device present: critical, with Open setup.
///   Never beside the lost interface, which already says it.
/// - Audio is starting (#1533): neutral, no action; it ends by itself.
/// - Effects came up switched off (#1515): warning, with Open effects and
///   Dismiss.
class StandingNotices extends StatefulWidget {
  /// Creates a [StandingNotices] over [child].
  const StandingNotices({required this.child, super.key});

  /// The app.
  final Widget child;

  @override
  State<StandingNotices> createState() => _StandingNoticesState();
}

class _StandingNoticesState extends State<StandingNotices> {
  /// What each raised message last said, so a sync that changes nothing
  /// raises nothing.
  final _raised = <String, Object>{};

  @override
  void initState() {
    super.initState();
    _sync();
  }

  void _sync() {
    if (!mounted) return;
    final audio = context.read<AudioSetupCubit>().state;
    final looper = context.read<LooperBloc>().state;
    final lost = switch (audio.deviceConnectivity) {
      DeviceConnectivity.lost || DeviceConnectivity.waiting => true,
      _ => false,
    };
    _syncDeviceLost(audio);
    _syncMaterialCleared(audio);
    _set(
      AppNoticeId.engineStopped,
      !looper.status.isConnected && !lost ? true : null,
      () => Notice(
        id: AppNoticeId.engineStopped,
        tone: NoticeTone.critical,
        title: (l10n) => l10n.engineStoppedBanner,
        action: _openSetup(AppNoticeId.engineStopped),
      ),
    );
    _set(
      AppNoticeId.audioStarting,
      looper.status.isConnected && looper.status.starting && !lost
          ? true
          : null,
      () => Notice(
        id: AppNoticeId.audioStarting,
        icon: LucideIcons.hourglass,
        title: (l10n) => l10n.audioStartingBanner,
      ),
    );
    _syncFxHeld(looper);
    _syncOutputFxWaiting(looper);
  }

  /// Effects kept for outputs the open device lacks (#1421): named once per
  /// device open, logged when named, until the player dismisses them.
  void _syncOutputFxWaiting(LooperState looper) {
    final waiting = looper.outputFxWaiting;
    if (waiting.isEmpty) {
      _set(AppNoticeId.outputFxWaiting, null);
      return;
    }
    final names = context.read<OutputsCubit>().state.names;
    final channels = looper.status.outputChannels;
    if (_raised[AppNoticeId.outputFxWaiting] != _OutputFxWaiting(waiting)) {
      AppLog.info(
        'effects kept for outputs the device lacks: '
        '${waiting.map((bus) => bus + 1).join(', ')}',
      );
    }
    _set(
      AppNoticeId.outputFxWaiting,
      _OutputFxWaiting(waiting),
      () => Notice(
        id: AppNoticeId.outputFxWaiting,
        title: (l10n) => l10n.outputFxWaitingTitle,
        body: (l10n) => l10n.outputFxWaitingBody(
          fxHeldList(l10n, [
            for (final bus in waiting)
              l10n.outputName(names, bus, channels: channels),
          ]),
          waiting.length,
        ),
        secondary: NoticeAction(
          key: const Key(AppNoticeId.outputFxWaitingDismiss),
          label: (l10n) => l10n.dismiss,
          onPressed: () => context.read<LooperBloc>().add(
            const LooperOutputFxWaitingDismissed(),
          ),
        ),
      ),
    );
  }

  void _syncDeviceLost(AudioSetupState audio) {
    final name = audio.connectivityDeviceName;
    final key = switch (audio.deviceConnectivity) {
      DeviceConnectivity.lost => ('lost', name),
      DeviceConnectivity.waiting => ('waiting', name),
      _ => null,
    };
    _set(
      AppNoticeId.deviceLost,
      key,
      () => Notice(
        id: AppNoticeId.deviceLost,
        tone: NoticeTone.critical,
        title: (l10n) => audioLossLine(l10n, audio) ?? '',
        body: audio.deviceConnectivity == DeviceConnectivity.waiting
            ? (l10n) => l10n.audioRecoveryWaitingBody
            : null,
        action: _openSetup(AppNoticeId.deviceLost),
      ),
    );
  }

  void _syncMaterialCleared(AudioSetupState audio) {
    final reopen = audio.engineStatus.reopen;
    _set(
      AppNoticeId.deviceMaterialCleared,
      audio.deviceConnectivity == DeviceConnectivity.restoredCleared
          ? _Reopen(reopen)
          : null,
      () => Notice(
        id: AppNoticeId.deviceMaterialCleared,
        tone: NoticeTone.critical,
        title: (l10n) => l10n.deviceRestoredClearedTitle,
        body: (l10n) => reopen?.outcome == ReopenOutcome.clearedCap
            ? l10n.deviceRestoredClearedCapBanner
            : l10n.deviceRestoredClearedBanner(
                reopen?.sampleRate ?? 0,
                reopen?.previousSampleRate ?? 0,
              ),
        action: NoticeAction(
          key: const Key('${AppNoticeId.deviceMaterialCleared}_library'),
          label: (l10n) => l10n.stageLibrary,
          onPressed: () {
            context.read<AudioSetupCubit>().dismissReopenNotice();
            unawaited(openLibrary());
          },
        ),
      ),
    );
  }

  void _syncFxHeld(LooperState looper) {
    final held = looper.fxHoldNotice;
    if (held.isEmpty) {
      _set(AppNoticeId.fxHeld, null);
      return;
    }
    final names = (
      tracks: context.read<TracksCubit>().state.names,
      inputs: context.read<InputsCubit>().state.names,
      outputs: context.read<OutputsCubit>().state.names,
      outputChannels: looper.status.outputChannels,
    );
    List<String> labels(AppLocalizations l10n) {
      final labels = <String>[];
      for (final address in held) {
        final label = fxHeldChainLabel(
          l10n,
          address,
          trackNames: names.tracks,
          inputNames: names.inputs,
          outputNames: names.outputs,
          outputChannels: names.outputChannels,
        );
        if (!labels.contains(label)) labels.add(label);
      }
      return labels;
    }

    _set(
      AppNoticeId.fxHeld,
      _FxHeld(held, names),
      () => Notice(
        id: AppNoticeId.fxHeld,
        tone: NoticeTone.warning,
        title: (l10n) => l10n.fxHeldTitle,
        body: (l10n) {
          final chains = labels(l10n);
          return l10n.fxHeldBanner(fxHeldList(l10n, chains), chains.length);
        },
        // The fix: the Effects page at the first chain that is off.
        action: NoticeAction(
          key: const Key(AppNoticeId.fxHeldOpen),
          label: (l10n) => l10n.fxHeldOpen,
          onPressed: () =>
              unawaited(openFx(destination: fxDestinationOf(held.first))),
        ),
        // The chains stay off; only the message goes.
        secondary: NoticeAction(
          key: const Key(AppNoticeId.fxHeldDismiss),
          label: (l10n) => l10n.dismiss,
          onPressed: () => context.read<LooperBloc>().add(
            const LooperFxHoldNoticeDismissed(),
          ),
        ),
      ),
    );
  }

  NoticeAction _openSetup(String id) => NoticeAction(
    key: Key('${id}_setup'),
    label: (l10n) => l10n.deviceLostBannerAction,
    onPressed: () => unawaited(openDeviceSettings()),
  );

  /// Raises [id] with [notice] while [key] is not null and differs from what
  /// was last raised; clears it when [key] is null.
  void _set(String id, Object? key, [Notice Function()? notice]) {
    final notices = context.read<NoticesCubit>();
    if (key == null) {
      if (_raised.remove(id) != null) notices.clear(id);
      return;
    }
    if (_raised[id] == key) return;
    _raised[id] = key;
    notices.raise(notice!());
  }

  @override
  Widget build(BuildContext context) => MultiBlocListener(
    listeners: [
      BlocListener<AudioSetupCubit, AudioSetupState>(
        listenWhen: (previous, current) =>
            previous.deviceConnectivity != current.deviceConnectivity ||
            previous.connectivityDeviceName != current.connectivityDeviceName ||
            previous.engineStatus.reopen != current.engineStatus.reopen,
        listener: (_, _) => _sync(),
      ),
      // Not every engine tick: only what these conditions read.
      BlocListener<LooperBloc, LooperState>(
        listenWhen: (previous, current) =>
            previous.status.isConnected != current.status.isConnected ||
            previous.status.starting != current.status.starting ||
            previous.status.outputChannels != current.status.outputChannels ||
            previous.fxHoldNotice != current.fxHoldNotice ||
            previous.outputFxWaiting != current.outputFxWaiting,
        listener: (_, _) => _sync(),
      ),
      BlocListener<TracksCubit, TracksState>(
        listenWhen: (previous, current) => previous.names != current.names,
        listener: (_, _) => _sync(),
      ),
      BlocListener<InputsCubit, InputsState>(
        listener: (_, _) => _sync(),
      ),
      BlocListener<OutputsCubit, OutputsState>(
        listener: (_, _) => _sync(),
      ),
    ],
    child: widget.child,
  );
}

class _Reopen extends Equatable {
  const _Reopen(this.reopen);

  final EngineReopened? reopen;

  @override
  List<Object?> get props => [reopen];
}

class _OutputFxWaiting extends Equatable {
  const _OutputFxWaiting(this.buses);

  final List<int> buses;

  @override
  List<Object?> get props => [buses];
}

class _FxHeld extends Equatable {
  const _FxHeld(this.held, this.names);

  final List<FxAddress> held;
  final Object names;

  @override
  List<Object?> get props => [held, names];
}

/// The line the must-act message says for [state]'s interface condition,
/// and the readout's band echoes word for word, so the two screens never
/// disagree (#1270 Part 5); `null` when it is not about a missing
/// interface.
String? audioLossLine(AppLocalizations l10n, AudioSetupState state) =>
    switch (state.deviceConnectivity) {
      DeviceConnectivity.lost => l10n.deviceLostNamedBanner(
        state.connectivityDeviceName.isEmpty
            ? l10n.audioDeviceFallbackName
            : state.connectivityDeviceName,
      ),
      DeviceConnectivity.waiting => l10n.audioRecoveryWaitingBanner,
      DeviceConnectivity.none ||
      DeviceConnectivity.restored ||
      DeviceConnectivity.restoredPartial ||
      DeviceConnectivity.restoredCleared => null,
    };

/// What the effects-off message calls the chain at [address]: a live
/// input's chain by the input's name, a take's or a track's chain by the
/// track's, a destination's by its name (#1515).
String fxHeldChainLabel(
  AppLocalizations l10n,
  FxAddress address, {
  required List<String> trackNames,
  required Map<int, String> inputNames,
  required Map<int, String> outputNames,
  required int outputChannels,
}) => switch (address.stage) {
  FxStage.input => l10n.fxHeldInputChain(
    l10n.inputName(inputNames, address.index),
  ),
  FxStage.loop || FxStage.track => l10n.trackName(trackNames, address.index),
  FxStage.allTracks => l10n.fxAllTracks,
  FxStage.output => l10n.outputName(
    outputNames,
    address.index,
    channels: outputChannels,
  ),
};

/// [labels] as one list: "A", "A and B", "A, B and C".
String fxHeldList(AppLocalizations l10n, List<String> labels) =>
    labels.length < 2
    ? labels.join()
    : l10n.fxHeldListAnd(
        labels.sublist(0, labels.length - 1).join(', '),
        labels.last,
      );

/// The Effects page's destination for the chain at [address].
FxDestination fxDestinationOf(FxAddress address) => switch (address.stage) {
  FxStage.input => FxDestination.liveInput(address.index),
  FxStage.loop || FxStage.track => FxDestination.recordedTrack(address.index),
  FxStage.allTracks => const FxDestination.allTracks(),
  FxStage.output => FxDestination.output(address.index),
};
