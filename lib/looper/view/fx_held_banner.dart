import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/audio_setup/cubit/inputs_cubit.dart';
import 'package:segno/audio_setup/cubit/outputs_cubit.dart';
import 'package:segno/common/console_surface.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/bloc/looper_bloc.dart';
import 'package:segno/looper/cubit/tracks_cubit.dart';
import 'package:segno/theme/theme.dart';

/// What the effects-off notice calls the chain at [address]: a live input's
/// chain by the input's name, a take's or a track's chain by the track's,
/// a destination's by its name (#1515).
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

/// The stage's standing notice that some effects are off because the rig
/// could not run them when it came up (#1515, the owner's R2): the chains
/// keep their settings, play as off, and switching one on is refused until
/// the rig has room for it. A banner and not a toast, because the sound
/// differs from what was saved until the player acts; the popup severity
/// rule. A take whose effects come in off while it stands joins it instead
/// of raising a toast beside it, so one cause never shows two notices.
///
/// It stands until every chain it names is back on, or the player dismisses
/// it (the chains stay off). Empty, it takes no space.
class FxHeldBanner extends StatelessWidget {
  /// Creates an [FxHeldBanner].
  const FxHeldBanner({super.key});

  /// The gap under the banner, the stage run's own 10.
  static const double _gapBelow = 10;

  @override
  Widget build(BuildContext context) {
    final notice = context.select<LooperBloc, List<FxAddress>>(
      (bloc) => bloc.state.fxHoldNotice,
    );
    if (notice.isEmpty) return const SizedBox.shrink();
    final l10n = context.l10n;
    final outputChannels = context.select<LooperBloc, int>(
      (bloc) => bloc.state.status.outputChannels,
    );
    // Each name source only when the notice names that kind of chain.
    bool names(FxStage stage) => notice.any((at) => at.stage == stage);
    final trackNames = names(FxStage.loop) || names(FxStage.track)
        ? context.watch<TracksCubit>().state.names
        : const <String>[];
    final inputNames = names(FxStage.input)
        ? context.watch<InputsCubit>().state.names
        : const <int, String>{};
    final outputNames = names(FxStage.output)
        ? context.watch<OutputsCubit>().state.names
        : const <int, String>{};
    final labels = <String>[];
    for (final address in notice) {
      final label = fxHeldChainLabel(
        l10n,
        address,
        trackNames: trackNames,
        inputNames: inputNames,
        outputNames: outputNames,
        outputChannels: outputChannels,
      );
      if (!labels.contains(label)) labels.add(label);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _FxHeldStrip(
          message: l10n.fxHeldBanner(fxHeldList(l10n, labels), labels.length),
          onDismiss: () => context.read<LooperBloc>().add(
            const LooperFxHoldNoticeDismissed(),
          ),
        ),
        const SizedBox(height: _gapBelow),
      ],
    );
  }
}

/// The strip itself: the device-lost banner's shape in the warning colour
/// (a sound that differs, not a loss), the sentence and its one action.
class _FxHeldStrip extends StatelessWidget {
  const _FxHeldStrip({required this.message, required this.onDismiss});

  final String message;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return Container(
      key: const Key('fx_held_banner'),
      padding: const EdgeInsets.symmetric(vertical: 11, horizontal: 15),
      decoration: BoxDecoration(
        color: surface.warning.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(11),
        border: Border.all(color: surface.warning.withValues(alpha: 0.5)),
      ),
      child: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: surface.warning,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 10),
          Flexible(
            child: AppText(
              message,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: surface.textPrimary,
                fontSize: 15,
                height: 1.2,
                leadingDistribution: TextLeadingDistribution.even,
              ),
            ),
          ),
          const SizedBox(width: 10),
          ConsoleSmallButton(
            key: const Key('fx_held_banner_dismiss'),
            label: context.l10n.dismiss,
            onPressed: onDismiss,
          ),
        ],
      ),
    );
  }
}
