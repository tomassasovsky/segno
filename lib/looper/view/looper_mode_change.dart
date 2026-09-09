import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/common/console_surface.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/bloc/looper_bloc.dart';
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
/// switches directly; a playing rig asks **Stop loops and switch** first
/// (Cancel keeps everything); a capture, a queued action or unfit spans
/// refuse with their reason. No audio is cleared, trimmed or stretched to
/// make a mode fit. `LooperModeSection` and the Loop face both call this, so
/// the two surfaces cannot drift.
///
/// Filed beside the Settings section rather than under `view/loop/`: a
/// non-console screen imports it, so a folder named after one consumer would
/// misstate who owns it.
///
/// Resolves **true** when the change was dispatched, so a caller can shut its
/// chooser on the way through and leave it open when the confirm was declined
/// or the change was refused.
///
/// Needs [LooperBloc] and [LooperRepository] on [context].
///
/// [confirm] asks "Stop loops and switch" in the caller's own dialog (the
/// accepted mode cards draw the pen's); the console confirm dialog is the
/// default.
Future<bool> requestLooperModeChange(
  BuildContext context, {
  required LooperMode current,
  required LooperMode next,
  Future<bool> Function()? confirm,
}) async {
  if (next == current) return false;
  final l10n = context.l10n;
  final bloc = context.read<LooperBloc>();
  final repository = context.read<LooperRepository>();
  var gate = repository.looperModeGate(next);
  if (gate == LooperModeGate.playing) {
    final confirmed = confirm != null
        ? await confirm()
        : await showConsoleConfirmDialog(
            context,
            title: l10n.modeChangeStopTitle(
              looperModeLabels(l10n)[next]!.label,
            ),
            body: l10n.modeChangeStopBody,
            confirmLabel: l10n.modeChangeStopConfirm,
          );
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

/// The short reason a mode is unavailable right now. `null` when the change
/// is open or only needs the stop confirmation. Shown from the chooser as a
/// snackbar here; the accepted mode cards (slice 2c) will draw it in place of
/// the mode's description.
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
