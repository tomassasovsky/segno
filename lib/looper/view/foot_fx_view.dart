import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:segno/app/segno_navigator.dart';
import 'package:segno/control/control.dart';
import 'package:segno/control/model/foot_fx.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/bloc/looper_bloc.dart';
import 'package:segno/looper/cubit/tracks_cubit.dart';
import 'package:segno/looper/view/fx_editor/fx_block_chip.dart';
import 'package:segno/looper/view/performance_pedal.dart';
import 'package:segno/theme/theme.dart';

/// The accepted ten-pedal FX face (pen 10/03 `noDGu`, #1229): every
/// bindable switch names what its FX binding drives, with a Toggle or Hold
/// line, and lights exactly as its LED does. An unbound track switch toggles
/// its own track's chain; unbound Rec/Play, Stop, Undo and Clear do nothing
/// here and are drawn dimmed.
class FootFxView extends StatelessWidget {
  /// Creates the performance surface within the real Tracks hierarchy.
  const FootFxView({super.key});

  @override
  Widget build(BuildContext context) {
    final control = context.read<ControlCubit>();
    final controlState = context.watch<ControlCubit>().state;
    final looper = context.watch<LooperBloc>().state;
    final pedals = projectFootFx(controlState, looper);
    final l10n = context.l10n;
    final surface = context.surface;

    const front = [
      PedalButton.recPlay,
      PedalButton.stop,
      PedalButton.undo,
      PedalButton.mode,
      PedalButton.track1,
      PedalButton.track2,
      PedalButton.track3,
      PedalButton.track4,
    ];
    return DefaultTextStyle.merge(
      style: TextStyle(
        fontWeight: FontWeight.w400,
        fontFamily: SurfaceTheme.displayFont,
        color: surface.textPrimary,
      ),
      child: Column(
        key: const Key('foot_fx_view'),
        children: [
          Container(
            height: 96,
            padding: const EdgeInsetsDirectional.symmetric(horizontal: 36),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: surface.line)),
            ),
            child: Row(
              children: [
                IconButton.outlined(
                  key: const Key('foot_fx_exit'),
                  tooltip: l10n.actionModeExit,
                  onPressed: () =>
                      control.activateFootFxPedal(PedalButton.mode),
                  style: IconButton.styleFrom(
                    minimumSize: const Size(64, 64),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  icon: const Icon(Icons.chevron_left),
                ),
                const Spacer(),
                OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(136, 64),
                    textStyle: const TextStyle(
                      fontFamily: SurfaceTheme.displayFont,
                      fontSize: 24,
                      fontWeight: FontWeight.w400,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  onPressed: () => unawaited(openSegnoSettings()),
                  child: AppText(l10n.stageSettings),
                ),
              ],
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(60, 24, 60, 24),
              child: FittedBox(
                child: SizedBox(
                  width: 1800,
                  height: 880,
                  child: Stack(
                    children: [
                      PositionedDirectional(
                        start: 40,
                        top: 16,
                        child: AppText(
                          l10n.actionModeFx,
                          style: const TextStyle(fontSize: 40),
                        ),
                      ),
                      PositionedDirectional(
                        start: 480,
                        top: 56,
                        width: 180,
                        child: _FootFxPedal(pedal: pedals[PedalButton.clear]!),
                      ),
                      PositionedDirectional(
                        start: 700,
                        top: 56,
                        width: 180,
                        child: _FootFxPedal(pedal: pedals[PedalButton.bank]!),
                      ),
                      PositionedDirectional(
                        start: 40,
                        end: 40,
                        top: 472,
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            for (final button in front)
                              SizedBox(
                                width: 180,
                                child: _FootFxPedal(pedal: pedals[button]!),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _FootFxPedal extends StatelessWidget {
  const _FootFxPedal({required this.pedal});

  final FootFxPedal pedal;

  @override
  Widget build(BuildContext context) {
    final control = context.read<ControlCubit>();
    final repository = context.read<LooperRepository>();
    final trackNames = context.watch<TracksCubit>().state.names;
    final bank = context.select<ControlCubit, int>(
      (cubit) => cubit.state.activeBank,
    );
    final l10n = context.l10n;
    final button = pedal.button;
    final binding = pedal.binding;
    final target = pedal.target;

    final String title;
    var detail = '';
    var hint = '';
    switch (pedal.role) {
      case FootFxRole.exit:
        title = l10n.actionModeExit;
      case FootFxRole.bank:
        title = l10n.footFadeBank(bank == 0 ? 'A' : 'B');
        detail = l10n.footReverseSwitchBank;
      case FootFxRole.inert:
        title = switch (button) {
          PedalButton.recPlay => l10n.actionRecordPlay,
          PedalButton.stop => l10n.actionStop,
          PedalButton.undo => l10n.actionUndo,
          _ => l10n.actionOperationClear,
        };
      case FootFxRole.trackChain:
        final channel = pedal.channel!;
        final effects = pedal.effects;
        title = effects.isEmpty
            ? l10n.footFxSlot(
                bank == 0 ? 'A' : 'B',
                button.index - PedalButton.track1.index + 1,
              )
            : fxBlockName(l10n, effects.first);
        detail = l10n.footFxToggle;
        hint = l10n.trackName(trackNames, channel);
      case FootFxRole.binding:
        if (pedal.stale || target == null) {
          title = l10n.footFxTargetMissing;
        } else {
          title =
              _targetName(l10n, repository, target) ??
              bindingTargetLabel(l10n, trackNames, target);
        }
        detail = binding!.behavior == BindingBehavior.momentary
            ? l10n.footFxHold
            : l10n.footFxToggle;
        final holdTarget = binding.decodeHoldTarget();
        hint = holdTarget != null
            ? l10n.footFxHoldAction(
                _targetName(l10n, repository, holdTarget) ??
                    bindingTargetLabel(l10n, trackNames, holdTarget),
              )
            : target == null || pedal.stale
            ? ''
            : fxStageLabel(l10n, trackNames, target.address);
    }

    return PerformancePedal(
      keyPrefix: 'foot_fx_pedal',
      button: button,
      label: switch (button) {
        PedalButton.recPlay => '●+▶',
        PedalButton.stop => '■',
        PedalButton.undo => l10n.footMixerUndo,
        PedalButton.clear => l10n.footMixerClear,
        PedalButton.bank => l10n.footMixerBank,
        PedalButton.mode => l10n.footMixerMode,
        _ => '${button.index - PedalButton.track1.index + 1}',
      },
      title: title,
      detail: detail,
      // The held contact's Toggle/Hold line brightens while a momentary is
      // down (pen `ri60q`).
      detailHighlighted:
          binding != null &&
          binding.behavior == BindingBehavior.momentary &&
          pedal.lit,
      hint: hint,
      // A stale binding stays pressable: its stomp is refused with a notice,
      // on screen and by foot alike (§3 rule 2). Only a switch with nothing
      // behind it is dimmed.
      enabled: pedal.available,
      selected: pedal.lit,
      onPressed: control.footFxPressed,
      onReleased: control.footFxReleased,
      onCancelled: control.footFxCancelled,
      onActivate: () => control.activateFootFxPedal(button),
      onHold: (binding?.hasHold ?? false) || button == PedalButton.bank
          ? () => control.activateFootFxPedal(button, hold: true)
          : null,
    );
  }
}

/// The name of what [target] drives: the effect a slot target names, or the
/// first effect of the chain a chain target names; null when the chain is
/// empty or gone.
String? _targetName(
  AppLocalizations l10n,
  LooperRepository repository,
  FxBindingTarget target,
) {
  final entries = repository.chainEntriesAt(target.address);
  if (entries == null || entries.isEmpty) return null;
  return switch (target) {
    FxChainTarget() => fxBlockName(l10n, entries.first),
    FxSlotTarget(:final slotId) => switch (entries.where(
      (entry) => entry.slotId == slotId,
    )) {
      final matches when matches.isNotEmpty => fxBlockName(
        l10n,
        matches.first,
      ),
      _ => null,
    },
  };
}
