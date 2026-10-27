import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/view/loop_settings/loop_settings_widgets.dart';
import 'package:segno/theme/theme.dart';
import 'package:segno/update/usb/usb_update_cubit.dart';
import 'package:segno/update/usb/usb_update_package.dart';

/// Load from USB's panel on Updates (#1270 Part 8, pen 33): the packages on
/// the plugged-in drives, the copy and install of one, and why one was not
/// installed. Nothing while the list is closed.
class UpdatesUsbPanel extends StatelessWidget {
  /// Creates an [UpdatesUsbPanel]; [onClosed] runs when the list closes.
  const UpdatesUsbPanel({required this.onClosed, super.key});

  /// Called once the list is closed: by Cancel, or by a package staged.
  final VoidCallback onClosed;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    final cubit = context.read<UsbUpdateCubit>();
    final state = context.watch<UsbUpdateCubit>().state;
    if (state.phase == UsbUpdatePhase.closed) {
      WidgetsBinding.instance.addPostFrameCallback((_) => onClosed());
      return const SizedBox.shrink();
    }

    final (String? line, LoopNoteTone tone) = switch (state.phase) {
      UsbUpdatePhase.noDrive => (l10n.updatesUsbNoDrive, LoopNoteTone.plain),
      UsbUpdatePhase.reading => (l10n.updatesUsbReading, LoopNoteTone.plain),
      UsbUpdatePhase.empty => (
        l10n.updatesUsbEmpty(state.driveLabel),
        LoopNoteTone.plain,
      ),
      UsbUpdatePhase.copying => (l10n.updatesUsbCopying, LoopNoteTone.plain),
      UsbUpdatePhase.installing => (
        l10n.updatesUsbInstalling,
        LoopNoteTone.plain,
      ),
      UsbUpdatePhase.failed => (_failure(l10n, state), LoopNoteTone.error),
      UsbUpdatePhase.list ||
      UsbUpdatePhase.closed => (null, LoopNoteTone.plain),
    };
    final action = switch (state.phase) {
      UsbUpdatePhase.copying => LoopOutlinedButton(
        key: const Key('updates_usb_cancel_copy'),
        width: 160,
        label: l10n.cancel,
        onTap: cubit.cancel,
      ),
      UsbUpdatePhase.installing => null,
      UsbUpdatePhase.failed => LoopOutlinedButton(
        key: const Key('updates_usb_back'),
        width: 160,
        label: l10n.updatesUsbBack,
        onTap: cubit.back,
      ),
      _ => LoopOutlinedButton(
        key: const Key('updates_usb_close'),
        width: 160,
        label: l10n.cancel,
        onTap: cubit.closePanel,
      ),
    };

    return Container(
      key: const Key('updates_usb_panel'),
      padding: const EdgeInsets.all(37),
      decoration: BoxDecoration(
        color: surface.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: surface.frameControlLine),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(child: LoopSectionLabel(l10n.updatesUsbChoose)),
              ?action,
            ],
          ),
          const SizedBox(height: 28),
          if (line != null)
            LoopNote(line, key: const Key('updates_usb_line'), tone: tone),
          if (state.phase == UsbUpdatePhase.copying ||
              state.phase == UsbUpdatePhase.installing) ...[
            const SizedBox(height: 18),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                key: const Key('updates_usb_progress'),
                minHeight: 8,
                // The copy cannot say how far it is; the install can.
                value: state.phase == UsbUpdatePhase.installing
                    ? state.progress
                    : null,
                color: surface.accent,
                backgroundColor: surface.control,
              ),
            ),
          ],
          if (state.phase == UsbUpdatePhase.list)
            for (final (index, package) in state.packages.indexed) ...[
              if (index > 0) const SizedBox(height: 16),
              _PackageRow(
                key: Key('updates_usb_package_$index'),
                package: package,
                autofocus: index == 0,
                onTap: () => cubit.choose(package),
              ),
            ],
        ],
      ),
    );
  }

  static String _failure(AppLocalizations l10n, UsbUpdateState state) =>
      switch (state.error) {
        UsbUpdateError.unverified => l10n.updatesUsbUnverified,
        UsbUpdateError.notNewer => l10n.updatesUsbNotNewer(
          '${state.refusedVersion ?? ''}',
          '${state.installedVersion ?? ''}',
        ),
        UsbUpdateError.removed => l10n.updatesUsbRemoved,
        UsbUpdateError.noSpace => l10n.updatesUsbNoSpace(
          l10n.updatesUsbMegabytes(_megabytes(state.neededBytes ?? 0)),
        ),
        UsbUpdateError.busy => l10n.operationBusy(state.busyKind ?? 'other'),
        UsbUpdateError.bootReadOnly => l10n.updatesPageBootReadOnly,
        UsbUpdateError.failed || null => l10n.updatesUsbFailed,
      };
}

/// Whole megabytes, rounded up: a size is never said as less than it is.
int _megabytes(int bytes) => (bytes + (1 << 20) - 1) >> 20;

class _PackageRow extends StatelessWidget {
  const _PackageRow({
    required this.package,
    required this.onTap,
    this.autofocus = false,
    super.key,
  });

  final UsbUpdatePackage package;
  final VoidCallback onTap;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    final version = package.version;
    final title = version == null ? package.name : 'Segno $version';
    final meta = [
      l10n.updatesUsbMegabytes(_megabytes(package.sizeBytes)),
      package.name,
    ].join(' · ');
    return Semantics(
      button: true,
      label: title,
      value: meta,
      child: LoopFocusable(
        autofocus: autofocus,
        onActivate: onTap,
        child: Material(
          color: surface.frameControlFill,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
            side: BorderSide(color: surface.frameControlLine),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            canRequestFocus: false,
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 29, vertical: 14),
              child: ExcludeSemantics(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    AppText(
                      title,
                      style: TextStyle(
                        color: surface.textPrimary,
                        fontSize: 26,
                        height: 1.2,
                      ),
                    ),
                    const SizedBox(height: 4),
                    AppText(
                      meta,
                      key: const Key('updates_usb_package_meta'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: surface.textSecondary,
                        fontSize: 20,
                        height: 1.2,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
