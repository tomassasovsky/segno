import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:segno/app/segno_navigator.dart';
import 'package:segno/common/console_surface.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/storage/view/storage_page.dart';
import 'package:segno/storage/view/storage_volume_card.dart';
import 'package:segno/system/cubit/console_facts_cubit.dart';

/// The Storage tab: the volumes and safe eject (pen 31, [StoragePage]), then
/// what is using Internal, and the housekeeping action.
///
/// The breakdown readouts are not a report — they are the argument for the
/// action, which is what keeps this from being the kind of tab that only
/// tells you things.
///
/// **Deleting captures asks first**, like every destructive action on this
/// console, and afterwards the cubit **re-reads rather than guessing** at
/// what is left. And when the build cannot read the disk at all, the whole
/// breakdown is replaced by a card that says so — zeroes drawn as facts would
/// be worse than saying nothing.
class StorageSystemTab extends StatefulWidget {
  /// Creates a [StorageSystemTab].
  const new({super.key});

  /// How old a capture has to be for the housekeeping action to take it.
  static const int retentionDays = 30;

  @override
  State<StorageSystemTab> createState() => _StorageSystemTabState();
}

class _StorageSystemTabState extends State<StorageSystemTab> {
  @override
  void initState() {
    super.initState();
    // Re-read on open: captures may have been written by the session since
    // the app started.
    unawaited(context.read<ConsoleFactsCubit>().load());
  }

  Future<void> _deleteCaptures() async {
    final l10n = context.l10n;
    final cubit = context.read<ConsoleFactsCubit>();
    final confirmed = await showConsoleConfirmDialog(
      context,
      title: l10n.storageDeleteCapturesTitle,
      body: l10n.storageDeleteCapturesConfirmBody(
        StorageSystemTab.retentionDays,
      ),
      confirmLabel: l10n.storageDeleteCapturesConfirm,
    );
    if (!confirmed) return;
    await cubit.deleteCapturesOlderThan(StorageSystemTab.retentionDays);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final state = context.watch<ConsoleFactsCubit>().state;
    final usage = state.storage;

    return KeyedSubtree(
      key: const Key('system_storage_tab'),
      child: ConsoleFace(
        previewKey: const Key('system_storage_upcoming'),
        lastGroupExtent:
            ConsolePinnedGroupLabel.extent +
            kConsoleRowHeight +
            ConsoleCard.borderExtent,
        groups: [
          ConsoleGroup(
            blocks: [
              StoragePage(onOpenLibrary: () => unawaited(openLibrary())),
            ],
          ),
          ConsoleGroup(
            caption: l10n.systemThisConsoleGroup,
            blocks: [
              // Nothing at all while the read is in flight. "This build can't
              // read the console's disk" is an ANSWER, and an answer that has
              // not arrived yet is not an answer of no.
              if (!state.hasStorage)
                if (state.settled)
                  ConsoleEmptyCard(
                    key: const Key('system_storage_unknown'),
                    message: l10n.storageUnknown,
                  )
                else
                  const SizedBox.shrink()
              else
                ConsoleCard(
                  key: const Key('system_storage_card'),
                  children: [
                    _UsageRow(
                      rowKey: const Key('system_storage_sessions'),
                      title: l10n.storageSessionsTitle,
                      bytes: usage.sessionBytes,
                    ),
                    _UsageRow(
                      rowKey: const Key('system_storage_captures'),
                      title: l10n.storageCapturesTitle,
                      subtitle: l10n.storageCapturesSubtitle,
                      bytes: usage.captureBytes,
                    ),
                    _UsageRow(
                      rowKey: const Key('system_storage_plugins'),
                      title: l10n.storagePluginsTitle,
                      subtitle: l10n.storagePluginsSubtitle(usage.pluginCount),
                      bytes: usage.pluginBytes,
                    ),
                    // No Free row: the Internal card above carries free
                    // space, read every few seconds; a second figure from a
                    // read made once on open would disagree with it.
                    _UsageRow(
                      rowKey: const Key('system_storage_system'),
                      title: l10n.storageSystemTitle,
                      subtitle: l10n.storageSystemSubtitle,
                      bytes: usage.systemBytes,
                      showDivider: false,
                    ),
                  ],
                ),
            ],
          ),
          ConsoleGroup(
            caption: l10n.systemHousekeepingGroup,
            blocks: [
              ConsoleCard(
                children: [
                  // The failure sits at the top of the list the action lives
                  // in, in the console's own idiom — never a toast, and never
                  // by taking the disk figures off the screen.
                  if (state.actionFailed)
                    ConsoleBanner(
                      key: const Key('system_storage_action_failed'),
                      message: l10n.storageActionFailed,
                      // Nothing on the disk changed: a warning (#1562).
                      tone: ConsoleBannerTone.warning,
                    ),
                  ConsoleRow(
                    key: const Key('system_storage_delete_captures'),
                    title: l10n.storageDeleteCapturesTitle,
                    subtitle: l10n.storageDeleteCapturesSubtitle(
                      StorageSystemTab.retentionDays,
                    ),
                    expanded: false,
                    showDivider: false,
                    onTap: state.hasStorage && !state.busy
                        ? () => unawaited(_deleteCaptures())
                        : null,
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// One line of the breakdown: what it is, and how much of the disk it is.
///
/// The figure goes in [ConsoleRow.value] rather than `state`: `41.6 GB` is a
/// quantity a person reads, not a machine word about the row.
class _UsageRow extends StatelessWidget {
  const new({
    required this.rowKey,
    required this.title,
    required this.bytes,
    this.subtitle,
    this.showDivider = true,
  });

  /// The row's own key, which tests find it by.
  final Key rowKey;

  final String title;
  final String? subtitle;

  /// How much of the disk it takes.
  final int bytes;

  /// Whether to paint the hairline below; false on the card's last row.
  final bool showDivider;

  @override
  Widget build(BuildContext context) => ConsoleRow(
    key: rowKey,
    title: title,
    subtitle: subtitle,
    value: context.l10n.storageGigabytes(decimalGigabytes(bytes)),
    showDisclosure: false,
    showDivider: showDivider,
  );
}
