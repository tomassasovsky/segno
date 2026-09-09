import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/bloc/looper_bloc.dart';
import 'package:segno/looper/cubit/playback_options_cubit.dart';
import 'package:segno/looper/view/loop_settings/loop_settings_labels.dart';
import 'package:segno/looper/view/loop_settings/loop_settings_widgets.dart';
import 'package:segno/looper/view/loop_settings/loop_track_names.dart';
import 'package:segno/theme/theme.dart';

/// What the Playback & overdub page reads off the looper for one scope.
typedef _PlaybackValues = ({
  int count,
  bool? trackOnceOverride,
  int? trackDecayOverride,
});

_PlaybackValues _playbackValues(LooperState state, int? channel) {
  final track = channel == null || channel >= state.tracks.length
      ? null
      : state.tracks[channel];
  return (
    count: state.tracks.length,
    trackOnceOverride: track?.oneShotOverride,
    trackDecayOverride: track?.overdubDecayOverride,
  );
}

/// The Playback & overdub page: the scope selector, then Loop/Once and the
/// overdub decay slider for that scope, each with its origin tag and a Use
/// default when a track overrides it (the pen's `playback-layout`, 1720 x
/// 488 at (100, 342)). Both stay live during playback and capture.
class LoopPlaybackPage extends StatefulWidget {
  /// Creates a [LoopPlaybackPage].
  const LoopPlaybackPage({super.key});

  @override
  State<LoopPlaybackPage> createState() => _LoopPlaybackPageState();
}

class _LoopPlaybackPageState extends State<LoopPlaybackPage> {
  int? _scope;

  void _setOnce(bool? once) {
    final scope = _scope;
    if (scope == null) {
      unawaited(context.read<PlaybackOptionsCubit>().setOnce(value: once!));
    } else {
      context.read<LooperBloc>().add(LooperTrackOnceChanged(scope, once: once));
    }
  }

  void _setDecay(int? percent) {
    final scope = _scope;
    if (scope == null) {
      unawaited(
        context.read<PlaybackOptionsCubit>().setOverdubDecay(percent ?? 0),
      );
    } else {
      context.read<LooperBloc>().add(
        LooperTrackOverdubDecayChanged(scope, percent: percent),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    final v = context.select<LooperBloc, _PlaybackValues>(
      (bloc) => _playbackValues(bloc.state, _scope),
    );
    // The defaults are the cubit's own intent (what it persists and pushes);
    // the overrides are the repository's projection.
    final defaults = context.watch<PlaybackOptionsCubit>().state;
    final scope = _scope;
    final onceCustom = scope != null && v.trackOnceOverride != null;
    final once = scope == null
        ? defaults.once
        : v.trackOnceOverride ?? defaults.once;
    final decayCustom = scope != null && v.trackDecayOverride != null;
    final decay = scope == null
        ? defaults.overdubDecay
        : v.trackDecayOverride ?? defaults.overdubDecay;
    const top = 342.0;
    return Positioned.fill(
      child: Stack(
        children: [
          Positioned(
            left: 100,
            top: 124,
            child: LoopScopeSelector(
              trackNames: trackDisplayNames(context, v.count),
              selected: scope,
              onSelected: (channel) => setState(() => _scope = channel),
            ),
          ),
          // ---- playback
          Positioned(
            left: 100,
            top: top + 17,
            child: LoopFieldLabel(
              title: l10n.loopPlaybackLabel,
              fontSize: 32,
              origin: scope == null
                  ? null
                  : onceCustom
                  ? LoopFieldOrigin.custom
                  : LoopFieldOrigin.isDefault,
            ),
          ),
          Positioned(
            left: 100 + 328,
            top: top,
            child: LoopChoiceRow<bool>(
              values: const [false, true],
              labelOf: (o) => o ? l10n.loopPlaybackOnce : l10n.loopPlaybackLoop,
              keyOf: (o) =>
                  Key(o ? 'loop_playback_once' : 'loop_playback_loop'),
              iconOf: (o) =>
                  o ? LucideIcons.arrowRightToLine : LucideIcons.repeat,
              selected: once,
              onSelected: _setOnce,
              width: 584,
              height: 120,
              fontSize: 28,
            ),
          ),
          if (onceCustom)
            Positioned(
              left: 100 + 328 + 1221,
              top: top + 28,
              child: LoopUseDefaultButton(
                key: const Key('loop_playback_use_default'),
                onTap: () => _setOnce(null),
              ),
            ),
          Positioned(
            left: 100 + 328,
            top: top + 140,
            child: LoopNote(
              once ? l10n.loopPlaybackNoteOnce : l10n.loopPlaybackNoteLoop,
              key: const Key('loop_playback_note'),
            ),
          ),
          // ---- overdub decay
          Positioned(
            left: 100,
            top: top + 246 + 51,
            child: LoopFieldLabel(
              title: l10n.loopDecayLabel,
              fontSize: 32,
              origin: scope == null
                  ? null
                  : decayCustom
                  ? LoopFieldOrigin.custom
                  : LoopFieldOrigin.isDefault,
            ),
          ),
          Positioned(
            left: 100 + 328,
            top: top + 246 + 10,
            child: AppText(
              overdubDecayReadout(l10n, decay),
              key: const Key('loop_decay_readout'),
              style: TextStyle(
                color: surface.textPrimary,
                fontSize: 40,
                height: 1,
              ),
            ),
          ),
          if (decayCustom)
            Positioned(
              left: 100 + 328 + 1221,
              top: top + 246,
              child: LoopUseDefaultButton(
                key: const Key('loop_decay_use_default'),
                onTap: () => _setDecay(null),
              ),
            ),
          Positioned(
            left: 100 + 328,
            top: top + 246 + 84,
            child: LoopSlider(
              key: const Key('loop_decay_slider'),
              value: decay / 100,
              onChanged: (fraction) => _setDecay((fraction * 100).round()),
              width: 1392,
              semanticLabel: l10n.loopDecaySliderLabel,
            ),
          ),
          Positioned(
            left: 100 + 328,
            top: top + 246 + 160,
            child: SizedBox(
              width: 1392,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  LoopNote(l10n.loopDecayKeep),
                  LoopNote(l10n.loopDecayReplace),
                ],
              ),
            ),
          ),
          Positioned(
            left: 100 + 328,
            top: top + 246 + 208,
            child: LoopNote(
              overdubDecayNote(l10n, decay),
              key: const Key('loop_decay_note'),
            ),
          ),
        ],
      ),
    );
  }
}
