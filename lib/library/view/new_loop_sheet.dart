import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/library/application/eds_setup.dart';
import 'package:segno/library/cubit/library_cubit.dart';
import 'package:segno/library/cubit/new_loop_cubit.dart';
import 'package:segno/library/view/library_sessions_tab.dart';
import 'package:segno/looper/bloc/looper_bloc.dart';
import 'package:segno/looper/cubit/tracks_cubit.dart';
import 'package:segno/looper/view/loop_settings/loop_settings_widgets.dart';
import 'package:segno/session/session.dart';
import 'package:segno/theme/theme.dart';

/// What `Start new loop` was confirmed with: the template to apply, or none
/// for Empty tracks.
typedef NewLoopConfirmation = ({NewLoopTemplate? template});

/// Asks before `New loop` (plan D8: it always asks), then starts it through
/// [SessionCubit.newLoop] with the chosen start (#1513). `Cancel` changes
/// nothing.
Future<void> startNewLoop(BuildContext context) async {
  final session = context.read<SessionCubit>();
  final library = context.read<LibraryCubit>();
  final looper = context.read<LooperRepository>();
  final confirmed = await showDialog<NewLoopConfirmation>(
    context: context,
    barrierColor: context.surface.scrim,
    builder: (_) => BlocProvider(
      create: (_) => NewLoopCubit(
        loadEdsSetup: loadEdsSetup,
        fits: (template) => newLoopTemplateFits(looper, template),
      ),
      child: NewLoopSheet(
        currentName: session.state.currentSessionName,
        channels: [
          for (final track in context.read<LooperBloc>().state.tracks)
            if (track.hasContent) track.channel,
        ],
        trackNames: context.read<TracksCubit>().state.names,
      ),
    ),
  );
  if (confirmed == null) return;
  // A New loop ends Listen (plan D10).
  library.stopListening();
  await session.newLoop(template: confirmed.template);
}

/// The New loop sheet (pen 19/02 `New loop / Keep current session`, and
/// 19/07 `New loop / Ed's setup`): the current session stays in the
/// Library, its tracks give way to empty ones, and the effects, tempo and
/// pedal setup stay. `Start with` chooses Empty tracks or Ed's setup, which
/// also names tracks 1 to 4 and gives each an Ed's Rack sound. Pops a
/// [NewLoopConfirmation] on `Start new loop` and null on `Cancel`.
class NewLoopSheet extends StatelessWidget {
  /// Creates the sheet for the current session [currentName], whose tracks
  /// [channels] hold audio and whose tracks are named [trackNames].
  const NewLoopSheet({
    required this.currentName,
    required this.channels,
    required this.trackNames,
    super.key,
  });

  /// The current session's name, or null while it has none yet.
  final String? currentName;

  /// The current rig's channels (0-based) holding audio.
  final List<int> channels;

