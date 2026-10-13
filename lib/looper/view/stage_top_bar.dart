import 'dart:async';
import 'dart:math' as math;

import 'package:cpu_load_repository/cpu_load_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:routing_graph/routing_graph.dart' show FocusableTapTarget;
import 'package:segno/app/segno_navigator.dart';
import 'package:segno/common/pen_icons.dart';
import 'package:segno/control/control.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/bloc/looper_bloc.dart';
import 'package:segno/looper/cubit/cpu_load_cubit.dart';
import 'package:segno/looper/cubit/tracks_cubit.dart';
import 'package:segno/looper/model/interaction_mode.dart';
import 'package:segno/looper/view/backing_click_dialog.dart';
import 'package:segno/looper/view/loop_settings/loop_select.dart';
import 'package:segno/looper/view/loop_settings/loop_settings_widgets.dart';
import 'package:segno/performance/performance.dart';
import 'package:segno/session/session.dart';
import 'package:segno/theme/theme.dart';

/// The stage's top bar (the accepted design): Library, the record light and
/// the CPU load at the leading edge, the session name centred on the whole
/// bar, and at the trailing edge the bank, the view menu, the Tuner and
/// Settings. Track, Wave and Mixer are choices behind the view icon, not tabs
/// in the track area; the bank indicator also changes bank.
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
      child: CustomMultiChildLayout(
        delegate: _CentredTitleLayout(gap: _gap),
        children: [
          LayoutId(
            id: _BarSlot.leading,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _StageIconButton(
                  key: const Key('stage_library'),
                  semanticLabel: l10n.stageLibrary,
                  onTap: () => unawaited(openLibrary()),
                  child: PenIconView(
                    icon: PenIcon.library,
                    size: 28,
                    color: surface.textPrimary,
                  ),
                ),
                const SizedBox(width: _gap),
                const _RecordLight(),
                const _CpuLoad(),
              ],
            ),
          ),
          LayoutId(id: _BarSlot.title, child: const _SessionName()),
          LayoutId(
            id: _BarSlot.trailing,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const _BackingClickButton(),
                const _ResetMixerButton(),
                const _BankButton(),
                const SizedBox(width: _gap),
                const _ViewButton(),
                const SizedBox(width: _gap),
                // The Tuner by touch; feet reach it through MODE or an
                // assignment.
                _StageIconButton(
                  key: const Key('stage_tuner'),
                  semanticLabel: l10n.actionModeTuner,
                  bordered: true,
                  onTap: () => context.read<ControlCubit>().setMode(
                    InteractionMode.tuner,
                  ),
                  child: Icon(
                    LucideIcons.guitar,
                    size: 28,
                    color: surface.textPrimary,
                  ),
                ),
                const SizedBox(width: _gap),
                _StageIconButton(
                  key: const Key('stage_settings'),
                  semanticLabel: l10n.stageSettings,
                  bordered: true,
                  onTap: () => unawaited(openSegnoSettings()),
                  child: Icon(
                    LucideIcons.settings,
                    size: 28,
                    color: surface.textPrimary,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The bar's three slots.
enum _BarSlot { leading, title, trailing }

/// Lays the bar out with the title centred on the WHOLE bar, not on the room
/// between the side groups (#1308).
///
/// The side groups sit at their own widths at either edge. The title is
/// centred on the bar and may be at most twice the distance from the centre
/// to the nearer group, less [gap], so it stays centred whatever the groups'
/// widths and is ellipsized rather than run under either of them. Only when
/// a group reaches so near the centre that less than
/// [minCentredWidth] is left does the title fall back to the room between
/// the groups.
///
/// Flutter's `NavigationToolbar` was the obvious candidate and does not fit:
/// a long middle slides off centre towards the roomier side there.
class _CentredTitleLayout extends MultiChildLayoutDelegate {
  _CentredTitleLayout({required this.gap});

  final double gap;

  /// The narrowest centred room the title is still drawn in; below it the
  /// title falls back to the room between the groups.
  static const double minCentredWidth = 120;

  @override
  void performLayout(Size size) {
    final loose = BoxConstraints.loose(size);
    final leading = layoutChild(_BarSlot.leading, loose);
    final trailing = layoutChild(
      _BarSlot.trailing,
      loose.copyWith(maxWidth: math.max(0, size.width - leading.width)),
    );
    positionChild(
      _BarSlot.leading,
      Offset(0, (size.height - leading.height) / 2),
    );
    positionChild(
      _BarSlot.trailing,
      Offset(size.width - trailing.width, (size.height - trailing.height) / 2),
    );
    final centre = size.width / 2;
    final centredRoom =
        2 * (math.min(centre - leading.width, centre - trailing.width) - gap);
    if (centredRoom >= minCentredWidth) {
      final title = layoutChild(
        _BarSlot.title,
        BoxConstraints(maxWidth: centredRoom, maxHeight: size.height),
      );
      positionChild(
        _BarSlot.title,
        Offset(centre - title.width / 2, (size.height - title.height) / 2),
      );
      return;
    }
    // A side group reaches (nearly) to the centre — the Mixer's extra
    // buttons on the 1024-wide appliance — so no centred room is left: the
    // title takes the room between the groups instead of vanishing.
    final start = leading.width + gap;
    final room = math.max(0, size.width - trailing.width - gap - start);
    final title = layoutChild(
      _BarSlot.title,
      BoxConstraints(maxWidth: room.toDouble(), maxHeight: size.height),
    );
    positionChild(
      _BarSlot.title,
      Offset(
        start + (room - title.width) / 2,
        (size.height - title.height) / 2,
      ),
    );
  }

  @override
  bool shouldRelayout(_CentredTitleLayout oldDelegate) =>
      oldDelegate.gap != gap;
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

/// The pen's `stage-aux` button (25 `bZDIR`): opens the Backing & click
/// volume and pan dialog. Mixer view only, beside Reset mixer.
class _BackingClickButton extends StatelessWidget {
  const _BackingClickButton();

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final showing = context.select<TracksCubit, bool>(
      (cubit) => cubit.state.stageView == StageView.mixer,
    );
    if (!showing) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(right: StageTopBar._gap),
      child: LoopOutlinedButton(
        key: const Key('stage_backing_click'),
        width: 173,
        height: 54,
        fontSize: 20,
        radius: 8,
        tone: LoopButtonTone.raised,
        label: l10n.mixerBackingClick,
        semanticLabel: l10n.a11yMixerBackingClick,
        onTap: () => unawaited(showBackingClickDialog(context)),
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

  Future<void> _confirmReset(BuildContext context) async {
    final l10n = context.l10n;
    final surface = context.surface;
    final repository = context.read<LooperRepository>();
    final generation = repository.mixGeneration;
    final confirmed = await showDialog<bool>(
      context: context,
      barrierColor: surface.scrim,
      builder: (dialogContext) => AlertDialog(
        key: const Key('mixer_reset_confirm'),
        backgroundColor: surface.cardHigh,
        title: Text(l10n.mixerReset),
        content: Text(l10n.mixerResetConfirmBody),
        actions: [
          TextButton(
            key: const Key('mixer_reset_cancel'),
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            key: const Key('mixer_reset_apply'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(l10n.mixerReset),
          ),
        ],
      ),
    );
    if (confirmed == true &&
        context.mounted &&
        repository.mixGeneration == generation) {
      context.read<LooperBloc>().add(const LooperMixerReset());
    }
  }

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
        onTap: () => unawaited(_confirmReset(context)),
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

/// The view button: opens the Track / Wave / Mixer menu below itself. A radio
/// menu (`menuitemradio` in the prototype): the current view is checked.
class _ViewButton extends StatelessWidget {
  const _ViewButton();

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final l10n = context.l10n;
    final current = context.select<TracksCubit, StageView>(
      (cubit) => cubit.state.stageView,
    );
    return LoopMenu<StageView>(
      value: current,
      onSelected: context.read<TracksCubit>().showView,
      items: [
        for (final view in StageView.values)
          LoopSelectItem(
            key: Key('stage_view_${view.name}'),
            value: view,
            label: switch (view) {
              StageView.track => l10n.stageViewTrack,
              StageView.wave => l10n.stageViewWave,
              StageView.mixer => l10n.stageViewMixer,
            },
          ),
      ],
      builder: (context, controller) => _StageIconButton(
        key: const Key('stage_view_menu'),
        semanticLabel: l10n.stageViewMenu,
        bordered: true,
        onTap: () => controller.isOpen ? controller.close() : controller.open(),
        child: PenIconView(
          icon: PenIcon.views,
          size: 28,
          color: surface.textPrimary,
        ),
      ),
    );
  }
}

/// The performance-record light: a circle holding a red dot at rest, and —
/// per `c/stage-armed` — a red stop square with the elapsed readout beside it
/// while a capture runs. A state light, not a button: the MODE footswitch
/// long-press owns arm/disarm on the console, and the recording indicator
/// persists on the stage while a capture runs.
///
/// A fixed slot (#1308): the elapsed readout appears inside room the light
/// always holds, so arming moves nothing beside it.
class _RecordLight extends StatelessWidget {
  const _RecordLight();

  /// The light's 36, the 12 before the readout, and the readout's 60 — six
  /// JetBrains Mono figures at 16, enough for `100:00`.
  static const double slotWidth = 36 + 12 + 60;

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
        child: SizedBox(
          key: const Key('stage_record_slot'),
          width: slotWidth,
          child: Row(
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
                Flexible(
                  child: AppText(
                    elapsed,
                    key: const Key('stage_record_elapsed'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: surface.rec,
                      fontFamily: SurfaceTheme.monoFont,
                      fontSize: 16,
                      fontFeatures: const [FontFeature.tabularFigures()],
                      height: 1.15,
                      leadingDistribution: TextLeadingDistribution.even,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// The console's CPU load, right of the record light (#1307): `CPU 23%`, the
/// share of the whole machine with every core counted as 100%.
///
/// Absent on a build that cannot measure it (no `/proc/stat`, the macOS
/// desktop). Owns its [CpuLoadCubit], so the load is sampled only while the
/// bar is on screen, and only a change in the shown figure rebuilds the
/// figure. A fixed slot sized for `CPU 100%`, so no reading moves anything.
class _CpuLoad extends StatelessWidget {
  const _CpuLoad();

  /// Eight JetBrains Mono characters at 16: `CPU 100%`.
  static const double slotWidth = 80;

  @override
  Widget build(BuildContext context) {
    final repository = context.read<CpuLoadRepository>();
    if (!repository.isSupported) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(left: StageTopBar._gap),
      child: BlocProvider(
        create: (_) => CpuLoadCubit(repository: repository),
        child: const _CpuLoadFigure(),
      ),
    );
  }
}

class _CpuLoadFigure extends StatelessWidget {
  const _CpuLoadFigure();

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final l10n = context.l10n;
    final load = context.watch<CpuLoadCubit>().state;
    return Semantics(
      label: load == null
          ? l10n.a11yStageCpuLoadPending
          : l10n.a11yStageCpuLoad(load),
      child: ExcludeSemantics(
        child: SizedBox(
          key: const Key('stage_cpu_load_slot'),
          width: _CpuLoad.slotWidth,
          child: AppText(
            load == null ? l10n.stageCpuLoadPending : l10n.stageCpuLoad(load),
            key: const Key('stage_cpu_load'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: surface.textSecondary,
              fontFamily: SurfaceTheme.monoFont,
              fontSize: 16,
              fontFeatures: const [FontFeature.tabularFigures()],
              height: 1.15,
              leadingDistribution: TextLeadingDistribution.even,
            ),
          ),
        ),
      ),
    );
  }
}
