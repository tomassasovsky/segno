import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:segno/common/console_rename_sheet.dart';
import 'package:segno/common/console_surface.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/library/application/removable_volumes.dart';
import 'package:segno/library/cubit/library_audio_cubit.dart';
import 'package:segno/library/cubit/library_cubit.dart';
import 'package:segno/library/view/library_audio_dialogs.dart';
import 'package:segno/library/view/library_preview_card.dart';
import 'package:segno/library/view/library_sessions_tab.dart';
import 'package:segno/looper/view/loop_settings/loop_settings_widgets.dart';
import 'package:segno/theme/theme.dart';

/// Library > Audio (pen 18/01, 20/07 to 20/12; #1178 Part 7): the location
/// and search row over the file browser and the preview card, or, while an
/// export runs or once it is done, its progress (20/08) or result (20/12).
///
/// The sub-nav row (`Prepared audio`, `Save audio`, `Record performance`)
/// and the actions that belong to later work (`Add to prepared`, `Use as
/// backing`, `Use in loop`, `Show on USB`) are not drawn (plan deviation 3).
class LibraryAudioTab extends StatelessWidget {
  /// Creates the Audio tab.
  const LibraryAudioTab({super.key});

  @override
  Widget build(BuildContext context) {
    final export = context.select<LibraryAudioCubit, LibraryAudioExport?>(
      (c) => c.state.export,
    );
    return BlocListener<LibraryAudioCubit, LibraryAudioState>(
      listenWhen: (previous, current) =>
          previous.export != current.export &&
          (current.export is LibraryExportConflict ||
              current.export is LibraryExportNeedsDrive),
      listener: (context, state) => unawaited(
        showLibraryExportQuestion(context, state.export!),
      ),
      child: switch (export) {
        final LibraryExportRunning running => LibraryExportProgress(
          export: running,
        ),
        final LibraryExportDone done => LibraryExportResult(export: done),
        _ => const Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(height: 64, child: LibraryAudioTools()),
            SizedBox(height: 28),
            Expanded(child: LibraryAudioBrowser()),
          ],
        ),
      },
    );
  }
}

/// The `Internal` / `USB drive` segment and `Search audio`.
class LibraryAudioTools extends StatelessWidget {
  /// Creates the tools row.
  const LibraryAudioTools({super.key});

  Future<void> _search(BuildContext context, String query) async {
    final cubit = context.read<LibraryAudioCubit>();
    final l10n = context.l10n;
    final answer = await showConsoleRenameSheet(
      context,
      title: l10n.librarySearchAudio,
      subtitle: l10n.librarySearchAudio,
      current: query,
      fieldLabel: l10n.librarySearchAudio,
      allowEmpty: true,
    );
    if (answer != null) cubit.search(answer.trim());
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final location = context.select<LibraryCubit, LibraryLocation>(
      (c) => c.state.location,
    );
    final query = context.select<LibraryAudioCubit, String>(
      (c) => c.state.query,
    );
    final library = context.read<LibraryCubit>();
    return Row(
      children: [
        LoopChoiceButton(
          key: const Key('library_audio_internal'),
          label: l10n.libraryInternal,
          selected: location == LibraryLocation.internal,
          onTap: () => library.setLocation(LibraryLocation.internal),
          width: 180,
          height: 64,
        ),
        const SizedBox(width: 12),
        LoopChoiceButton(
          key: const Key('library_audio_usb'),
          label: l10n.libraryUsbDrive,
          selected: location == LibraryLocation.usb,
          onTap: () => library.setLocation(LibraryLocation.usb),
          width: 180,
          height: 64,
        ),
        const Spacer(),
        SizedBox(
          width: 310,
          child: LibrarySearchBox(
            key: const Key('library_audio_search'),
            text: query.isEmpty ? l10n.librarySearchAudio : query,
            placeholder: query.isEmpty,
            semanticLabel: l10n.librarySearchAudio,
            onTap: () => unawaited(_search(context, query)),
          ),
        ),
      ],
    );
  }
}

