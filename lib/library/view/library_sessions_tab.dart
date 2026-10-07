import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:intl/intl.dart';
import 'package:looper_repository/looper_repository.dart' show kMaxTracks;
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:segno/common/console_rename_sheet.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/library/application/removable_volumes.dart';
import 'package:segno/library/cubit/library_cubit.dart';
import 'package:segno/library/view/library_manage.dart';
import 'package:segno/library/view/library_preview_card.dart';
import 'package:segno/looper/view/loop_settings/loop_settings_widgets.dart';
import 'package:segno/session/session.dart';
import 'package:segno/theme/theme.dart';
import 'package:session_repository/session_repository.dart';

/// The Sessions tab (pen 19/01 `session-library-layout`): the 709-wide
/// session list beside the preview card.
class LibrarySessionsTab extends StatelessWidget {
  /// Creates the Sessions tab.
  const LibrarySessionsTab({super.key});

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
          width: 709,
          child: switch (location) {
            LibraryLocation.internal => const LibrarySessionList(),
            // Backups on a drive are listed in Part 8; until then a mounted
            // drive shows an empty list rather than a fake one.
            LibraryLocation.usb when readable => const SizedBox.shrink(),
            LibraryLocation.usb when unusable != null => LibraryUnusableUsb(
              volume: unusable,
            ),
            LibraryLocation.usb => const LibraryConnectUsb(),
          },
        ),
        // The pen puts the card at x 765, 1028 wide, one pixel past its own
        // 1792 layout; this keeps the x and stays inside.
        const SizedBox(width: 56),
        const Expanded(child: LibraryPreviewCard()),
      ],
    );
  }
}

/// The internal session list: search, folder chips and the rows.
class LibrarySessionList extends StatelessWidget {
  /// Creates the internal session list.
  const LibrarySessionList({super.key});

  @override
  Widget build(BuildContext context) => const Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(
        children: [
          LibrarySearchField(),
          SizedBox(width: 9),
          LibraryNewFolderButton(),
        ],
      ),
      SizedBox(height: 84, child: LibraryFolderChips()),
      Expanded(child: LibrarySessionRows()),
    ],
  );
}

/// `New folder`, beside the search: names a folder on the keyboard sheet
/// and creates it.
class LibraryNewFolderButton extends StatelessWidget {
  /// Creates the New folder button.
  const LibraryNewFolderButton({super.key});

  @override
  Widget build(BuildContext context) {
    final busy = context.select<SessionCubit, bool>(
      (c) => c.state.status == SessionStatus.working,
    );
    return LoopOutlinedButton(
      key: const Key('library_new_folder'),
      width: 144,
      fontSize: 22,
      label: context.l10n.libraryNewFolder,
      onTap: busy ? null : () => unawaited(promptNewFolder(context)),
    );
  }
}

/// The `Search sessions` field. The console has no keys, so a tap opens the
/// on-screen keyboard sheet; an empty answer clears the search.
class LibrarySearchField extends StatelessWidget {
  /// Creates the search field.
  const LibrarySearchField({super.key});

  Future<void> _edit(BuildContext context, String query) async {
    final cubit = context.read<LibraryCubit>();
    final l10n = context.l10n;
    final answer = await showConsoleRenameSheet(
      context,
      title: l10n.librarySearchSessions,
      subtitle: l10n.librarySearchSessions,
      current: query,
      fieldLabel: l10n.librarySearchSessions,
      allowEmpty: true,
    );
    if (answer != null) cubit.search(answer.trim());
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final query = context.select<LibraryCubit, String>((c) => c.state.query);
    return LibrarySearchBox(
      key: const Key('library_search'),
      text: query.isEmpty ? l10n.librarySearchSessions : query,
      placeholder: query.isEmpty,
      semanticLabel: l10n.librarySearchSessions,
      onTap: () => unawaited(_edit(context, query)),
    );
  }
}

