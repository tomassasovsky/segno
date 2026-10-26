import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:segno/audio_setup/cubit/monitor_cubit.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/bloc/looper_bloc.dart';
import 'package:segno/looper/view/loop_settings/loop_settings_widgets.dart';
import 'package:segno/theme/theme.dart';

/// Whether the chain at [address] is switched in (its effects power), watched
/// so the caller rebuilds when it changes, whoever changed it: this page, a
/// pedal binding or a restored session.
///
/// A live input's flag is the monitor cubit's, the one owner of the Input
/// stage; every other stage's is the projected rig's.
bool watchFxChainEnabled(BuildContext context, FxAddress address) =>
    switch (address.stage) {
      FxStage.input => context.select<MonitorCubit, bool>(
        (m) => m.state.forInput(address.index).chainEnabled,
      ),
      FxStage.loop => context.select<LooperBloc, bool>(
        (b) =>
            b.state.tracks
                .elementAtOrNull(address.index)
                ?.lanes
                .elementAtOrNull(address.lane ?? 0)
                ?.chainEnabled ??
            true,
      ),
      FxStage.track => context.select<LooperBloc, bool>(
        (b) =>
            b.state.tracks.elementAtOrNull(address.index)?.chainEnabled ?? true,
      ),
      FxStage.output => context.select<LooperBloc, bool>(
        (b) => b.state.outputChainEnabled(address.index),
      ),
      FxStage.allTracks => context.select<LooperBloc, bool>(
        (b) => b.state.allTracksChain.chainEnabled,
      ),
    };

/// What switching the chain at [stage] off does to the sound, for the band
/// that says it is off.
String fxChainOffConsequence(AppLocalizations l10n, FxStage stage) =>
    switch (stage) {
      FxStage.input => l10n.fxChainOffInputConsequence,
      FxStage.loop => l10n.fxChainOffLoopConsequence,
      FxStage.track => l10n.fxChainOffTrackConsequence,
      FxStage.allTracks => l10n.fxChainOffAllTracksConsequence,
      FxStage.output => l10n.fxChainOffOutputConsequence,
    };

/// The chain's own power, Effects Off | On (#1452): every effect on this
/// input, take, track, All tracks or output switched in or out at once,
/// separate from each rack's and each pedal's switch.
///
/// Segmented rather than a toggle button: it sits beside Hear live's
/// segmented Off / Auto / On on the Effects page, and the selected segment
/// says the state in a word rather than by tint alone.
class FxChainPower extends StatelessWidget {
  /// Creates an [FxChainPower] for the chain at [address].
  const FxChainPower({
    required this.address,
    required this.onChanged,
    super.key,
  });

  /// The chain this switches.
  final FxAddress address;

  /// Asks for the chain to be switched in (`true`) or out.
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final on = watchFxChainEnabled(context, address);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        AppText(
          l10n.fxChainPowerLabel,
          key: const Key('fx_chain_power_label'),
          style: TextStyle(color: context.surface.textSecondary, fontSize: 20),
        ),
        const SizedBox(width: 12),
        for (final (value, label) in <(bool, String)>[
          (false, l10n.toggleOff),
          (true, l10n.toggleOn),
        ]) ...[
          if (value) const SizedBox(width: 5),
          LoopChoiceButton(
            key: Key(value ? 'fx_chain_power_on' : 'fx_chain_power_off'),
            label: label,
            selected: value == on,
            onTap: () {
              if (value != on) onChanged(value);
            },
            width: 88,
            height: 64,
            fontSize: 20,
          ),
        ],
      ],
    );
  }
}

/// The band that says a chain is off (#1452): one sentence in the warning
/// colour, over the racks or pedals it silences, and the way to turn it back
/// on from the screen where the silence is noticed.
///
/// The only notice for this cause: no toast goes with it.
class FxChainOffNotice extends StatelessWidget {
  /// Creates an [FxChainOffNotice].
  const FxChainOffNotice({
    required this.message,
    required this.onTurnOn,
    super.key,
  });

  /// The band's height, which the pages lay their content out around.
  static const double height = 68;

  /// What the chain being off does to the sound.
  final String message;

  /// Switches the chain back in.
  final VoidCallback onTurnOn;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return Container(
      key: const Key('fx_chain_off_notice'),
      height: height,
      padding: const EdgeInsets.only(left: 27, right: 8),
      decoration: BoxDecoration(
        color: surface.warning.withValues(alpha: 0.14),
        border: Border(left: BorderSide(color: surface.warning, width: 3)),
      ),
      child: Row(
        children: [
          Expanded(
            child: AppText(
              message,
              maxLines: 2,
              style: TextStyle(
                color: surface.textPrimary,
                fontSize: 22,
                height: 1.1,
              ),
            ),
          ),
          const SizedBox(width: 16),
          LoopOutlinedButton(
            key: const Key('fx_chain_turn_on'),
            width: 260,
            height: 52,
            radius: 8,
            tone: LoopButtonTone.accent,
            leadingIcon: LucideIcons.power,
            label: context.l10n.fxChainTurnOn,
            onTap: onTurnOn,
          ),
        ],
      ),
    );
  }
}