/// The 1060-wide file list beside the 684-wide preview card.
class LibraryAudioBrowser extends StatelessWidget {
  /// Creates the browser.
  const LibraryAudioBrowser({super.key});

  @override
  Widget build(BuildContext context) {
    final location = context.select<LibraryCubit, LibraryLocation>(
      (c) => c.state.location,
    );
    final readable = context.select<LibraryCubit, bool>(
      (c) => c.state.hasReadableVolume,
    );
    final unusable = context.select<LibraryCubit, RemovableVolume?>(
      (c) => c.state.unusableVolume,
    );
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          width: 1060,
          child: switch (location) {
            LibraryLocation.internal => const LibraryAudioFiles(),
            // Browsing a drive's audio is later work (import is a non-goal
            // here); a mounted drive shows an empty list, not a fake one.
            LibraryLocation.usb when readable => const SizedBox.shrink(),
            LibraryLocation.usb when unusable != null => LibraryUnusableUsb(
              volume: unusable,
            ),
            LibraryLocation.usb => const LibraryConnectUsb(),
          },
        ),
        const SizedBox(width: 48),
        const Expanded(child: LibraryAudioCard()),
      ],
    );
  }
}

/// The folder path row and the folder's rows: at the top the two folders,
/// inside one its files.
class LibraryAudioFiles extends StatelessWidget {
  /// Creates the file list.
  const LibraryAudioFiles({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    final state = context.watch<LibraryAudioCubit>().state;
    final cubit = context.read<LibraryAudioCubit>();
    final folder = state.folder;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DecoratedBox(
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: surface.borderSubtle)),
          ),
          child: SizedBox(
            height: 77,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Opacity(
                  opacity: folder == null ? surface.disabledOpacity : 1,
                  child: LoopOutlinedButton(
                    key: const Key('library_audio_parent'),
                    width: 60,
                    height: 60,
                    icon: LucideIcons.cornerLeftUp,
                    semanticLabel: l10n.libraryAudioParentFolder,
                    onTap: folder == null ? null : cubit.closeFolder,
                  ),
                ),
                const SizedBox(width: 20),
                Padding(
                  padding: const EdgeInsets.only(top: 16),
                  child: AppText(
                    key: const Key('library_audio_path'),
                    switch (folder) {
                      null => l10n.libraryInternal,
                      LibraryAudioFolder.performances =>
                        l10n.libraryAudioPerformances,
                      LibraryAudioFolder.sessions => l10n.librarySessions,
                    },
                    style: TextStyle(
                      color: surface.textSecondary,
                      fontSize: 25,
                      height: 1,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        Expanded(
          child: folder == null
              ? ListView(
                  key: const Key('library_audio_folders'),
                  padding: const EdgeInsets.only(top: 12, right: 12),
                  itemExtent: 96,
                  children: [
                    LibraryAudioRow(
                      key: const Key('library_audio_folder_performances'),
                      icon: LucideIcons.folder,
                      name: l10n.libraryAudioPerformances,
                      trailing: l10n.libraryAudioFolderCount(
                        state.recordings.length,
                      ),
                      onTap: () =>
                          cubit.openFolder(LibraryAudioFolder.performances),
                    ),
                    LibraryAudioRow(
                      key: const Key('library_audio_folder_sessions'),
                      icon: LucideIcons.folder,
                      name: l10n.librarySessions,
                      trailing: l10n.libraryAudioFolderCount(
                        state.mixdowns.length,
                      ),
                      onTap: () =>
                          cubit.openFolder(LibraryAudioFolder.sessions),
                    ),
                  ],
                )
              : const LibraryAudioItems(),
        ),
      ],
    );
  }
}

/// The open folder's files, or one line when it has none to show.
class LibraryAudioItems extends StatelessWidget {
  /// Creates the open folder's rows.
  const LibraryAudioItems({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final state = context.watch<LibraryAudioCubit>().state;
    final items = state.items;
    if (items.isEmpty) {
      return Padding(
        padding: const EdgeInsets.only(top: 36),
        child: AppText(
          state.query.trim().isEmpty
              ? l10n.libraryAudioEmpty
              : l10n.libraryAudioNoMatches,
          key: const Key('library_audio_empty'),
          style: TextStyle(
            color: context.surface.textSecondary,
            fontSize: 22,
            height: 1,
          ),
        ),
      );
    }
    final cubit = context.read<LibraryAudioCubit>();
    return ListView.builder(
      key: const Key('library_audio_rows'),
      padding: const EdgeInsets.only(top: 12, right: 12),
      itemExtent: 96,
      itemCount: items.length,
      itemBuilder: (context, i) {
        final item = items[i];
        final recovered = item is LibraryRecording && item.capture.recovered;
        return LibraryAudioRow(
          key: Key('library_audio_row_${item.key}'),
          icon: LucideIcons.fileAudio,
          name: item.name,
          tag: recovered ? l10n.libraryAudioRecovered : null,
          trailing: audioClock(item.duration),
          selected: item.key == state.selectedKey,
          onTap: () => unawaited(cubit.select(item)),
        );
      },
    );
  }
}

/// `m:ss`, or `h:mm:ss` from an hour.
String audioClock(Duration d) {
  final s = d.inSeconds;
  final hours = s ~/ 3600;
  final mm = (s % 3600 ~/ 60).toString();
  final ss = (s % 60).toString().padLeft(2, '0');
  return hours > 0 ? '$hours:${mm.padLeft(2, '0')}:$ss' : '$mm:$ss';
}

/// One 96-tall row of the file browser: a glyph, the name, an optional tag
/// (a recovered take), and a trailing fact (a length or a file count).
class LibraryAudioRow extends StatelessWidget {
  /// Creates a row.
  const LibraryAudioRow({
    required this.icon,
    required this.name,
    required this.trailing,
    required this.onTap,
    this.tag,
    this.selected = false,
    super.key,
  });

