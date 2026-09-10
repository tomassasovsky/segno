import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:routing_graph/routing_graph.dart' show FocusableTapTarget;
import 'package:segno/common/pen_icons.dart';
import 'package:segno/control/control.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/bloc/looper_bloc.dart';
import 'package:segno/looper/cubit/settings_tray_cubit.dart';
import 'package:segno/looper/cubit/tracks_cubit.dart';
import 'package:segno/performance/performance.dart';
import 'package:segno/session/session.dart';
import 'package:segno/theme/theme.dart';

/// The stage's top bar (the accepted design): Library at the leading edge, the
/// session name centred, and at the trailing edge the bank, the view menu and
/// Settings. Track, Wave and (later) Mixer are choices behind the view icon,
/// not tabs in the track area; the bank indicator also changes bank.
///
/// Each element subscribes to its own slice, so a session rename rebuilds the
/// name and a bank change the bank button.
class StageTopBar extends StatelessWidget {
  /// Creates a [StageTopBar].
  const StageTopBar({super.key});

  /// The bar's height — the pen's 96.
  static const double height = 96;

  /// The bar's inset from the screen edges — the pen's 60.
  static const double sideInset = 60;

  /// The gap between the trailing buttons — the pen's 24.
  static const double _gap = 24;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final l10n = context.l10n;
    return Container(
      key: const Key('stage_top_bar'),
      height: height,
      padding: const EdgeInsets.symmetric(horizontal: sideInset),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: surface.line)),
      ),
      child: Row(
        children: [
          _StageIconButton(
            key: const Key('stage_library'),
            semanticLabel: l10n.stageLibrary,
            onTap: () => unawaited(showSessionsManager(context)),
            child: PenIconView(
              icon: PenIcon.library,
              size: 28,
              color: surface.textPrimary,
            ),
          ),
          const SizedBox(width: _gap),
          const _RecordLight(),
          const Expanded(child: _SessionName()),
          const _ResetMixerButton(),
          const _BankButton(),
          const SizedBox(width: _gap),
          const _ViewButton(),
          const SizedBox(width: _gap),
          _StageIconButton(
            key: const Key('stage_settings'),
            semanticLabel: l10n.stageSettings,
            bordered: true,
            onTap: () => context.read<SettingsTrayCubit>().open(),
            child: Icon(
              LucideIcons.settings,
              size: 28,
              color: surface.textPrimary,
            ),
          ),
        ],
      ),
    );
  }
}

/// A 60×60 icon target, bordered like the pen's trailing buttons or bare like
/// its Library mark.
class _StageIconButton extends StatelessWidget {
  const _StageIconButton({
    required this.semanticLabel,
    required this.onTap,
    required this.child,
    this.bordered = false,
    super.key,
  });

  final String semanticLabel;
  final VoidCallback onTap;
  final Widget child;
  final bool bordered;

  static const double size = 60;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return FocusableTapTarget(
      semanticLabel: semanticLabel,
      borderRadius: 10,
      onTap: onTap,
      child: Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          border: bordered ? Border.all(color: surface.line) : null,
        ),
        child: child,
      ),
    );
  }
}

/// The open session's name, centred — a readout; Library is the way to the
/// sessions. `Unsaved`, in italic, while no session is open.
class _SessionName extends StatelessWidget {
  const _SessionName();

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final l10n = context.l10n;
    final name = context.select<SessionCubit, String?>(
      (cubit) => cubit.state.currentSessionName,
    );
    return AppText(
      name ?? l10n.sessionUnsaved,
      key: const Key('stage_session_name'),
      textAlign: TextAlign.center,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontFamily: SurfaceTheme.displayFont,
        color: surface.textPrimary,
        fontSize: 30,
        fontStyle: name == null ? FontStyle.italic : FontStyle.normal,
        height: 1,
      ),
    );
  }
}

/// Reset mixer, drawn only while the Mixer is showing.
///
/// Every track's level back to unity and every pan to centre. Mute, Solo,
/// effects and the audio itself are untouched — the accepted design is
/// explicit that this is a mix reset, not a session one.
///
/// Only in the Mixer view, because that is where the pen puts it and because
/// an action that changes eight values at once wants to be beside them.
class _ResetMixerButton extends StatelessWidget {
  const _ResetMixerButton();

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final l10n = context.l10n;
    final showing = context.select<TracksCubit, bool>(
      (cubit) => cubit.state.stageView == StageView.mixer,
    );
    if (!showing) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(right: StageTopBar._gap),
      child: _StageIconButton(
        key: const Key('stage_reset_mixer'),
        semanticLabel: l10n.a11yMixerReset,
        onTap: () => context.read<LooperBloc>().add(const LooperMixerReset()),
        child: Icon(
          LucideIcons.rotateCcw,
          size: 28,
          color: surface.textPrimary,
        ),
      ),
    );
  }
}

