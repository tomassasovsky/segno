import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/library/view/library_sessions_tab.dart';
import 'package:segno/looper/bloc/looper_bloc.dart';
import 'package:segno/looper/view/loop_settings/loop_settings_widgets.dart';
import 'package:segno/session/session.dart';
import 'package:segno/theme/theme.dart';

/// Asks before `New loop` (plan D8: it always asks), then starts it through
/// [SessionCubit.newLoop]. `Cancel` changes nothing.
Future<void> startNewLoop(BuildContext context) async {
  final session = context.read<SessionCubit>();
  final confirmed = await showDialog<bool>(
    context: context,
    barrierColor: context.surface.scrim,
    builder: (_) => NewLoopSheet(
      currentName: session.state.currentSessionName,
      channels: [
        for (final track in context.read<LooperBloc>().state.tracks)
          if (track.hasContent) track.channel,
      ],
    ),
  );
  if (confirmed ?? false) await session.newLoop();
}

/// The New loop sheet (pen 19/02 `New loop / Keep current session`): the
/// current session stays in the Library, its tracks give way to empty ones,
/// and the effects, tempo and pedal setup stay. Pops true on
/// `Start new loop` and false on `Cancel`.
class NewLoopSheet extends StatelessWidget {
  /// Creates the sheet for the current session [currentName], whose tracks
  /// [channels] hold audio.
  const NewLoopSheet({
    required this.currentName,
    required this.channels,
    super.key,
  });

  /// The current session's name, or null while it has none yet.
  final String? currentName;

  /// The current rig's channels (0-based) holding audio.
  final List<int> channels;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    final body = TextStyle(color: surface.textSecondary, fontSize: 24);
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
                    const LibraryTrackStrip(
                      key: Key('new_loop_after'),
                      channels: [],
                      size: LibraryTrackStripSize.sheet,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              SizedBox(
                height: 36,
                child: AppText(l10n.libraryNewLoopKeeps, style: body),
              ),
              const SizedBox(height: 24),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  LoopOutlinedButton(
                    key: const Key('new_loop_cancel'),
                    width: 125,
                    label: l10n.cancel,
                    onTap: () => Navigator.of(context).pop(false),
                  ),
                  const SizedBox(width: 16),
                  LoopOutlinedButton(
                    key: const Key('new_loop_start'),
                    width: 216,
                    tone: LoopButtonTone.accent,
                    label: l10n.libraryNewLoopStart,
                    onTap: () => Navigator.of(context).pop(true),
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
