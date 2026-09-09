import 'package:flutter/material.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/view/loop_settings/loop_audio_tempo_page.dart';
import 'package:segno/looper/view/loop_settings/loop_length_page.dart';
import 'package:segno/looper/view/loop_settings/loop_mode_page.dart';
import 'package:segno/looper/view/loop_settings/loop_playback_page.dart';
import 'package:segno/looper/view/loop_settings/loop_recording_page.dart';
import 'package:segno/looper/view/loop_settings/loop_settings_frame.dart';
import 'package:segno/looper/view/loop_settings/loop_settings_hub.dart';
import 'package:segno/looper/view/loop_settings/loop_tempo_page.dart';

/// The pages of the Loop settings route: the hub and its six submenus plus
/// the Time signature page the Tempo & click page opens.
enum LoopSettingsPageId {
  /// The six rows.
  hub,

  /// The five mode cards.
  mode,

  /// Pedal or Sound; Play or Overdub.
  recording,

  /// Tempo, click and count-in.
  tempo,

  /// The 17 time signatures.
  signature,

  /// Loop length and record timing.
  length,

  /// Loop/Once and overdub decay.
  playback,

  /// Tempo following and pitch, as a readout.
  audioTempo;

  /// The page a hub row opens.
  static LoopSettingsPageId of(LoopSettingsSubmenu submenu) =>
      switch (submenu) {
        LoopSettingsSubmenu.mode => LoopSettingsPageId.mode,
        LoopSettingsSubmenu.recording => LoopSettingsPageId.recording,
        LoopSettingsSubmenu.tempo => LoopSettingsPageId.tempo,
        LoopSettingsSubmenu.length => LoopSettingsPageId.length,
        LoopSettingsSubmenu.playback => LoopSettingsPageId.playback,
        LoopSettingsSubmenu.audioTempo => LoopSettingsPageId.audioTempo,
      };
}

/// The Loop settings route (accepted design, Loop setup): the hub and its
/// submenus as one full-screen page stack, each drawn at the pen's size.
/// Back climbs the stack and leaves the route from the hub; Stage leaves it
/// from anywhere.
class LoopSettingsPage extends StatefulWidget {
  /// Creates a [LoopSettingsPage] opened at [initial].
  const LoopSettingsPage({
    this.initial = LoopSettingsPageId.hub,
    super.key,
  });

  /// The page shown first; a submenu opened directly still has the hub
  /// under it.
  final LoopSettingsPageId initial;

  @override
  State<LoopSettingsPage> createState() => _LoopSettingsPageState();
}

class _LoopSettingsPageState extends State<LoopSettingsPage> {
  late final List<LoopSettingsPageId> _stack = [
    LoopSettingsPageId.hub,
    if (widget.initial != LoopSettingsPageId.hub) widget.initial,
  ];

  LoopSettingsPageId get _current => _stack.last;

  void _open(LoopSettingsPageId page) => setState(() => _stack.add(page));

  void _back() {
    if (_stack.length > 1) {
      setState(_stack.removeLast);
    } else {
      Navigator.of(context).maybePop();
    }
  }

  void _stage() => Navigator.of(context).popUntil((route) => route.isFirst);

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final page = _current;
    final (title, titleLeft) = switch (page) {
      LoopSettingsPageId.hub => (l10n.loopSettingsTitle, 36.0),
      LoopSettingsPageId.mode => (l10n.loopHubMode, 36.0),
      LoopSettingsPageId.recording => (l10n.loopHubRecording, 36.0),
      LoopSettingsPageId.tempo => (l10n.loopHubTempo, 36.0),
      LoopSettingsPageId.signature => (l10n.loopTempoSignature, 36.0),
      LoopSettingsPageId.length => (l10n.loopHubLength, 100.0),
      LoopSettingsPageId.playback => (l10n.loopHubPlayback, 100.0),
      LoopSettingsPageId.audioTempo => (l10n.loopHubAudioTempo, 100.0),
    };
    return Scaffold(
      body: LoopSettingsFrame(
        key: Key('loop_settings_page_${page.name}'),
        crumb: page == LoopSettingsPageId.hub
            ? l10n.loopSettingsCrumb
            : l10n.loopSettingsCrumbNested,
        title: title,
        titleLeft: titleLeft,
        onBack: _back,
        onStage: _stage,
        children: [
          switch (page) {
            LoopSettingsPageId.hub => LoopSettingsHub(
              onOpen: (submenu) => _open(LoopSettingsPageId.of(submenu)),
            ),
            LoopSettingsPageId.mode => const LoopModePage(),
            LoopSettingsPageId.recording => const LoopRecordingPage(),
            LoopSettingsPageId.tempo => LoopTempoPage(
              onOpenSignature: () => _open(LoopSettingsPageId.signature),
            ),
            LoopSettingsPageId.signature => LoopTimeSignaturePage(
              onChosen: _back,
            ),
            LoopSettingsPageId.length => const LoopLengthPage(),
            LoopSettingsPageId.playback => const LoopPlaybackPage(),
            LoopSettingsPageId.audioTempo => const LoopAudioTempoPage(),
          },
        ],
      ),
    );
  }
}
