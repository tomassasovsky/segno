import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/bloc/looper_bloc.dart';
import 'package:segno/looper/cubit/playback_options_cubit.dart';
import 'package:segno/looper/view/loop_settings/loop_settings_widgets.dart';
import 'package:segno/looper/view/loop_settings/loop_track_names.dart';
import 'package:segno/theme/theme.dart';

/// The Audio & tempo page (#1179, the pen's `audio-tempo-layout`, 1720 x 444
/// at (100, 364), screens 07/04 to 07/06): the scope selector, then Follow
/// tempo and Pitch for that scope, each with its origin tag and a Use default
/// when a track overrides it. A scope that keeps its recorded speed shows
/// Pitch as the readout it then is: the pitch stays the recorded one.
class LoopAudioTempoPage extends StatefulWidget {
  /// Creates a [LoopAudioTempoPage].
  const LoopAudioTempoPage({super.key});

  @override
  State<LoopAudioTempoPage> createState() => _LoopAudioTempoPageState();
}

class _LoopAudioTempoPageState extends State<LoopAudioTempoPage> {
  int? _scope;

  void _setFollow(bool? follow) {
    final cubit = context.read<PlaybackOptionsCubit>();
    if (cubit.state.followTempo == null) return;
    unawaited(cubit.setFollowTempo(channel: _scope, follow: follow));
  }

  void _setPitch(PitchMode? mode) {
    final cubit = context.read<PlaybackOptionsCubit>();
    if (cubit.state.pitchMode == null) return;
    unawaited(cubit.setPitchMode(channel: _scope, mode: mode));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    final count = context.select<LooperBloc, int>(
      (bloc) => bloc.state.tracks.length,
    );
    // Default and Custom membership come from the confirmed owners; a field
    // whose owner is not ready (loading, or a vector owed after an uncertain
    // receipt) shows the default it would restore, disabled.
    final options = context.watch<PlaybackOptionsCubit>().state;
    final scope = _scope;
    final follow = options.followTempo;
    final pitch = options.pitchMode;
    final followCustom = scope != null && follow?.trackOverrides[scope] != null;
    final follows =
        (scope == null ? follow?.defaultValue : follow?.effective(scope)) ??
        true;
    final pitchCustom = scope != null && pitch?.trackOverrides[scope] != null;
    final mode =
        (scope == null ? pitch?.defaultValue : pitch?.effective(scope)) ??
        PitchMode.unchanged;
    const top = 364.0;
    const pitchTop = top + 270;
    return Positioned.fill(
      child: Stack(
        children: [
          Positioned(
            left: 100,
            top: 124,
            child: LoopScopeSelector(
              trackNames: trackDisplayNames(context, count),
              selected: scope,
              onSelected: (channel) => setState(() => _scope = channel),
            ),
          ),
          // ---- follow tempo
          Positioned(
            left: 100,
            top: top + (scope == null ? 34 : 17),
            child: LoopFieldLabel(
              title: l10n.loopAudioFollowLabel,
              fontSize: 32,
              origin: scopedOrigin(
                scoped: scope != null,
                custom: followCustom,
              ),
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
              // The pen's glyphs: Off ↦, On ⇄.
              iconOf: (on) => on
                  ? LucideIcons.arrowRightLeft
                  : LucideIcons.arrowRightToLine,
              selected: follows,
              enabled: follow != null,
              onSelected: _setFollow,
              width: 744,
              height: 120,
              fontSize: 28,
            ),
          ),
          if (followCustom)
            Positioned(
              left: 100 + 328 + 1221,
              top: top + 28,
              child: LoopUseDefaultButton(
                key: const Key('loop_audio_follow_use_default'),
                onTap: follow != null ? () => _setFollow(null) : null,
              ),
            ),
          Positioned(
            left: 100 + 328,
            top: top + 140,
            child: LoopNote(
              follows ? l10n.loopAudioNoteOn : l10n.loopAudioNoteOff,
              key: const Key('loop_audio_follow_note'),
            ),
          ),
          // ---- pitch
          if (follows) ...[
            Positioned(
              left: 100,
              top: pitchTop + (scope == null ? 34 : 17),
              child: LoopFieldLabel(
                title: l10n.loopAudioPitchLabel,
                fontSize: 32,
                origin: scopedOrigin(
                  scoped: scope != null,
                  custom: pitchCustom,
                ),
              ),
            ),
            Positioned(
              left: 100 + 328,
              top: pitchTop,
              child: LoopChoiceRow<PitchMode>(
                values: const [PitchMode.unchanged, PitchMode.followsSpeed],
                labelOf: (m) => m == PitchMode.unchanged
                    ? l10n.loopAudioPitchUnchanged
                    : l10n.loopAudioPitchFollows,
                keyOf: (m) => Key(
                  m == PitchMode.unchanged
                      ? 'loop_audio_pitch_unchanged'
                      : 'loop_audio_pitch_follows',
                ),
                // The pen's glyphs: Unchanged ≡, Follows speed ↗.
                iconOf: (m) => m == PitchMode.unchanged
                    ? LucideIcons.menu
                    : LucideIcons.arrowUpRight,
                selected: mode,
                enabled: pitch != null,
                onSelected: _setPitch,
                width: 744,
                height: 120,
                fontSize: 28,
              ),
            ),
            if (pitchCustom)
              Positioned(
                left: 100 + 328 + 1221,
                top: pitchTop + 28,
                child: LoopUseDefaultButton(
                  key: const Key('loop_audio_pitch_use_default'),
                  onTap: pitch != null ? () => _setPitch(null) : null,
                ),
              ),
            Positioned(
              left: 100 + 328,
              top: pitchTop + 140,
              child: LoopNote(
                mode == PitchMode.unchanged
                    ? l10n.loopAudioNotePitchKept
                    : l10n.loopAudioNotePitchFollows,
                key: const Key('loop_audio_pitch_note'),
              ),
            ),
          ] else ...[
            // Keeping the recorded speed keeps the recorded pitch: a readout
            // (the pen's 06 / Keep recorded speed), not a choice.
            Positioned(
              left: 100,
              top: pitchTop + 34,
              child: LoopFieldLabel(
                title: l10n.loopAudioPitchLabel,
                fontSize: 32,
              ),
            ),
            Positioned(
              left: 100 + 328,
              top: pitchTop + 42,
              child: Row(
                key: const Key('loop_audio_pitch_readout'),
                children: [
                  Icon(
                    LucideIcons.menu,
                    size: 36,
                    color: surface.textPrimary,
                  ),
                  const SizedBox(width: 24),
                  AppText(
                    l10n.loopAudioPitchUnchanged,
                    style: TextStyle(
                      color: surface.textPrimary,
                      fontSize: 28,
                      height: 1,
                    ),
                  ),
                ],
              ),
            ),
            Positioned(
              left: 100 + 328,
              top: pitchTop + 140,
              child: LoopNote(
                l10n.loopAudioNotePitchUnchanged,
                key: const Key('loop_audio_pitch_note'),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