  /// The row's glyph: a folder or a file.
  final IconData icon;

  /// The folder's or file's name.
  final String name;

  /// What the right edge says.
  final String trailing;

  /// A word beside [trailing], when the row has one.
  final String? tag;

  /// Whether the preview card shows this row.
  final bool selected;

  /// Opens the folder, or selects the file.
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return Semantics(
      button: true,
      selected: selected,
      label: name,
      value: [?tag, trailing].join(', '),
      child: LoopFocusable(
        onActivate: onTap,
        child: Material(
          color: selected ? surface.accentSurface : Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(6),
            side: BorderSide(
              color: selected ? surface.accent : Colors.transparent,
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            canRequestFocus: false,
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 21),
              child: Row(
                children: [
                  Icon(icon, size: 30, color: surface.textSecondary),
                  const SizedBox(width: 22),
                  Expanded(
                    child: AppText(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: surface.textPrimary,
                        fontSize: 25,
                        height: 1.2,
                      ),
                    ),
                  ),
                  if (tag case final tag?) ...[
                    const SizedBox(width: 16),
                    AppText(
                      tag,
                      key: const Key('library_audio_row_tag'),
                      style: TextStyle(
                        color: surface.warning,
                        fontSize: 21,
                        height: 1.2,
                      ),
                    ),
                  ],
                  const SizedBox(width: 22),
                  AppText(
                    trailing,
                    style: TextStyle(
                      color: surface.textSecondary,
                      fontFamily: SurfaceTheme.monoFont,
                      fontSize: 21,
                      height: 1.2,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The 684 x 728 preview card: kind and length, name, waveform, `Preview`,
/// the line that reports a failed action, and the item's actions.
class LibraryAudioCard extends StatelessWidget {
  /// Creates the card.
  const LibraryAudioCard({super.key});

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final l10n = context.l10n;
    final state = context.watch<LibraryAudioCubit>().state;
    final item = state.selected;
    return DecoratedBox(
      key: const Key('library_audio_card'),
      decoration: BoxDecoration(
        color: surface.card,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: surface.borderSubtle),
      ),
      child: Padding(
        padding: const EdgeInsets.all(37),
        child: item == null
            ? AppText(
                l10n.libraryAudioNoSelection,
                key: const Key('library_audio_no_selection'),
                style: TextStyle(
                  color: surface.textSecondary,
                  fontSize: 22,
                  height: 1.2,
                ),
              )
            : LibraryAudioPreviewBody(item: item),
      ),
    );
  }
}

/// The selected item's side of the card.
class LibraryAudioPreviewBody extends StatelessWidget {
  /// Creates the body for [item].
  const LibraryAudioPreviewBody({required this.item, super.key});

  /// The selected file.
  final LibraryAudioItem item;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final l10n = context.l10n;
    final state = context.watch<LibraryAudioCubit>().state;
    final item = this.item;
    final parts = item is LibraryRecording
        ? item.capture.masterParts.length
        : 1;
    final recovered = item is LibraryRecording && item.capture.recovered;
    final kind = [
      if (parts > 1) l10n.libraryAudioParts(parts) else l10n.libraryAudioWav,
      if (recovered) l10n.libraryAudioRecovered,
    ].join(' · ');
    final factStyle = TextStyle(
      color: surface.textSecondary,
      fontSize: 21,
      height: 1.15,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: 24,
          child: Row(
            children: [
              Expanded(
                child: AppText(
                  kind,
                  key: const Key('library_audio_kind'),
                  style: factStyle,
                ),
              ),
              AppText(
                audioClock(item.duration),
                key: const Key('library_audio_duration'),
                style: factStyle,
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),
        SizedBox(
          height: 44,
          child: AppText(
            item.name,
            key: const Key('library_audio_name'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: surface.textPrimary,
              fontSize: 35,
              height: 1.2,
            ),
          ),
        ),
        const SizedBox(height: 36),
        SizedBox(
          height: 176,
          child: switch (state.peaks) {
            final peaks? => CustomPaint(
              key: const Key('library_audio_peaks'),
              painter: LibraryPeaksPainter(peaks: peaks, color: surface.accent),
            ),
            null => const SizedBox.shrink(),
          },
        ),
        const SizedBox(height: 36),
        SizedBox(height: 64, child: LibraryAudioPreviewControl(item: item)),
        const SizedBox(height: 60),
        const SizedBox(height: 30, child: LibraryAudioLine()),
        const SizedBox(height: 16),
        LibraryAudioActions(item: item),
      ],
    );
  }
}

/// `Preview` (198 x 64), `Stop` while it plays, with how far it has played.
class LibraryAudioPreviewControl extends StatelessWidget {
  /// Creates the control for [item].
  const LibraryAudioPreviewControl({required this.item, super.key});

  /// The selected file.
  final LibraryAudioItem item;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    final preview = context.select<LibraryAudioCubit, LibraryAudioPreview?>(
      (c) => c.state.preview,
    );
    final playing = preview != null && preview.key == item.key;
    return Row(
      children: [
        LoopOutlinedButton(
          key: const Key('library_audio_preview'),
          width: 198,
          leadingIcon: playing ? LucideIcons.square : LucideIcons.play,
          label: playing ? l10n.libraryListenStop : l10n.libraryAudioPreview,
          onTap: () => unawaited(context.read<LibraryAudioCubit>().preview()),
        ),
        if (playing) ...[
          const SizedBox(width: 20),
          AppText(
            l10n.libraryListenProgress(
              audioClock(_at(preview.position, preview.sampleRate)),
              audioClock(_at(preview.frames, preview.sampleRate)),
            ),
            key: const Key('library_audio_progress'),
            style: TextStyle(
              color: surface.textSecondary,
              fontFamily: SurfaceTheme.monoFont,
              fontSize: 21,
              height: 1,
            ),
          ),
        ],
      ],
    );
  }

  static Duration _at(int frames, int rate) => rate <= 0
      ? Duration.zero
      : Duration(microseconds: frames * Duration.microsecondsPerSecond ~/ rate);
}

/// The card's one line (pen 20/11's place): a failed action, a refused
/// `Preview`, the truncation note, or that the DAW project was written.
class LibraryAudioLine extends StatelessWidget {
  /// Creates the line.
  const LibraryAudioLine({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    final state = context.watch<LibraryAudioCubit>().state;
    final failure = switch (state.error) {
      LibraryAudioError.notEnoughSpace => l10n.libraryAudioNotEnoughSpace,
      LibraryAudioError.readOnly => l10n.libraryAudioReadOnly,
      LibraryAudioError.exportFailed => l10n.libraryAudioExportFailed,
      LibraryAudioError.dawProjectFailed => l10n.libraryAudioDawProjectFailed,
      LibraryAudioError.deleteBusy => l10n.libraryAudioDeleteBusy,
      LibraryAudioError.deleteFailed => l10n.libraryAudioDeleteFailed,
      null => switch (state.previewRefusal) {
        LibraryListenRefusal.unplayable => l10n.libraryListenFailed,
        LibraryListenRefusal.noDevice => l10n.libraryListenNoDevice,
        LibraryListenRefusal.performanceArmed => l10n.libraryListenRecording,
        LibraryListenRefusal.busy => l10n.libraryListenBusy,
        null => null,
      },
    };
    final note = failure != null
        ? null
        : (state.preview?.truncated ?? false)
        ? l10n.libraryListenTruncated
        : state.dawProjectWritten
        ? l10n.libraryAudioDawProjectWritten
        : null;
    final text = failure ?? note;
    if (text == null) return const SizedBox.shrink();
    return Semantics(
      liveRegion: true,
      child: AppText(
        text,
        key: const Key('library_audio_line'),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: failure != null ? surface.rec : surface.textSecondary,
          fontSize: 21,
          height: 1.2,
        ),
      ),
    );
  }
}

/// The item's actions, two 299-wide buttons a row: a recording's `Export to
/// USB`, `DAW project` and `Delete`; a session's `Export to USB` (its
/// mixdown) and `Export stems`.
class LibraryAudioActions extends StatelessWidget {
  /// Creates the actions for [item].
  const LibraryAudioActions({required this.item, super.key});

  /// The selected file.
  final LibraryAudioItem item;

  Future<void> _exportRecording(BuildContext context) async {
    final cubit = context.read<LibraryAudioCubit>();
    final purpose = context.l10n.libraryAudioPurpose(item.name);
    final kind = await showLibraryExportChooser(context);
    if (kind != null) await cubit.export(kind, purpose: purpose);
  }

  Future<void> _delete(BuildContext context) async {
    final cubit = context.read<LibraryAudioCubit>();
    final l10n = context.l10n;
    final confirmed = await showConsoleConfirmDialog(
      context,
      title: l10n.libraryAudioDeleteTitle(item.name),
      body: l10n.libraryAudioDeleteBody,
      confirmLabel: l10n.libraryAudioDelete,
    );
    if (confirmed) await cubit.deleteRecording();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final cubit = context.read<LibraryAudioCubit>();
    final purpose = l10n.libraryAudioPurpose(item.name);
    Widget button(String key, String label, VoidCallback onTap) =>
        LoopOutlinedButton(
          key: Key(key),
          width: 299,
          fontSize: 23,
          label: label,
          onTap: onTap,
        );
    final rows = switch (item) {
      LibraryRecording() => [
        [
          button(
            'library_audio_export',
            l10n.libraryAudioExportUsb,
            () => unawaited(_exportRecording(context)),
          ),
          button(
            'library_audio_daw_project',
            l10n.libraryAudioDawProject,
            () => unawaited(cubit.writeProject()),
          ),
        ],
        [
          button(
            'library_audio_delete',
            l10n.libraryAudioDelete,
            () => unawaited(_delete(context)),
          ),
        ],
      ],
      LibraryMixdown() => [
        [
          button(
            'library_audio_export',
            l10n.libraryAudioExportUsb,
            () => unawaited(
              cubit.export(LibraryAudioExportKind.mixdown, purpose: purpose),
            ),
          ),
          button(
            'library_audio_export_stems',
            l10n.libraryAudioExportStems,
            () => unawaited(
              cubit.export(LibraryAudioExportKind.stems, purpose: purpose),
            ),
          ),
        ],
      ],
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final (i, row) in rows.indexed) ...[
          if (i > 0) const SizedBox(height: 16),
          Row(
            children: [
              for (final (j, b) in row.indexed) ...[
                if (j > 0) const SizedBox(width: 12),
                b,
              ],
            ],
          ),
        ],
      ],
    );
  }
}

/// Pen 20/08: the export's name, where it goes, how far it is, and
/// `Cancel`.
class LibraryExportProgress extends StatelessWidget {
  /// Creates the progress view of [export].
  const LibraryExportProgress({required this.export, super.key});

  /// The running export.
  final LibraryExportRunning export;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final l10n = context.l10n;
    return Column(
      key: const Key('library_export_progress'),
      children: [
        const SizedBox(height: 251),
        LibraryExportHeading(name: export.name),
        const SizedBox(height: 44),
        AppText(
          l10n.libraryAudioExportRoute(exportFolderLabel(l10n, export.folder)),
          style: TextStyle(color: surface.textSecondary, fontSize: 23),
        ),
        const SizedBox(height: 46),
        SizedBox(
          width: 820,
          height: 14,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(7),
            child: LinearProgressIndicator(
              key: const Key('library_export_bar'),
              value: export.fraction,
              backgroundColor: surface.cardHigh,
              color: surface.accent,
            ),
          ),
        ),
        const SizedBox(height: 60),
        LoopOutlinedButton(
          key: const Key('library_export_cancel'),
          width: 125,
          label: l10n.cancel,
          onTap: context.read<LibraryAudioCubit>().cancelExport,
        ),
      ],
    );
  }
}

/// Pen 20/12: the mark, what landed and where, that the internal copy is
/// kept, and `Done`.
class LibraryExportResult extends StatelessWidget {
  /// Creates the result view of [export].
  const LibraryExportResult({required this.export, super.key});

