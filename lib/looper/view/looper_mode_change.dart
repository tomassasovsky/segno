import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/bloc/looper_bloc.dart';
import 'package:segno/looper/view/loop_settings/loop_settings_widgets.dart';
import 'package:segno/theme/theme.dart';

/// The five looper modes, each with the one-liner that makes it choosable.
///
/// One table, called by both the Settings section and the console's Mode face.
/// Two copies would be two chances for the two surfaces to describe the same
/// mode differently — and a picker of five bare names ("Multi", "Band") asks
/// the reader to already know the answer, so the one-liner is not decoration.
Map<LooperMode, ({String label, String sub})> looperModeLabels(
  AppLocalizations l10n,
) => {
  LooperMode.multi: (
    label: l10n.looperModeMultiLabel,
    sub: l10n.looperModeMultiSub,
  ),
  LooperMode.sync: (
    label: l10n.looperModeSyncLabel,
    sub: l10n.looperModeSyncSub,
  ),
  LooperMode.song: (
    label: l10n.looperModeSongLabel,
    sub: l10n.looperModeSongSub,
  ),
  LooperMode.band: (
    label: l10n.looperModeBandLabel,
    sub: l10n.looperModeBandSub,
  ),
  LooperMode.free: (
    label: l10n.looperModeFreeLabel,
    sub: l10n.looperModeFreeSub,
  ),
};

/// Switches the looper to [next] under the accepted mode-change contract.
///
/// **The one implementation of it.** The engine measures what a change
/// would do (`LooperRepository.looperModeGate`): a stopped, fitting rig
/// switches directly; playing loops ask **Stop loops and switch** first in
/// the pen's dialog (Cancel keeps everything); a capture, a queued action or
/// unfit spans refuse with their reason. No audio is cleared, trimmed or
/// stretched to make a mode fit. The Loop mode page is its caller; any
/// other surface that switches the mode goes through here too, so the
/// surfaces cannot drift.
///
/// Resolves **true** when the change was dispatched, so a caller can shut its
/// chooser on the way through and leave it open when the confirm was declined
/// or the change was refused.
///
/// Needs [LooperBloc] and [LooperRepository] on [context].
Future<bool> requestLooperModeChange(
  BuildContext context, {
  required LooperMode current,
  required LooperMode next,
}) async {
  if (next == current) return false;
  final l10n = context.l10n;
  final bloc = context.read<LooperBloc>();
  final repository = context.read<LooperRepository>();
  var gate = repository.looperModeGate(next);
  if (gate == LooperModeGate.playing) {
    final confirmed = await showLooperModeStopDialog(context, next: next);
    if (!confirmed || !context.mounted) return false;
    // Asked again: a pedal may have armed a take while the dialog was up,
    // and a refusal then must be named, not swallowed.
    gate = repository.looperModeGate(next);
  }
  final reason = looperModeRefusal(l10n, gate);
  if (reason != null) {
    _showRefusal(context, reason);
    return false;
  }
  bloc.add(LooperModeChanged(next));
  return true;
}

/// The pen's "Switch to …?" dialog (Loop mode transitions): 960 x 267 at
/// the pen's scale, Keep it and the filled "Stop loops and switch".
/// Resolves true when the switch was confirmed.
Future<bool> showLooperModeStopDialog(
  BuildContext context, {
  required LooperMode next,
}) async {
  final l10n = context.l10n;
  final surface = context.surface;
  final confirmed = await showDialog<bool>(
    context: context,
    barrierColor: surface.scrim,
    builder: (dialogContext) => Center(
      child: Material(
        color: Colors.transparent,
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Container(
            key: const Key('loop_mode_confirm'),
            width: 960,
            height: 267,
            padding: const EdgeInsets.all(41),
            decoration: BoxDecoration(
              color: surface.cardHigh,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: surface.borderStrong),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AppText(
                  l10n.modeChangeStopTitle(looperModeLabels(l10n)[next]!.label),
                  style: TextStyle(
                    color: surface.textPrimary,
                    fontSize: 32,
                    height: 1,
                  ),
                ),
                const SizedBox(height: 29),
                AppText(
                  l10n.modeChangeStopBody,
                  style: TextStyle(
                    color: surface.textSecondary,
                    fontSize: 24,
                    height: 1,
                  ),
                ),
                const Spacer(),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    LoopOutlinedButton(
                      key: const Key('loop_mode_confirm_cancel'),
                      width: 125,
                      label: l10n.consoleKeepIt,
                      onTap: () => Navigator.of(dialogContext).pop(false),
                    ),
                    const SizedBox(width: 15),
                    LoopOutlinedButton(
                      key: const Key('loop_mode_confirm_switch'),
                      width: 305,
                      tone: LoopButtonTone.accent,
                      label: l10n.modeChangeStopConfirm,
                      onTap: () => Navigator.of(dialogContext).pop(true),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
  return confirmed ?? false;
}

/// The short reason a mode is unavailable right now. `null` when the change
/// is open or only needs the stop confirmation. One wording for both
/// readers: the refusal snackbar here, and the mode cards, which draw it in
/// place of the mode's description while the gate is closed.
String? looperModeRefusal(AppLocalizations l10n, LooperModeGate gate) =>
    switch (gate) {
      LooperModeGate.capturing => l10n.modeChangeBlockedCapturing,
      LooperModeGate.queued => l10n.modeChangeBlockedQueued,
      LooperModeGate.spans => l10n.modeChangeBlockedSpans,
      LooperModeGate.open || LooperModeGate.playing => null,
    };

void _showRefusal(BuildContext context, String reason) {
  ScaffoldMessenger.of(context)
    ..clearSnackBars()
    ..showSnackBar(
      SnackBar(
        key: const Key('looperMode_refused_snackbar'),
        content: Semantics(liveRegion: true, child: AppText(reason)),
      ),
    );
}
