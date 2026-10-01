import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/bloc/looper_bloc.dart';
import 'package:segno/looper/view/loop_settings/loop_settings_widgets.dart';
import 'package:segno/looper/view/loop_settings/loop_track_names.dart';

/// The Audio & tempo page as a readout (the pen's `audio-tempo-layout`,
/// 1720 x 444 at (100, 364)): Follow tempo and Pitch drawn at the state
/// every track has today (recorded speed, unchanged pitch), with the choices
/// disabled and one line saying tempo following is not available yet. The
/// engine has no contract for either setting (accepted design, Audio &
/// tempo: "its native contract does not yet exist").
class LoopAudioTempoPage extends StatefulWidget {
  /// Creates a [LoopAudioTempoPage].
  const LoopAudioTempoPage({super.key});

  @override
  State<LoopAudioTempoPage> createState() => _LoopAudioTempoPageState();
}

class _LoopAudioTempoPageState extends State<LoopAudioTempoPage> {
  int? _scope;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final count = context.select<LooperBloc, int>(
      (bloc) => bloc.state.tracks.length,
    );
    final names = trackDisplayNames(context, count);
    const top = 364.0;
    return Positioned.fill(
      child: Stack(
        children: [
          Positioned(
            left: 100,
            top: 124,
            child: LoopScopeSelector(
              trackNames: names,
              selected: _scope,
              onSelected: (channel) => setState(() => _scope = channel),
            ),
          ),
          Positioned(
            left: 100,
            top: 244,
            child: LoopNote(
              l10n.loopAudioUnavailable,
              key: const Key('loop_audio_unavailable'),
            ),
          ),
          Positioned(
            left: 100,
            top: top + 34,
            child: LoopFieldLabel(
              title: l10n.loopAudioFollowLabel,
              fontSize: 32,
            ),
          ),
          Positioned(
            left: 100 + 328,
            top: top,
            child: LoopChoiceRow<bool>(
              values: const [false, true],
              labelOf: (on) =>
                  on ? l10n.loopAudioFollowOn : l10n.loopAudioFollowOff,
              keyOf: (on) =>
                  Key(on ? 'loop_audio_follow_on' : 'loop_audio_follow_off'),
              iconOf: (on) => on ? LucideIcons.timer : LucideIcons.timerOff,
              selected: false,
              enabled: false,
              onSelected: (_) {},
              width: 744,
              height: 120,
              fontSize: 28,
            ),
          ),
          Positioned(
            left: 100 + 328,
            top: top + 140,
            child: LoopNote(l10n.loopAudioNoteOff),
          ),
          Positioned(
            left: 100,
            top: top + 270 + 34,
            child: LoopFieldLabel(
              title: l10n.loopAudioPitchLabel,
              fontSize: 32,
            ),
          ),
          Positioned(
            left: 100 + 328,
            top: top + 270,
            child: LoopChoiceRow<bool>(
              values: const [true, false],
              labelOf: (unchanged) => unchanged
                  ? l10n.loopAudioPitchUnchanged
                  : l10n.loopAudioPitchFollows,
              keyOf: (unchanged) => Key(
                unchanged
                    ? 'loop_audio_pitch_unchanged'
                    : 'loop_audio_pitch_follows',
              ),
              iconOf: (unchanged) =>
                  unchanged ? LucideIcons.music : LucideIcons.audioLines,
              selected: true,
              enabled: false,
              onSelected: (_) {},
              width: 744,
              height: 120,
              fontSize: 28,
            ),
          ),
          Positioned(
            left: 100 + 328,
            top: top + 270 + 140,
            child: LoopNote(l10n.loopAudioNotePitchUnchanged),
          ),
        ],
      ),
    );
  }
}
