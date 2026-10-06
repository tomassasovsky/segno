import 'package:flutter/material.dart';
import 'package:segno/common/console_surface.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/theme/theme.dart';
import 'package:storage_repository/storage_repository.dart';

/// `Save to` (pen 48 `cH9UX`): Internal, then each USB drive by its label,
/// as a row of pills. The recorder is the first to use it; the Library and
/// backup choose a destination the same way.
///
/// A drive that cannot take the write is drawn disabled, and the line under
/// the row says why (read-only, not supported, too slow for
/// [requiredBytesPerSecond]). With no drive at all a `USB drive` pill stands
/// in, and choosing it calls [onConnectUsb] (the Connect USB sheet). Drives
/// being ejected or already ejected are not offered. When [enabled] is false
/// (a take is recording) the row gives way to the chosen destination's name
/// (pen 48 `FwjUV`).
class StorageDestinationPicker extends StatelessWidget {
  /// Creates a [StorageDestinationPicker].
  const StorageDestinationPicker({
    required this.volumes,
    required this.value,
    required this.onChanged,
    required this.onConnectUsb,
    this.requiredBytesPerSecond,
    this.enabled = true,
    super.key,
  });

  /// The removable volumes, in every state.
  final List<RemovableVolume> volumes;

  /// The chosen destination.
  final StorageDestination value;

  /// Called with a newly chosen destination.
  final ValueChanged<StorageDestination> onChanged;

  /// Called when USB is chosen with no drive to choose.
  final VoidCallback onConnectUsb;

  /// The write rate the job needs; a drive whose measured rate is below it is
  /// disabled as too slow. Null: no requirement.
  final int? requiredBytesPerSecond;

  /// Whether the choice can change now.
  final bool enabled;

  String _label(BuildContext context, RemovableVolume volume) =>
      volume.label.isEmpty ? context.l10n.storageUsbUnnamed : volume.label;

  /// Why [volume] cannot take the write, or null when it can.
  String? _refusal(BuildContext context, RemovableVolume volume) {
    final l10n = context.l10n;
    final label = _label(context, volume);
    final required = requiredBytesPerSecond;
    final measured = volume.writeBytesPerSecond;
    return switch (volume.status) {
      RemovableVolumeStatus.readOnly => l10n.storageUsbReadOnly(label),
      RemovableVolumeStatus.unsupported ||
      RemovableVolumeStatus.mountFailed => l10n.saveToUnsupported(label),
      RemovableVolumeStatus.mounted
          when required != null && measured != null && measured < required =>
        l10n.saveToTooSlow(label),
      _ => null,
    };
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final offered = [
      for (final volume in volumes)
        if (volume.status != RemovableVolumeStatus.ejecting &&
            volume.status != RemovableVolumeStatus.ejected)
          volume,
    ];
    final chosen = switch (value) {
      InternalDestination() => l10n.storageInternalTitle,
      RemovableDestination(:final generation) =>
        offered
                .where((v) => v.generation == generation)
                .map((v) => _label(context, v))
                .firstOrNull ??
            l10n.storageUsbTitle,
    };
    final refusals = [
      for (final volume in offered) ?_refusal(context, volume),
    ];
    return Column(
      key: const Key('save_to'),
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        _SaveToHeading(l10n.saveTo),
        const SizedBox(height: 10),
        if (!enabled)
          _SaveToChosen(chosen)
        else ...[
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              _DestinationPill(
                key: const Key('save_to_internal'),
                label: l10n.storageInternalTitle,
                selected: value is InternalDestination,
                onTap: () => onChanged(const StorageDestination.internal()),
              ),
              if (offered.isEmpty)
                _DestinationPill(
                  key: const Key('save_to_connect_usb'),
                  label: l10n.storageUsbTitle,
                  selected: false,
                  onTap: onConnectUsb,
                )
              else
                for (final volume in offered)
                  _DestinationPill(
                    key: Key('save_to_usb_${volume.generation}'),
                    label: _label(context, volume),
                    selected:
                        value ==
                        StorageDestination.removable(volume.generation),
                    onTap: _refusal(context, volume) == null
                        ? () => onChanged(
                            StorageDestination.removable(volume.generation),
                          )
                        : null,
                  ),
            ],
          ),
          for (final refusal in refusals) ...[
            const SizedBox(height: 8),
            AppText(
              refusal,
              style: TextStyle(
                color: context.surface.textSecondary,
                fontSize: 20,
                height: 1.2,
              ),
            ),
          ],
        ],
      ],
    );
  }
}

