import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:pedal_repository/pedal_repository.dart' show PedalLinkStatus;
import 'package:segno/l10n/l10n.dart';
import 'package:segno/pedal/cubit/pedal_cubit.dart';
import 'package:segno/pedal/view/pedal_assignment_page.dart';
import 'package:segno/setup/setup_surface.dart';
import 'package:segno/theme/theme.dart';

/// The pedal block in the audio/I-O settings: whether the console board is
/// connected, and the way in to the footswitch assignments. Driven by
/// [PedalCubit]; independent of the audio engine.
///
/// Nothing here CHOOSES hardware: the board is wired-in and announces itself
/// over the link, so there is no device to pick and no firmware version to
/// declare.
class PedalSettingsSection extends StatelessWidget {
  /// Creates a [PedalSettingsSection].
  const PedalSettingsSection({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final state = context.watch<PedalCubit>().state;

    return Column(
      key: const Key('pedalSettings_section'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SetupGroupLabel(l10n.pedalLinkGroup),
        const SizedBox(height: 12),
        _PedalStatusLine(
          status: state.status,
          firmwareVersion: state.firmwareVersion,
        ),
        const SizedBox(height: 12),
        // Kept alongside the tray's own pedal rail destination (#440) on
        // purpose — this is where you already are when configuring the pedal.
        // Both mount the same `PedalAssignmentView`, so this is a second
        // entry point, not a second implementation.
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            key: const Key('pedalSettings_openAssignments'),
            onPressed: () => showPedalAssignmentPage(context),
            icon: const Icon(Icons.piano_outlined, size: 16),
            label: AppText(l10n.pedalAssignTitle),
          ),
        ),
      ],
    );
  }
}

/// A one-line link status, exposed to screen readers via the text itself
/// (semantics, not color-only).
class _PedalStatusLine extends StatelessWidget {
  const _PedalStatusLine({required this.status, required this.firmwareVersion});

  final PedalLinkStatus status;
  final String? firmwareVersion;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final message = switch (status) {
      PedalLinkStatus.disconnected => l10n.pedalStatusDisconnected,
      PedalLinkStatus.connected => l10n.pedalStatusConnected(
        firmwareVersion ?? '',
      ),
      PedalLinkStatus.incompatible => l10n.pedalStatusIncompatible(
        firmwareVersion ?? '',
      ),
    };
    // A live region so connect / disconnect transitions are announced as they
    // happen, not only on navigation (WCAG 4.1.3).
    return Semantics(
      liveRegion: true,
      child: AppText(
        message,
        key: const Key('pedalSettings_status'),
        style: context.setupBody,
      ),
    );
  }
}
