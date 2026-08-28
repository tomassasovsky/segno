import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:pedal_repository/pedal_repository.dart'
    show PedalBindStatus, PedalCodec, PedalOutput;
import 'package:segno/l10n/l10n.dart';
import 'package:segno/pedal/cubit/pedal_cubit.dart';
import 'package:segno/pedal/view/pedal_assignment_page.dart';
import 'package:segno/setup/setup_surface.dart';
import 'package:segno/theme/theme.dart';

/// The bidirectional-pedal block in the audio/I-O settings: a MIDI **output**
/// device dropdown (with a "None" item) for the pedal's LED feedback link and a
/// live bind-status line. Driven by [PedalCubit]; independent of the audio
/// engine.
///
/// The pedal's *input* (footswitches) shares the MIDI input device selected in
/// the MIDI input section; this only binds the output destination segno pushes
/// state frames to.
class PedalSettingsSection extends StatelessWidget {
  /// Creates a [PedalSettingsSection].
  const PedalSettingsSection({super.key});

  // The parts that CHOOSE hardware -- the output picker and the manual
  // firmware-version gate -- are not here: auto-detect binds the pedal by
  // product name (#421) and the flasher records what it wrote (#427), so both
  // would be stale hand-cranks for values the appliance already knows.
  //
  // The parts that CONFIGURE it stay. Bind assignments and the bind-status
  // line are the only way in for a footswitch remap.

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final cubit = context.watch<PedalCubit>();
    final outputs = cubit.state.availableOutputs;
    final boundId = cubit.state.boundOutputId;

    return Column(
      key: const Key('pedalSettings_section'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SetupGroupLabel(l10n.pedalOutputGroup),
        const SizedBox(height: 12),
        // With no picker, this line is the ONLY way to see whether
        // auto-detect actually found the pedal.
        _PedalStatusLine(
          status: cubit.state.bindStatus,
          deviceName: _boundName(outputs, boundId),
        ),
        const SizedBox(height: 12),
        // No hint line under this one: the assignment page opens with the
        // same sentence, so repeating it here only costs height.
        //
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
        const SizedBox(height: 24),
        SetupGroupLabel(l10n.pedalFirmwareGroup),
        const SizedBox(height: 12),
        // The condition itself is the cubit's (it reads the repository's
        // resolved wire version) — this only renders the answer.
        if (cubit.state.firmwareUpdateAvailable) ...[
          const SizedBox(height: 12),
          _PedalFirmwareUpdateBanner(
            firmwareVersion: cubit.state.firmwareVersion,
          ),
        ],
      ],
    );
  }

  String _boundName(List<PedalOutput> outputs, String? boundId) {
    if (boundId == null) return '';
    for (final device in outputs) {
      if (device.id == boundId) return device.name;
    }
    return boundId;
  }
}

/// Shown while a pedal is bound but negotiates BELOW the newest protocol
/// (flow err-4): FX mode still works — the projection never branches on the
/// pedal version (B10) — but the codec downgrades it, so the chain LEDs come
/// out green instead of blue and the pedal reads FX as mute. Explaining that
/// here is the difference between "my pedal is broken" and "my pedal is old".
///
/// Informational for now: it names the fix (flash the newer firmware, then
/// pick the version above). The one-tap update ride-along lands with the
/// auto-detect/OTA flow (#331), which owns the flashing UI.
class _PedalFirmwareUpdateBanner extends StatelessWidget {
  const _PedalFirmwareUpdateBanner({required this.firmwareVersion});

  /// The negotiated version, or `null` when not set (the v2 safety floor).
  final int? firmwareVersion;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final version = firmwareVersion;
    final body = version == null
        ? l10n.pedalFirmwareUpdateBodyUnknown(
            PedalCodec.protocolVersion, // the unknown ⇒ v2 safety floor
            PedalCodec.protocolVersionMax,
          )
        : l10n.pedalFirmwareUpdateBody(version, PedalCodec.protocolVersionMax);

    // A live region: the banner appears and disappears as the pedal binds,
    // unbinds, or its version is set — transitions a screen reader must hear
    // without navigating back to this section (WCAG 4.1.3).
    return Semantics(
      liveRegion: true,
      child: Container(
        key: const Key('pedalSettings_firmwareUpdate_banner'),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: context.surface.card,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: theme.colorScheme.primary),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AppText(
              l10n.pedalFirmwareUpdateTitle,
              style: context.setupBody.copyWith(
                color: theme.colorScheme.primary,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 4),
            AppText(body, style: context.setupBody),
          ],
        ),
      ),
    );
  }
}

/// A one-line bind status for the pedal output link, exposed to screen readers
/// via the text itself (semantics, not color-only).
class _PedalStatusLine extends StatelessWidget {
  const _PedalStatusLine({required this.status, required this.deviceName});

  final PedalBindStatus status;
  final String deviceName;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final (message, isError) = switch (status) {
      PedalBindStatus.none => (l10n.pedalStatusNone, false),
      PedalBindStatus.connecting => (l10n.pedalStatusConnecting, false),
      PedalBindStatus.bound => (l10n.pedalStatusBound(deviceName), false),
      PedalBindStatus.error => (l10n.pedalStatusError(deviceName), true),
    };
    // A live region so bind / connecting / error transitions are announced as
    // they happen, not only on navigation (WCAG 4.1.3).
    return Semantics(
      liveRegion: true,
      child: AppText(
        message,
        key: const Key('pedalSettings_status'),
        style: context.setupBody.copyWith(
          color: isError ? Theme.of(context).colorScheme.error : null,
        ),
      ),
    );
  }
}