/// The pen's 556 x 64 search box: an outlined box with the query or the
/// placeholder, which opens a keyboard sheet instead of taking keys.
class LibrarySearchBox extends StatelessWidget {
  /// Creates the search box.
  const LibrarySearchBox({
    required this.text,
    required this.placeholder,
    required this.semanticLabel,
    required this.onTap,
    super.key,
  });

  /// What the box shows: the query, or the placeholder.
  final String text;

  /// Whether [text] is the placeholder. It is drawn like a query, as the
  /// pen draws it, and announced as the field's name only.
  final bool placeholder;

  /// The field's accessible name.
  final String semanticLabel;

  /// Opens the keyboard.
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return Semantics(
      textField: true,
      label: semanticLabel,
      value: placeholder ? null : text,
      child: LoopFocusable(
        radius: 7,
        onActivate: onTap,
        child: Material(
          color: Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(7),
            side: BorderSide(color: surface.borderStrong),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            canRequestFocus: false,
            onTap: onTap,
            child: SizedBox(
              width: 556,
              height: 64,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 19),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: AppText(
                    text,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: surface.textPrimary,
                      fontSize: 22,
                      height: 1,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The folder chips: `All`, `Unfiled`, then each folder.
class LibraryFolderChips extends StatelessWidget {
  /// Creates the folder chips.
  const LibraryFolderChips({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final cubit = context.read<LibraryCubit>();
    final filter = context.select<LibraryCubit, LibraryFolderFilter>(
      (c) => c.state.folderFilter,
    );
    final folders = context.select<SessionCubit, List<String>>(
      (c) => c.state.folders,
    );
    final chips = <(Key, String, LibraryFolderFilter)>[
      (
        const Key('library_folder_all'),
        l10n.libraryFolderAll,
        const AllSessions(),
      ),
      (
        const Key('library_folder_unfiled'),
        l10n.libraryFolderUnfiled,
        const UnfiledSessions(),
      ),
      for (final folder in folders)
        (Key('library_folder_$folder'), folder, FolderSessions(folder)),
    ];
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(vertical: 14),
      child: Row(
        children: [
          for (final (i, (key, label, value)) in chips.indexed) ...[
            if (i > 0) const SizedBox(width: 7),
            LibraryChip(
              key: key,
              label: label,
              selected: value == filter,
              onTap: () => cubit.filterFolder(value),
              onLongPress: switch (value) {
                FolderSessions(:final folder) => () => unawaited(
                  showFolderManage(context, folder),
                ),
                _ => null,
              },
            ),
          ],
        ],
      ),
    );
  }
}

/// One folder chip: 56 tall, as wide as its label, filled when selected.
class LibraryChip extends StatelessWidget {
  /// Creates a [LibraryChip].
  const LibraryChip({
    required this.label,
    required this.selected,
    required this.onTap,
    this.onLongPress,
    super.key,
  });

  /// The folder's name.
  final String label;

  /// Whether this chip is the filter.
  final bool selected;

  /// Makes this chip the filter.
  final VoidCallback onTap;

  /// Opens the folder's options; null for `All` and `Unfiled`.
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      child: LoopFocusable(
        radius: 7,
        onActivate: onTap,
        child: Material(
          color: selected ? surface.accentSurface : Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(7),
            side: BorderSide(
              color: selected ? surface.accent : surface.borderStrong,
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            canRequestFocus: false,
            onTap: onTap,
            onLongPress: onLongPress,
            child: SizedBox(
              height: 56,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 21),
                child: Center(
                  widthFactor: 1,
                  child: AppText(
                    label,
                    style: TextStyle(
                      color: surface.textPrimary,
                      fontSize: 21,
                      height: 1,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The session rows that pass the search and the folder chip, newest save
/// first, or a line saying why there are none.
class LibrarySessionRows extends StatelessWidget {
  /// Creates the session rows.
  const LibrarySessionRows({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final library = context.select<LibraryCubit, LibraryState>(
      (c) => c.state.withoutListen,
    );
    final session = context.watch<SessionCubit>().state;
    final rows = library.filter(session.sessions);
    if (rows.isEmpty) {
      return Padding(
        padding: const EdgeInsets.only(top: 36),
        child: AppText(
          session.sessions.isEmpty
              ? l10n.libraryNoSessions
              : l10n.libraryNoMatches,
          key: const Key('library_rows_empty'),
          style: TextStyle(
            color: context.surface.textSecondary,
            fontSize: 22,
            height: 1,
          ),
        ),
      );
    }
    final cubit = context.read<LibraryCubit>();
    return ListView.builder(
      key: const Key('library_rows'),
      padding: const EdgeInsets.only(top: 12, right: 10),
      itemExtent: 148,
      itemCount: rows.length,
      itemBuilder: (context, i) {
        final summary = rows[i];
        return LibrarySessionRow(
          key: Key('library_row_${summary.id}'),
          summary: summary,
          current: summary.id == session.currentSessionId,
          selected: summary.id == library.selectedId,
          onTap: () => unawaited(cubit.select(summary.id)),
        );
      },
    );
  }
}

/// One saved session's 148-tall row: its name, a meta line (`Current
/// session`, or the saved date and track count) and the eight-slot track
/// strip. A tap selects it for the preview; it never opens it.
class LibrarySessionRow extends StatelessWidget {
  /// Creates a [LibrarySessionRow].
  const LibrarySessionRow({
    required this.summary,
    required this.current,
    required this.selected,
    required this.onTap,
    super.key,
  });

  /// The catalog entry.
  final SessionSummary summary;

  /// Whether it is the session open on the stage.
  final bool current;

  /// Whether it is the one the preview shows.
  final bool selected;

  /// Selects it.
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final l10n = context.l10n;
    final tracks = l10n.libraryTrackCount(summary.trackCount);
    final date = savedDateLabel(context, summary.modifiedAt);
    final meta = current
        ? l10n.libraryCurrentSession
        : date.isEmpty
        ? tracks
        : l10n.librarySessionMeta(date, tracks);
    return Semantics(
      button: true,
      selected: selected,
      label: summary.name,
      value: meta,
      child: LoopFocusable(
        onActivate: onTap,
        child: Material(
          color: selected ? surface.accentSurface : Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
            side: BorderSide(
              color: selected ? surface.accent : Colors.transparent,
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            canRequestFocus: false,
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(25, 25, 25, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    height: 34,
                    child: AppText(
                      summary.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: surface.textPrimary,
                        fontSize: 28,
                        height: 1.2,
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    height: 23,
                    child: AppText(
                      meta,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: surface.textSecondary,
                        fontSize: 20,
                        height: 1.15,
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  LibraryTrackStrip(channels: summary.populatedChannels),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Where a [LibraryTrackStrip] is drawn, which sets its size.
enum LibraryTrackStripSize {
  /// A session row's strip (19/01): 340 x 13.
  row(width: 340, height: 13, slotWidth: 37),

  /// The New loop sheet's before and after strips (19/02): 346 x 36.
  sheet(width: 346, height: 36, slotWidth: 38);

  const LibraryTrackStripSize({
    required this.width,
    required this.height,
    required this.slotWidth,
  });

  /// The strip's width.
  final double width;

  /// The strip's and each slot's height.
  final double height;

  /// Each slot's width.
  final double slotWidth;
}

/// The eight-slot track strip: one slot per track, filled where the
/// session holds recorded audio.
class LibraryTrackStrip extends StatelessWidget {
  /// Creates a track strip for the populated [channels].
  const LibraryTrackStrip({
    required this.channels,
    this.size = LibraryTrackStripSize.row,
    super.key,
  });

  /// The channels (0-based) holding audio.
  final List<int> channels;

  /// Where the strip is drawn.
  final LibraryTrackStripSize size;

  static const int _slots = kMaxTracks;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return ExcludeSemantics(
      child: SizedBox(
        width: size.width,
        height: size.height,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            for (var channel = 0; channel < _slots; channel++)
              DecoratedBox(
                key: Key(
                  'library_strip_${channel}_'
                  '${channels.contains(channel) ? 'filled' : 'empty'}',
                ),
                decoration: BoxDecoration(
                  color: channels.contains(channel)
                      ? surface.accent
                      : surface.control,
                  borderRadius: BorderRadius.circular(3),
                  border: Border.all(
                    color: channels.contains(channel)
                        ? surface.accent
                        : surface.borderStrong,
                  ),
                ),
                child: SizedBox(width: size.slotWidth, height: size.height),
              ),
          ],
        ),
      ),
    );
  }
}

/// The pen's saved-date label: `today 14:02`, `yesterday`, then `7 Sep`;
/// empty when the date is unknown. [now] is the clock (the wall clock when
/// omitted).
String savedDateLabel(BuildContext context, DateTime? at, {DateTime? now}) {
  if (at == null) return '';
  final l10n = context.l10n;
  final clock = now ?? DateTime.now();
  final today = DateTime(clock.year, clock.month, clock.day);
  final day = DateTime(at.year, at.month, at.day);
  if (day == today) {
    final hh = at.hour.toString().padLeft(2, '0');
    final mm = at.minute.toString().padLeft(2, '0');
    return l10n.sessionDateToday('$hh:$mm');
  }
  if (day == today.subtract(const Duration(days: 1))) {
    return l10n.sessionDateYesterday;
  }
  return DateFormat(
    'd MMM',
    Localizations.localeOf(context).toString(),
  ).format(at);
}

/// The USB location without a drive (pen 18/06, worded for sessions):
/// nothing on a drive can be shown, and the internal sessions are still a
/// tap away.
class LibraryConnectUsb extends StatelessWidget {
  /// Creates the no-drive notice.
  const LibraryConnectUsb({super.key});

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final l10n = context.l10n;
    return Padding(
      key: const Key('library_connect_usb'),
      padding: const EdgeInsets.only(top: 92),
      child: Column(
        children: [
          Icon(LucideIcons.usb, size: 68, color: surface.textSecondary),
          const SizedBox(height: 20),
          AppText(
            l10n.libraryConnectUsb,
            style: TextStyle(
              color: surface.textPrimary,
              fontSize: 32,
              height: 1.15,
            ),
          ),
          const SizedBox(height: 20),
          AppText(
            l10n.libraryConnectUsbBody,
            style: TextStyle(
              color: surface.textSecondary,
              fontSize: 23,
              height: 1.4,
            ),
          ),
        ],
      ),
    );
  }
}

/// The USB location with a drive that is there but cannot be read: an
/// unsupported filesystem or a failed mount (#1177's states), worded as the
/// storage service words it.
class LibraryUnusableUsb extends StatelessWidget {
  /// Creates the notice for [volume].
  const LibraryUnusableUsb({required this.volume, super.key});

  /// The drive that cannot be read.
  final RemovableVolume volume;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final l10n = context.l10n;
    return Padding(
      key: const Key('library_unusable_usb'),
      padding: const EdgeInsets.only(top: 92),
      child: Column(
        children: [
          Icon(LucideIcons.usb, size: 68, color: surface.textSecondary),
          const SizedBox(height: 20),
          AppText(
            l10n.libraryUsbUnusable,
            style: TextStyle(
              color: surface.textPrimary,
              fontSize: 32,
              height: 1.15,
            ),
          ),
          const SizedBox(height: 20),
          AppText(
            volume.status == RemovableVolumeStatus.unsupported
                ? l10n.libraryUsbUnsupported(volume.fsType)
                : l10n.libraryUsbMountFailed,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: surface.textSecondary,
              fontSize: 23,
              height: 1.4,
            ),
          ),
        ],
      ),
    );
  }
}
