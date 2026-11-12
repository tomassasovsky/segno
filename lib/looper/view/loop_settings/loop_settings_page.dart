import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:material_ui/material_ui.dart';
import 'package:segno/app/app_notices.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/cubit/loop_settings_feedback_cubit.dart';
import 'package:segno/looper/view/loop_settings/loop_edit_scope.dart';
import 'package:segno/looper/view/loop_settings/loop_mode_page.dart';
import 'package:segno/looper/view/loop_settings/loop_playback_page.dart';
import 'package:segno/looper/view/loop_settings/loop_recording_page.dart';
import 'package:segno/looper/view/loop_settings/loop_settings_frame.dart';
import 'package:segno/looper/view/loop_settings/loop_settings_widgets.dart';
import 'package:segno/looper/view/loop_settings/loop_tempo_page.dart';
import 'package:segno/notices/notices.dart';
import 'package:segno/theme/theme.dart';

/// The four tabs of Loop settings (#1659), in setup order.
enum LoopSettingsTab {
  /// The five mode cards.
  mode,

  /// Tempo, time signature, click and count-in.
  tempo,

  /// When a take starts and ends: start, second press, length, later
  /// tracks and record timing. Locked while a take records.
  recording,

  /// What a recorded loop does as it repeats: Loop/Once, decay, Follow
  /// tempo and Pitch. Never locked.
  playback,
}

/// The Loop settings route: four tabs on the title row, opened at
/// [initial], plus the Time signature page the Tempo & click tab opens.
///
/// One track selection belongs to the visit: the Recording and Playback
/// tabs share it, it opens at Defaults, and it ends when Back or Stage
/// leaves the route. Back closes the Time signature page first; Stage leaves
/// from anywhere.
class LoopSettingsPage extends StatefulWidget {
  /// Creates a [LoopSettingsPage] opened at [initial].
  const LoopSettingsPage({
    this.initial = LoopSettingsTab.mode,
    this.onTab,
    this.onStage,
    super.key,
  });

  /// The tab shown first.
  final LoopSettingsTab initial;

  /// Told each tab the player switches to, so the next visit can open on
  /// it.
  final ValueChanged<LoopSettingsTab>? onTab;

  /// Closes the tray when Stage is chosen from its Loop entry.
  final VoidCallback? onStage;

  @override
  State<LoopSettingsPage> createState() => _LoopSettingsPageState();
}

class _LoopSettingsPageState extends State<LoopSettingsPage> {
  final LoopEditCoordinator _edits = LoopEditCoordinator();
  late LoopSettingsTab _tab = widget.initial;

  /// Whether the Time signature page is open over the Tempo & click tab.
  bool _signature = false;

  /// The visit's track selection: a channel, or `null` for the defaults.
  int? _track;

  void _show(LoopSettingsTab tab) {
    if (tab == _tab) return;
    _edits.cancel();
    setState(() => _tab = tab);
    widget.onTab?.call(tab);
  }

  void _openSignature() {
    _edits.cancel();
    setState(() => _signature = true);
  }

  void _selectTrack(int? track) => setState(() => _track = track);

  void _back() {
    if (_edits.cancel()) return;
    if (_signature) {
      setState(() => _signature = false);
    } else {
      Navigator.of(context).maybePop();
    }
  }

  void _stage() {
    _edits.cancel();
    widget.onStage?.call();
    Navigator.of(context).popUntil((route) => route.isFirst);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final tabs = _LoopSettingsTabs(selected: _tab, onShow: _show);
    final page = Key('loop_settings_page_${_tab.name}');
    return BlocProvider(
      create: (context) => LoopSettingsFeedbackCubit(
        repository: context.read<LooperRepository>(),
      ),
      child: BlocListener<LoopSettingsFeedbackCubit, LoopSettingsFeedback>(
        listenWhen: (previous, current) => previous.refused != current.refused,
        listener: (context, _) => context.read<NoticesCubit>().show(
          Notice(
            id: AppNoticeId.loopSettings,
            tone: NoticeTone.warning,
            title: (l10n) => l10n.loopSettingsRefused,
            body: (l10n) => l10n.loopSettingsRefusedBody,
          ),
        ),
        child: LoopEditScope(
          coordinator: _edits,
          child: CallbackShortcuts(
            bindings: {
              const SingleActivator(LogicalKeyboardKey.escape): _back,
            },
            child: Focus(
              autofocus: true,
              child: Scaffold(
                body: _signature
                    ? LoopSettingsFrame(
                        key: const Key('loop_settings_page_signature'),
                        crumb: l10n.loopSettingsCrumbNested,
                        title: l10n.loopTempoSignature,
                        onBack: _back,
                        onStage: _stage,
                        children: [LoopTimeSignaturePage(onChosen: _back)],
                      )
                    // One frame for every tab, so a tab switch keeps the tab
                    // row (and the focus on it); only the content is keyed.
                    : LoopSettingsFrame(
                        crumb: l10n.loopSettingsCrumb,
                        title: l10n.loopSettingsTitle,
                        actions: tabs,
                        // The title ends before the tabs, a gap short.
                        titleRight:
                            _LoopSettingsTabs.widthOf(context) +
                            context.spacing.xl,
                        onBack: _back,
                        onStage: _stage,
                        children: [
                          switch (_tab) {
                            LoopSettingsTab.mode => LoopModePage(key: page),
                            LoopSettingsTab.tempo => LoopTempoPage(
                              key: page,
                              onOpenSignature: _openSignature,
                            ),
                            LoopSettingsTab.recording => LoopRecordingPage(
                              key: page,
                              track: _track,
                              onTrack: _selectTrack,
                            ),
                            LoopSettingsTab.playback => LoopPlaybackPage(
                              key: page,
                              track: _track,
                              onTrack: _selectTrack,
                            ),
                          },
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

/// The four tabs at the right end of the title row: one 64 high choice each,
/// the selected one filled, as the Pedals page's contexts are drawn.
class _LoopSettingsTabs extends StatelessWidget {
  const _LoopSettingsTabs({required this.selected, required this.onShow});

  final LoopSettingsTab selected;
  final ValueChanged<LoopSettingsTab> onShow;

  /// Each tab's width: the longest label in either language with room.
  static const double tabWidth = 220;

  /// The gap between two tabs.
  static double gapOf(BuildContext context) => context.spacing.sm;

  /// The whole row's width.
  static double widthOf(BuildContext context) =>
      LoopSettingsTab.values.length * tabWidth +
      (LoopSettingsTab.values.length - 1) * gapOf(context);

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final (i, tab) in LoopSettingsTab.values.indexed) ...[
          if (i > 0) SizedBox(width: gapOf(context)),
          LoopChoiceButton(
            key: Key('loop_settings_tab_${tab.name}'),
            label: switch (tab) {
              LoopSettingsTab.mode => l10n.loopTabMode,
              LoopSettingsTab.tempo => l10n.loopTabTempo,
              LoopSettingsTab.recording => l10n.loopTabRecording,
              LoopSettingsTab.playback => l10n.loopTabPlayback,
            },
            selected: tab == selected,
            onTap: () => onShow(tab),
            width: tabWidth,
            height: 64,
          ),
        ],
      ],
    );
  }
}