  /// The finished export.
  final LibraryExportDone export;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final l10n = context.l10n;
    final style = TextStyle(color: surface.textSecondary, fontSize: 23);
    return Column(
      key: const Key('library_export_done'),
      children: [
        const SizedBox(height: 195),
        Container(
          width: 90,
          height: 90,
          decoration: BoxDecoration(
            color: surface.accentSurface,
            shape: BoxShape.circle,
            border: Border.all(color: surface.accent),
          ),
          child: Icon(LucideIcons.check, size: 46, color: surface.accent),
        ),
        const SizedBox(height: 28),
        LibraryExportHeading(name: export.name),
        const SizedBox(height: 44),
        AppText(
          l10n.libraryAudioExportPlace(exportFolderLabel(l10n, export.folder)),
          style: style,
        ),
        const SizedBox(height: 29),
        AppText(
          export.folder == LibraryAudioFolder.performances
              ? l10n.libraryAudioRecordingKept
              : l10n.libraryAudioSessionKept,
          style: style,
        ),
        const SizedBox(height: 52),
        LoopOutlinedButton(
          key: const Key('library_export_done_button'),
          width: 110,
          tone: LoopButtonTone.accent,
          label: l10n.libraryAudioDone,
          onTap: context.read<LibraryAudioCubit>().dismissExport,
        ),
      ],
    );
  }
}

/// The 44-point name over an export's progress or result.
class LibraryExportHeading extends StatelessWidget {
  /// Creates the heading for [name].
  const LibraryExportHeading({required this.name, super.key});

  /// What is exported.
  final String name;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 820,
    height: 57,
    child: AppText(
      name,
      key: const Key('library_export_name'),
      textAlign: TextAlign.center,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        color: context.surface.textPrimary,
        fontSize: 44,
        height: 1.2,
      ),
    ),
  );
}

/// The folder's name in an export's route.
String exportFolderLabel(AppLocalizations l10n, LibraryAudioFolder folder) =>
    switch (folder) {
      LibraryAudioFolder.performances => l10n.libraryAudioPerformances,
      LibraryAudioFolder.sessions => l10n.librarySessions,
    };