  /// The track names, by channel, which Ed's setup replaces on tracks 1 to 4.
  final List<String> trackNames;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    final body = TextStyle(color: surface.textSecondary, fontSize: 24);
    final state = context.watch<NewLoopCubit>().state;
    final eds = state.start == NewLoopStart.edsSetup;
    return Center(
      child: Material(
        type: MaterialType.transparency,
        child: Container(
          key: const Key('new_loop_sheet'),
          width: 850,
          padding: const EdgeInsets.all(41),
          decoration: BoxDecoration(
            color: surface.card,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: surface.borderStrong),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                height: 37,
                child: AppText(
                  l10n.libraryNewLoop,
                  style: TextStyle(color: surface.textPrimary, fontSize: 32),
                ),
              ),
              const SizedBox(height: 24),
              SizedBox(
                height: 36,
                child: NewLoopKeptLine(name: currentName, style: body),
              ),
              const SizedBox(height: 24),
              NewLoopStartPick(selected: state.start, style: body),
              const SizedBox(height: 24),
              SizedBox(
                height: 84,
                child: Row(
                  children: [
                    LibraryTrackStrip(
                      key: const Key('new_loop_before'),
                      channels: channels,
                      size: LibraryTrackStripSize.sheet,
                    ),
                    const Spacer(),
                    Icon(
                      LucideIcons.chevronRight,
                      size: 28,
                      color: surface.textSecondary,
                    ),
                    const Spacer(),
                    LibraryTrackStrip(
                      key: const Key('new_loop_after'),
                      channels: const [],
                      setUp: [
                        if (eds)
                          for (final track in edsSetup) track.channel,
                      ],
                      size: LibraryTrackStripSize.sheet,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              if (eds) ...[
                NewLoopEdsLine(status: state.eds, style: body),
                const SizedBox(height: 24),
                NewLoopNamesLine(trackNames: trackNames, style: body),
              ] else
                SizedBox(
                  height: 36,
                  child: AppText(
                    l10n.libraryNewLoopKeeps,
                    key: const Key('new_loop_summary'),
                    style: body,
                  ),
                ),
              const SizedBox(height: 24),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  LoopOutlinedButton(
                    key: const Key('new_loop_cancel'),
                    width: 125,
                    label: l10n.cancel,
                    onTap: () => Navigator.of(context).pop(),
                  ),
                  const SizedBox(width: 16),
                  Opacity(
                    // Waits for Ed's setup's sounds, and stays off when they
                    // cannot be used; drawn so.
                    opacity: state.canStart ? 1 : surface.disabledOpacity,
                    child: LoopOutlinedButton(
                      key: const Key('new_loop_start'),
                      width: 216,
                      tone: LoopButtonTone.accent,
                      label: l10n.libraryNewLoopStart,
                      onTap: state.canStart
                          ? () =>
                                Navigator.of(
                                  context,
                                ).pop<NewLoopConfirmation>(
                                  (template: state.chosenTemplate),
                                )
                          : null,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The sheet's `Start with` row: the label and the Empty tracks | Ed's setup
/// pick-one (19/07), [selected] chosen.
class NewLoopStartPick extends StatelessWidget {
  /// Creates the row with [selected] chosen, its label in [style].
  const NewLoopStartPick({
    required this.selected,
    required this.style,
    super.key,
  });

  /// The chosen start.
  final NewLoopStart selected;

  /// The label's style.
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return SizedBox(
      height: 64,
      child: Row(
        children: [
          Expanded(child: AppText(l10n.libraryNewLoopStartWith, style: style)),
          LoopChoiceRow<NewLoopStart>(
            values: NewLoopStart.values,
            labelOf: (start) => switch (start) {
              NewLoopStart.emptyTracks => l10n.libraryNewLoopEmptyTracks,
              NewLoopStart.edsSetup => l10n.libraryNewLoopEdsSetup,
            },
            keyOf: (start) => Key(switch (start) {
              NewLoopStart.emptyTracks => 'new_loop_template_empty',
              NewLoopStart.edsSetup => 'new_loop_template_eds',
            }),
            selected: selected,
            onSelected: (start) => context.read<NewLoopCubit>().choose(start),
            width: 456,
            height: 64,
            gap: 16,
          ),
        ],
      ),
    );
  }
}

/// What Ed's setup does, or why it cannot start yet: its sounds are loading,
/// one is missing, or they would go over the effects budget (#1513 D3).
class NewLoopEdsLine extends StatelessWidget {
  /// Creates the line for Ed's setup's [status] in [style].
  const NewLoopEdsLine({required this.status, required this.style, super.key});

  /// Where Ed's setup's sounds are.
  final EdsSetupStatus status;

  /// The line's style; a refusal takes the failure colour.
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final refused =
        status == EdsSetupStatus.missing || status == EdsSetupStatus.overBudget;
    return SizedBox(
      height: 80,
      child: Semantics(
        liveRegion: true,
        child: AppText(
          switch (status) {
            EdsSetupStatus.ready => l10n.libraryNewLoopEdsSummary,
            EdsSetupStatus.idle ||
            EdsSetupStatus.loading => l10n.libraryNewLoopEdsLoading,
            EdsSetupStatus.missing => l10n.libraryNewLoopEdsMissing,
            EdsSetupStatus.overBudget => l10n.libraryNewLoopEdsOverBudget,
          },
          key: const Key('new_loop_summary'),
          style: refused ? style.copyWith(color: context.surface.rec) : style,
          maxLines: 2,
        ),
      ),
    );
  }
}

/// Track names are global (#1513 Q3): says so, and names the custom names
/// on tracks 1 to 4 that Ed's setup replaces.
class NewLoopNamesLine extends StatelessWidget {
  /// Creates the line for the current [trackNames] in [style].
  const NewLoopNamesLine({
    required this.trackNames,
    required this.style,
    super.key,
  });

  /// The track names, by channel.
  final List<String> trackNames;

  /// The line's style.
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final replaced = [
      for (final track in edsSetup)
        if (track.channel < trackNames.length &&
            trackNames[track.channel] !=
                storedDefaultTrackName(track.channel) &&
            trackNames[track.channel] != track.name)
          trackNames[track.channel],
    ];
    final line = switch (replaced) {
      [] => l10n.libraryNewLoopNamesShared,
      [final name] =>
        '${l10n.libraryNewLoopNamesShared} '
            '${l10n.libraryNewLoopNameReplaced(name)}',
      [...final names, final last] =>
        '${l10n.libraryNewLoopNamesShared} '
            '${l10n.libraryNewLoopNamesReplaced(names.join(', '), last)}',
    };
    return AppText(line, key: const Key('new_loop_names'), style: style);
  }
}

/// "`name` stays in your Library.", the name drawn brighter as the pen
/// does, or "Your current loop stays in your Library." while the loop has
/// no name yet.
class NewLoopKeptLine extends StatelessWidget {
  /// Creates the line for the current session [name] in [style].
  const NewLoopKeptLine({required this.name, required this.style, super.key});

  /// The current session's name, or null while it has none.
  final String? name;

  /// The line's style; the name takes the primary text colour.
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final name = this.name;
    if (name == null) {
      return AppText(l10n.libraryNewLoopStaysUnnamed, style: style);
    }
    final line = l10n.libraryNewLoopStays(name);
    final at = line.indexOf(name);
    return Text.rich(
      TextSpan(
        style: style,
        children: [
          TextSpan(text: line.substring(0, at)),
          TextSpan(
            text: name,
            style: TextStyle(color: context.surface.textPrimary),
          ),
          TextSpan(text: line.substring(at + name.length)),
        ],
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }
}
