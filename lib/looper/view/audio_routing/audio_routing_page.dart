import 'package:flutter/material.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/view/audio_routing/audio_routing_tabs.dart';
import 'package:segno/looper/view/audio_routing/input_setup_tab.dart';
import 'package:segno/looper/view/audio_routing/output_routing_tab.dart';
import 'package:segno/looper/view/audio_routing/output_setup_tab.dart';
import 'package:segno/looper/view/audio_routing/recording_inputs_tab.dart';
import 'package:segno/looper/view/audio_routing/routing_names_page.dart';
import 'package:segno/looper/view/loop_settings/loop_settings_frame.dart';
import 'package:segno/looper/view/loop_settings/loop_settings_widgets.dart';

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

  /// The names list being shown over the tasks, or null for the tasks.
  ///
  /// A page state rather than a route, like the tasks themselves: the pen
  /// draws it behind the same frame, and its Back button goes back to the
  /// task it was opened from rather than out to Settings.
  RoutingNames? _names;

  /// Which side the header action names, given the task in view.
  RoutingNames get _side => switch (_tab) {
    AudioRoutingTab.setup || AudioRoutingTab.record => RoutingNames.inputs,
    AudioRoutingTab.outputs ||
    AudioRoutingTab.outputSetup => RoutingNames.outputs,
  };

  void _back() {
    if (_names != null) {
      setState(() => _names = null);
      return;
    }
    Navigator.maybePop(context);
  }

  void _stage() => Navigator.popUntil(context, (route) => route.isFirst);

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    // [LoopSettingsFrame] lays itself out on the pen canvas, and positions
    // its children in the 1920 x 984 MAIN area — so every `top` below is the
    // pen's screen y minus the 96 px top bar.
    final names = _names;
    return Scaffold(
      body: LoopSettingsFrame(
        crumb: l10n.loopSettingsCrumb,
        title: switch (names) {
          null => l10n.routingTitle,
          RoutingNames.inputs => l10n.routingInputNames,
          RoutingNames.outputs => l10n.routingOutputNames,
        },
        titleLeft: 100,
        onBack: _back,
        onStage: _stage,
        children: names != null
            ? [RoutingNamesList(side: names)]
            : [
                Positioned(
                  left: 100,
                  top: 132,
                  child: AudioRoutingTabBar(
                    selected: _tab,
                    onSelected: (tab) => setState(() => _tab = tab),
                  ),
                ),
                Positioned(
                  // The pen's header action, right-aligned with the task row.
                  right: 100,
                  top: 32,
                  child: LoopOutlinedButton(
                    key: const Key('routing_names_action'),
                    width: _side == RoutingNames.inputs ? 182 : 201,
                    label: _side == RoutingNames.inputs
                        ? l10n.routingInputNames
                        : l10n.routingOutputNames,
                    onTap: () => setState(() => _names = _side),
                  ),
                ),
                Positioned.fill(
                  child: KeyedSubtree(
                    key: ValueKey(_tab),
                    child: switch (_tab) {
                      AudioRoutingTab.setup => const InputSetupTab(),
                      AudioRoutingTab.record => const RecordingInputsTab(),
                      AudioRoutingTab.outputs => const OutputRoutingTab(),
                      AudioRoutingTab.outputSetup => const OutputSetupTab(),
                    },
                  ),
                ),
              ],
      ),
    );
  }
}
