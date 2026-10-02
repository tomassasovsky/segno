import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/bloc/looper_bloc.dart';
import 'package:segno/looper/cubit/playback_options_cubit.dart';
import 'package:segno/looper/view/loop_settings/loop_edit_scope.dart';
import 'package:segno/looper/view/loop_settings/loop_settings_labels.dart';
import 'package:segno/looper/view/loop_settings/loop_settings_widgets.dart';
import 'package:segno/looper/view/loop_settings/loop_track_names.dart';
import 'package:segno/theme/theme.dart';

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

  /// The decay under the pointer while the slider is dragged; the drag
  /// previews here and commits once when the pointer lifts, since a commit
  /// persists and, on a track scope, re-projects the whole rig.
  int? _dragDecay;
  int? _dragScope;
  bool _draggingDecay = false;

  static int _percentOf(double fraction) => (fraction * 100).round();

  void _previewDecay(double fraction) {
    if (!_draggingDecay) {
      _dragScope = _scope;
      _draggingDecay = true;
    }
    setState(() => _dragDecay = _percentOf(fraction));
  }

  void _commitDecay(double fraction) {
    final sameScope = _draggingDecay && _dragScope == _scope;
    _draggingDecay = false;
    setState(() => _dragDecay = null);
    if (sameScope) _setDecay(_percentOf(fraction));
  }

  void _setOnce(bool? once) {
    if (!context.read<PlaybackOptionsCubit>().state.oneShotReady) return;
    final scope = _scope;
    if (scope == null) {
      unawaited(
        context.read<PlaybackOptionsCubit>().setDefaultOneShot(value: once!),
      );
    } else {
      context.read<LooperBloc>().add(
        LooperOneShotToggled(scope, oneShot: once),
      );
    }
  }

  void _setDecay(int? percent) {
    if (!context.read<PlaybackOptionsCubit>().state.decayReady) return;
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
    final count = context.select<LooperBloc, int>(
      (bloc) => bloc.state.tracks.length,
    );
    // Default and Custom membership come from the same confirmed owner.
    final defaults = context.watch<PlaybackOptionsCubit>().state;
    final scope = _scope;
    final trackOnce = defaults.trackOneShotOverrides[scope];
    final onceCustom = scope != null && trackOnce != null;
    final once = trackOnce ?? defaults.defaultOneShot;
    final trackDecay = defaults.trackOverdubDecayOverrides[scope];
    final decayCustom = scope != null && trackDecay != null;
    final decay =
        _dragDecay ??
        (scope == null
            ? defaults.overdubDecay
            : trackDecay ?? defaults.overdubDecay);
    const top = 342.0;
    return Positioned.fill(
      child: BlocListener<LooperBloc, LooperState>(
        listenWhen: (before, after) =>
            before.tracks.any((track) => track.isCapturing) !=
            after.tracks.any((track) => track.isCapturing),
        listener: (context, state) {
          LoopEditScope.maybeOf(context)?.cancel();
          setState(() {
            _dragDecay = null;
            _draggingDecay = false;
          });
        },
        child: Stack(
          children: [
            Positioned(
              left: 100,
              top: 124,
              child: LoopScopeSelector(
                trackNames: trackDisplayNames(context, count),
                selected: scope,
                onSelected: (channel) => setState(() {
                  _scope = channel;
                  _dragDecay = null;
                  _draggingDecay = false;
                }),
              ),
            ),
            // ---- playback
            Positioned(
              left: 100,
              top: top + 17,
              child: LoopFieldLabel(
                title: l10n.loopPlaybackLabel,
                fontSize: 32,
                origin: scopedOrigin(scoped: scope != null, custom: onceCustom),
              ),
            ),
            Positioned(
              left: 100 + 328,
              top: top,
              child: LoopChoiceRow<bool>(
                values: const [false, true],
                labelOf: (o) =>
                    o ? l10n.loopPlaybackOnce : l10n.loopPlaybackLoop,
                keyOf: (o) =>
                    Key(o ? 'loop_playback_once' : 'loop_playback_loop'),
                iconOf: (o) =>
                    o ? LucideIcons.arrowRightToLine : LucideIcons.repeat,
                selected: once,
                onSelected: _setOnce,
                enabled: defaults.oneShotReady,
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
                  onTap: defaults.oneShotReady ? () => _setOnce(null) : null,
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
                origin: scopedOrigin(
                  scoped: scope != null,
                  custom: decayCustom,
                ),
              ),
            ),
            Positioned(
              left: 100 + 328,
              top: top + 246 + 10,
              child: AppText(
                defaults.decayReady
                    ? overdubDecayReadout(l10n, decay)
                    : l10n.expressionUnavailable,
                key: const Key('loop_decay_readout'),
                style: TextStyle(
                  color: surface.textPrimary,
                  fontSize: 40,
                  height: 1,
                ),
              ),
            ),
            if (decayCustom && defaults.decayReady)
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
                enabled: defaults.decayReady,
                onChanged: _previewDecay,
                onChangeEnd: _commitDecay,
                onDoubleTap: () {
                  setState(() {
                    _dragDecay = null;
                    _draggingDecay = false;
                  });
                  _setDecay(scope == null ? 0 : null);
                },
                onEditCancel: (_) => setState(() {
                  _dragDecay = null;
                  _draggingDecay = false;
                }),
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
      ),
    );
  }
}