class _SaveToHeading extends StatelessWidget {
  const _SaveToHeading(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => AppText(
    text,
    style: TextStyle(
      color: context.surface.textPrimary,
      fontSize: 24,
      height: 1,
    ),
  );
}

/// The chosen destination's name while the choice is locked (pen `FwjUV`).
class _SaveToChosen extends StatelessWidget {
  const _SaveToChosen(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => AppText(
    text,
    key: const Key('save_to_chosen'),
    style: TextStyle(
      color: context.surface.textPrimary,
      fontSize: 24,
      height: 1,
      fontWeight: FontWeight.w700,
    ),
  );
}

/// One destination (pen `recorder:destination:*`): filled and edged in the
/// accent when chosen, outlined when not, faded when it cannot be chosen.
class _DestinationPill extends StatelessWidget {
  const _DestinationPill({
    required this.label,
    required this.selected,
    required this.onTap,
    super.key,
  });

  final String label;
  final bool selected;

  /// Null: drawn disabled.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final tap = onTap;
    final pill = Semantics(
      button: true,
      selected: selected,
      enabled: tap != null,
      label: label,
      child: InkWell(
        onTap: tap == null
            ? null
            : () {
                // A pick-one: the chosen pill re-tapped changes nothing.
                if (!selected) tap();
              },
        borderRadius: BorderRadius.circular(7),
        child: Container(
          constraints: const BoxConstraints(minWidth: 180, minHeight: 64),
          padding: const EdgeInsets.symmetric(horizontal: 24),
          decoration: BoxDecoration(
            color: selected ? surface.accentSurface : null,
            borderRadius: BorderRadius.circular(7),
            border: Border.all(
              color: selected ? surface.borderStrong : surface.borderSubtle,
            ),
          ),
          // Sized by its label, centred in the pen's 180 x 64 minimum.
          child: Center(
            widthFactor: 1,
            heightFactor: 1,
            child: ExcludeSemantics(
              child: AppText(
                label,
                style: TextStyle(
                  color: selected ? surface.textPrimary : surface.textSecondary,
                  fontSize: 24,
                  height: 1,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    if (tap != null) return pill;
    return Opacity(opacity: surface.disabledOpacity, child: pill);
  }
}

/// `Connect a USB drive` (pen `m5XyVv`): the panel shown when USB is chosen
/// with no drive. The host keeps it up until a drive that can take the write
/// is mounted and closes it with that drive chosen; `Try again` chooses one
/// that is already there, and `Cancel` leaves the choice on Internal.
class ConnectUsbSheet extends StatelessWidget {
  /// Creates a [ConnectUsbSheet].
  const ConnectUsbSheet({
    required this.onTryAgain,
    required this.onCancel,
    super.key,
  });

  /// `Try again`.
  final VoidCallback onTryAgain;

  /// `Cancel`.
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    return Center(
      child: ConsoleDialogShell(
        key: const Key('connect_usb_sheet'),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            AppText(
              l10n.connectUsbTitle,
              style: TextStyle(
                color: surface.textPrimary,
                fontSize: 19,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 10),
            AppText(
              l10n.connectUsbBody,
              style: TextStyle(
                color: surface.textSecondary,
                fontSize: 16,
                height: 1.4,
                leadingDistribution: TextLeadingDistribution.even,
              ),
            ),
            const SizedBox(height: 19),
            Wrap(
              alignment: WrapAlignment.end,
              spacing: 10,
              runSpacing: 10,
              children: [
                IntrinsicWidth(
                  child: ConsoleDialogButton(
                    key: const Key('connect_usb_cancel'),
                    label: l10n.cancel,
                    onPressed: onCancel,
                  ),
                ),
                IntrinsicWidth(
                  child: ConsoleDialogButton(
                    key: const Key('connect_usb_try_again'),
                    label: l10n.connectUsbTryAgain,
                    tone: ConsoleDialogTone.primary,
                    onPressed: onTryAgain,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
