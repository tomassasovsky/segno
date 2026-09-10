import 'package:flutter/material.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/view/audio_routing/audio_routing_tabs.dart';
import 'package:segno/looper/view/audio_routing/input_setup_tab.dart';
import 'package:segno/looper/view/audio_routing/recording_inputs_tab.dart';
import 'package:segno/looper/view/loop_settings/loop_settings_frame.dart';

/// Which Audio routing task the page is showing.
///
/// The pen draws these as four pills in one nav row rather than as separate
/// routes, so they are page state, not navigator state: switching tasks keeps
/// the route and its Back button pointing at Settings.
enum AudioRoutingTab {
  /// Input setup: pick an input, pair it or not, place it and trim it.
  setup,

  /// Recording inputs: pick a track, then the inputs it records.
  record,

  /// Output routing: pick a source, then the destinations it reaches.
  outputs,

  /// Output setup: each destination's level, mute, format and balance.
  outputSetup,
}

/// The Audio routing route (accepted design, slice 3c): the pen's
/// `21 Audio routing` section, four tasks behind one frame.
class AudioRoutingPage extends StatefulWidget {
  /// Creates an [AudioRoutingPage] opened on [initial].
  const AudioRoutingPage({this.initial = AudioRoutingTab.setup, super.key});

  /// The task the page opens on.
  final AudioRoutingTab initial;

  @override
  State<AudioRoutingPage> createState() => _AudioRoutingPageState();
}

class _AudioRoutingPageState extends State<AudioRoutingPage> {
  late AudioRoutingTab _tab = widget.initial;

  void _back() => Navigator.maybePop(context);

  void _stage() => Navigator.popUntil(context, (route) => route.isFirst);

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    // [LoopSettingsFrame] lays itself out on the pen canvas, and positions
    // its children in the 1920 x 984 MAIN area — so every `top` below is the
    // pen's screen y minus the 96 px top bar.
    return Scaffold(
      body: LoopSettingsFrame(
        crumb: l10n.loopSettingsCrumb,
        title: l10n.routingTitle,
        titleLeft: 100,
        onBack: _back,
        onStage: _stage,
        children: [
          Positioned(
            left: 100,
            top: 132,
            child: AudioRoutingTabBar(
              selected: _tab,
              onSelected: (tab) => setState(() => _tab = tab),
            ),
          ),
          Positioned.fill(
            child: KeyedSubtree(
              key: ValueKey(_tab),
              child: switch (_tab) {
                AudioRoutingTab.setup => const InputSetupTab(),
                AudioRoutingTab.record => const RecordingInputsTab(),
                // The remaining tasks land with their own slices of 3c;
                // an unfinished pill must not draw a blank page.
                AudioRoutingTab.outputs ||
                AudioRoutingTab.outputSetup => const SizedBox.shrink(),
              },
            ),
          ),
        ],
      ),
    );
  }
}