/// The bank button: the visible bank's letter; a tap reveals the other bank's
/// four tracks without moving the selection or touching playback.
class _BankButton extends StatelessWidget {
  const _BankButton();

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final l10n = context.l10n;
    final active = context.select<ControlCubit, int>(
      (cubit) => cubit.state.activeBank,
    );
    final letter = String.fromCharCode(0x41 + active);
    final first = active * ControlState.tracksPerBank + 1;
    return _StageIconButton(
      key: const Key('stage_bank_button'),
      semanticLabel: l10n.a11yStageBankButton(
        letter,
        first,
        first + ControlState.tracksPerBank - 1,
      ),
      bordered: true,
      onTap: () => context.read<ControlCubit>().browseBank(
        (active + 1) % ControlState.bankCount,
      ),
      child: AppText(
        letter,
        key: const Key('stage_bank_letter'),
        style: TextStyle(
          fontFamily: SurfaceTheme.displayFont,
          color: surface.textPrimary,
          fontSize: 30,
          height: 1,
        ),
      ),
    );
  }
}

/// The view button: opens the Track / Wave menu below itself. A radio menu
/// (`menuitemradio` in the prototype): the current view is checked.
class _ViewButton extends StatelessWidget {
  const _ViewButton();

  Future<void> _showMenu(BuildContext context) async {
    final button = context.findRenderObject()! as RenderBox;
    final overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    final origin = button.localToGlobal(Offset.zero, ancestor: overlay);
    final current = context.read<TracksCubit>().state.stageView;
    final l10n = context.l10n;
    final surface = context.surface;
    final choice = await showMenu<StageView>(
      context: context,
      position: RelativeRect.fromLTRB(
        origin.dx,
        origin.dy + button.size.height + 8,
        overlay.size.width - origin.dx - button.size.width,
        0,
      ),
      color: surface.card,
      items: [
        for (final view in StageView.values)
          PopupMenuItem<StageView>(
            key: Key('stage_view_${view.name}'),
            value: view,
            child: Semantics(
              inMutuallyExclusiveGroup: true,
              checked: view == current,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  AppText(
                    switch (view) {
                      StageView.track => l10n.stageViewTrack,
                      StageView.wave => l10n.stageViewWave,
                      StageView.mixer => l10n.stageViewMixer,
                    },
                    style: TextStyle(
                      fontFamily: SurfaceTheme.displayFont,
                      color: surface.textPrimary,
                      fontSize: 24,
                    ),
                  ),
                  if (view == current) ...[
                    const SizedBox(width: 16),
                    Icon(LucideIcons.check, size: 22, color: surface.accent),
                  ],
                ],
              ),
            ),
          ),
      ],
    );
    if (choice != null && context.mounted) {
      context.read<TracksCubit>().showView(choice);
    }
  }

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return _StageIconButton(
      key: const Key('stage_view_menu'),
      semanticLabel: context.l10n.stageViewMenu,
      bordered: true,
      onTap: () => unawaited(_showMenu(context)),
      child: PenIconView(
        icon: PenIcon.views,
        size: 28,
        color: surface.textPrimary,
      ),
    );
  }
}

/// The performance-record light: a circle holding a red dot at rest, and —
/// per `c/stage-armed` — a red stop square with the elapsed readout beside it
/// while a capture runs. A state light, not a button: the MODE footswitch
/// long-press owns arm/disarm on the console, and the recording indicator
/// persists on the stage while a capture runs.
class _RecordLight extends StatelessWidget {
  const _RecordLight();

  static String _format(Duration elapsed) {
    final minutes = elapsed.inMinutes.toString().padLeft(2, '0');
    final seconds = (elapsed.inSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final l10n = context.l10n;
    final state = context.watch<PerformanceRecorderCubit>().state;
    final armed = state is PerformanceRecorderArmed ? state : null;
    final elapsed = armed == null ? null : _format(armed.elapsed);
    return Semantics(
      label: elapsed == null
          ? l10n.a11yStageRecordIdle
          : l10n.perfArmedElapsed(elapsed),
      child: ExcludeSemantics(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              key: const Key('stage_record_light'),
              width: 36,
              height: 36,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: armed != null ? surface.recSurface : null,
                border: Border.all(
                  color: armed != null ? surface.rec : surface.borderStrong,
                ),
              ),
              child: armed != null
                  ? Container(width: 12, height: 12, color: surface.rec)
                  : DecoratedBox(
                      decoration: BoxDecoration(
                        color: surface.rec,
                        shape: BoxShape.circle,
                      ),
                      child: const SizedBox.square(dimension: 14),
                    ),
            ),
            if (elapsed != null) ...[
              const SizedBox(width: 12),
              AppText(
                elapsed,
                key: const Key('stage_record_elapsed'),
                style: TextStyle(
                  color: surface.rec,
                  fontFamily: SurfaceTheme.monoFont,
                  fontSize: 16,
                  height: 1.15,
                  leadingDistribution: TextLeadingDistribution.even,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
