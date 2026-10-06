import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:segno/common/console_surface.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/storage/cubit/storage_cubit.dart';
import 'package:segno/storage/view/storage_recording_time.dart';
import 'package:segno/storage/view/storage_volume_card.dart';
import 'package:storage_repository/storage_repository.dart';

/// The Storage page's volumes (pen 31 `Storage & safe eject`): the Internal
/// card with its recording estimate, then one card per USB volume, or a
/// `Not connected` card when there is none.
///
/// Capacity is read while this is on screen only: on open, on every change
/// to the volume list, and every few seconds until it leaves
/// ([StorageCubit.startWatching] / [StorageCubit.stopWatching]).
///
/// A USB card has no `Browse` yet: the Library cannot open at a drive until
/// #1178 gives it a USB view, and a Browse that opened Internal would show
/// the wrong files as the drive's.
class StoragePage extends StatefulWidget {
  /// Creates a [StoragePage]. [onOpenLibrary] opens the Library at Internal.
  const StoragePage({required this.onOpenLibrary, super.key});

  /// Open library on the Internal card.
  final VoidCallback onOpenLibrary;

  @override
  State<StoragePage> createState() => _StoragePageState();
}

class _StoragePageState extends State<StoragePage> {
  late final StorageCubit _cubit;

  @override
  void initState() {
    super.initState();
    _cubit = context.read<StorageCubit>()..startWatching();
  }

  @override
  void dispose() {
    _cubit.stopWatching();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<StorageCubit>().state;
    final blocks = <Widget>[
      _InternalCard(state: state, onOpenLibrary: widget.onOpenLibrary),
      _RecordingTime(state: state),
      if (state.lowInternalSpace)
        StorageNotice(
          context.l10n.storageLowInternal,
          key: const Key('storage_low_space_banner'),
        ),
      if (state.volumes.isEmpty)
        const _NoUsbCard()
      else
        for (final volume in state.volumes) ...[
          _UsbCard(
            key: Key('storage_usb_card_${volume.generation}'),
            volume: volume,
            space: state.volumeSpace[volume.generation],
            holders: state.holders[volume.generation] ?? const {},
            ejectTaken: state.ejectTaken,
          ),
          if (state.ejectFailed == volume.generation)
            StorageNotice(
              context.l10n.storageEjectFailed,
              key: const Key('storage_eject_failed'),
            ),
          if (state.ejectTaken &&
              volume.status == RemovableVolumeStatus.ejecting)
            StorageNotice(
              context.l10n.storageEjectUnderway,
              key: const Key('storage_eject_underway'),
            ),
        ],
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final (index, block) in blocks.indexed) ...[
          if (index > 0) const SizedBox(height: kConsoleBlockGap),
          block,
        ],
      ],
    );
  }
}

/// A measured volume's capacity, or the sentence that says it was not.
class _Capacity extends StatelessWidget {
  const _Capacity({required this.space, this.low = false});

  final VolumeSpace? space;
  final bool low;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final space = this.space;
    if (space == null || space.totalBytes <= 0) {
      return StorageCardMessage(
        icon: StorageCardMessage.none,
        message: l10n.storageCapacityUnavailable,
      );
    }
    return StorageCapacity(
      free: l10n.storageFreeGigabytes(decimalGigabytes(space.freeBytes)),
      total: l10n.storageOfGigabytes(
        decimalGigabytes(space.totalBytes).round(),
      ),
      usedFraction: 1 - space.freeBytes / space.totalBytes,
      low: low,
    );
  }
}

class _InternalCard extends StatelessWidget {
  const _InternalCard({required this.state, required this.onOpenLibrary});

  final StorageState state;
  final VoidCallback onOpenLibrary;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return StorageVolumeCard(
      key: const Key('storage_internal_card'),
      title: l10n.storageInternalTitle,
      subtitle: l10n.storageInternalSubtitle,
      body: _Capacity(
        space: state.internalSpace,
        low: state.lowInternalSpace,
      ),
      actions: [
        StorageCardButton(
          key: const Key('storage_open_library'),
          label: l10n.storageOpenLibrary,
          onPressed: onOpenLibrary,
        ),
      ],
    );
  }
}

class _RecordingTime extends StatelessWidget {
  const _RecordingTime({required this.state});

  final StorageState state;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final time = state.recordingTime;
    return StorageRecordingTime(
      key: const Key('storage_recording_time'),
      headline: switch (time) {
        null => l10n.storageRecordingTimeUnavailable,
        Duration(inMinutes: 0) => l10n.storageNoRecordingSpace,
        _ => l10n.storageRecordingRemaining(
          time.inHours,
          time.inMinutes % 60,
        ),
      },
      format: state.sampleRate > 0
          ? l10n.storageRecordingFormat(state.sampleRate / 1000)
          : null,
      note: l10n.storageReserveNote(
        decimalGigabytes(StorageRepository.internalReserveBytes),
      ),
    );
  }
}

class _NoUsbCard extends StatelessWidget {
  const _NoUsbCard();

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return StorageVolumeCard(
      key: const Key('storage_usb_card_none'),
      title: l10n.storageUsbTitle,
      subtitle: l10n.storageUsbNotConnected,
      body: StorageCardMessage(
        icon: StorageCardMessage.none,
        message: l10n.storageUsbConnectHint,
      ),
    );
  }
}

class _UsbCard extends StatelessWidget {
  const _UsbCard({
    required this.volume,
    required this.space,
    required this.holders,
    required this.ejectTaken,
    super.key,
  });

  final RemovableVolume volume;
  final VolumeSpace? space;
  final Set<WritePurpose> holders;

  /// The helper has the eject; Cancel can no longer stop it.
  final bool ejectTaken;

  /// The names the pen's copy uses for the filesystems the image cannot
  /// drive; anything else is shown as udev names it, upper-cased.
  static const _fsNames = {
    'hfsplus': 'HFS+',
    'apfs': 'APFS',
    'btrfs': 'Btrfs',
    'crypto_LUKS': 'LUKS',
  };

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final cubit = context.read<StorageCubit>();
    final label = volume.label.isEmpty ? l10n.storageUsbUnnamed : volume.label;
    final eject = StorageCardButton(
      key: const Key('storage_eject'),
      label: l10n.storageEject,
      tone: ConsoleDialogTone.primary,
      // Eject is unavailable during USB work (accepted behaviour §7.7); the
      // subtitle names the work.
      onPressed: holders.isEmpty
          ? () => unawaited(cubit.eject(volume.generation))
          : null,
    );
    final (subtitle, body, actions) = switch (volume.status) {
      RemovableVolumeStatus.mounted => (
        holders.isEmpty
            ? label
            : l10n.storageUsbInUse(
                label,
                [for (final p in holders) _purposeWords(l10n, p)].join(', '),
              ),
        _Capacity(space: space),
        [eject],
      ),
      RemovableVolumeStatus.readOnly => (
        l10n.storageUsbReadOnly(label),
        _Capacity(space: space),
        [eject],
      ),
      RemovableVolumeStatus.ejecting => (
        l10n.storageUsbEjecting,
        _Capacity(space: space),
        [
          if (!ejectTaken)
            StorageCardButton(
              key: const Key('storage_eject_cancel'),
              label: l10n.cancel,
              onPressed: () => unawaited(cubit.cancelEject()),
            ),
        ],
      ),
      RemovableVolumeStatus.ejected => (
        l10n.storageUsbSafeToRemove,
        StorageCardMessage(
          icon: StorageCardMessage.done,
          message: l10n.storageUsbSafeToRemoveBody,
        ),
        const <Widget>[],
      ),
      RemovableVolumeStatus.unsupported => (
        label,
        StorageCardMessage(
          icon: StorageCardMessage.none,
          message: volume.fsType == 'none'
              ? l10n.storageUsbUnformatted
              : l10n.storageUsbUnsupported(
                  _fsNames[volume.fsType] ?? volume.fsType.toUpperCase(),
                ),
        ),
        const <Widget>[],
      ),
      RemovableVolumeStatus.mountFailed => (
        label,
        StorageCardMessage(
          icon: StorageCardMessage.none,
          message: l10n.storageUsbMountFailed,
        ),
        const <Widget>[],
      ),
    };
    return StorageVolumeCard(
      title: l10n.storageUsbTitle,
      subtitle: subtitle,
      body: body,
      actions: actions,
    );
  }

  static String _purposeWords(AppLocalizations l10n, WritePurpose purpose) =>
      switch (purpose) {
        WritePurpose.recording => l10n.storagePurposeRecording,
        WritePurpose.copy => l10n.storagePurposeCopy,
        WritePurpose.export => l10n.storagePurposeExport,
        WritePurpose.backup => l10n.storagePurposeBackup,
      };
}
