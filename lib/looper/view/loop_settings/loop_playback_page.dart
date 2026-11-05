import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/bloc/looper_bloc.dart';
import 'package:segno/looper/cubit/playback_options_cubit.dart';
import 'package:segno/looper/view/loop_settings/loop_edit_scope.dart';
import 'package:segno/looper/view/loop_settings/loop_settings_frame.dart';
import 'package:segno/looper/view/loop_settings/loop_settings_labels.dart';
import 'package:segno/looper/view/loop_settings/loop_settings_widgets.dart';
import 'package:segno/looper/view/loop_settings/loop_track_names.dart';
import 'package:segno/theme/theme.dart';

/// The Playback tab (#1659): everything a recorded loop does as it repeats.
///
/// The track selector, then for its scope: Loop/Once, the overdub decay
/// slider, and what happens when the tempo changes, Follow tempo and Pitch
/// side by side. Each field carries its origin tag and a Use default when a
/// track overrides it. A scope that keeps its recorded speed shows Pitch as
/// the readout it then is: the pitch stays the recorded one.
///
/// One lock rule: nothing here locks. Every field stays live during playback
/// and capture.
class LoopPlaybackPage extends StatefulWidget {
  /// Creates a [LoopPlaybackPage] showing [track]'s fields.
  const LoopPlaybackPage({
    required this.track,
    required this.onTrack,
    super.key,
  });

  /// The selected channel, or `null` for the defaults; shared with the
  /// Recording tab for the visit.
  final int? track;

  /// Selects a channel, or `null` for the defaults.
  final ValueChanged<int?> onTrack;

  /// The track selector, under the title row.
  static const double selectorTop = 124;

  /// The Loop/Once row.
  static const double playbackTop = selectorTop + 64 + 32;

  /// The Loop/Once row's height; its label is centred on it.
  static const double playbackHeight = 120;

  /// The decay readout; the slider and its notes follow.
  static const double decayTop = playbackTop + playbackHeight + 20 + 29 + 32;

  /// The decay slider.
  static const double sliderTop = decayTop + 74;

  /// The Follow tempo and Pitch headings, side by side.
  static const double tempoTop = decayTop + 198 + 29 + 32;

  /// The band each tempo heading is centred in: a Use default's height.
  static const double tempoLabelHeight = 64;

  /// The Follow tempo and Pitch choice rows.
  static const double tempoRowTop = tempoTop + tempoLabelHeight + 16;

  /// Their height, the Loop/Once row's.
  static const double tempoRowHeight = playbackHeight;

  @override
  State<LoopPlaybackPage> createState() => _LoopPlaybackPageState();
}

class _LoopPlaybackPageState extends State<LoopPlaybackPage> {
  /// Where the full-width fields' controls start, after their labels.
  static const double _controlsLeft = 328;

  /// The decay under the pointer while the slider is dragged; the drag
  /// previews here and commits once when the pointer lifts, since a commit
  /// persists and, on a track scope, re-projects the whole rig.
  int? _dragDecay;
  int? _dragScope;
  bool _draggingDecay = false;

  static int _percentOf(double fraction) => (fraction * 100).round();

  void _endDecayDrag() {
    _dragDecay = null;
    _draggingDecay = false;
  }

  void _selectTrack(int? channel) {
    setState(_endDecayDrag);
    widget.onTrack(channel);
  }

  void _previewDecay(double fraction) {
    if (!_draggingDecay) {
      _dragScope = widget.track;
      _draggingDecay = true;
    }
    setState(() => _dragDecay = _percentOf(fraction));
  }

  void _commitDecay(double fraction) {
    final sameScope = _draggingDecay && _dragScope == widget.track;
    _draggingDecay = false;
    setState(() => _dragDecay = null);
    if (sameScope) _setDecay(_percentOf(fraction));
  }

  void _setOnce(bool? once) {
    final cubit = context.read<PlaybackOptionsCubit>();
    if (!cubit.state.oneShotReady) return;
    final scope = widget.track;
    if (scope == null) {
      unawaited(cubit.setDefaultOneShot(value: once!));
    } else {
      unawaited(cubit.setTrackOneShot(channel: scope, oneShot: once));
    }
  }

  void _setDecay(int? percent) {
    final cubit = context.read<PlaybackOptionsCubit>();
    if (!cubit.state.decayReady) return;
    final scope = widget.track;
    if (scope == null) {
      unawaited(cubit.setOverdubDecay(percent ?? 0));
    } else {
      unawaited(cubit.setTrackOverdubDecay(channel: scope, percent: percent));
    }
  }

  void _setFollow(bool? follow) {
    final cubit = context.read<PlaybackOptionsCubit>();
    if (cubit.state.followTempo == null) return;
    unawaited(cubit.setFollowTempo(channel: widget.track, follow: follow));
  }

  void _setPitch(PitchMode? mode) {
    final cubit = context.read<PlaybackOptionsCubit>();
    if (cubit.state.pitchMode == null) return;
    unawaited(cubit.setPitchMode(channel: widget.track, mode: mode));
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
    final scope = widget.track;
    final trackOnce = options.trackOneShotOverrides[scope];
    final onceCustom = scope != null && trackOnce != null;
    final once = trackOnce ?? options.defaultOneShot;
    final trackDecay = options.trackOverdubDecayOverrides[scope];
    final decayCustom = scope != null && trackDecay != null;
    final decay =
        _dragDecay ??
        (scope == null
            ? options.overdubDecay
            : trackDecay ?? options.overdubDecay);
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
    final width = LoopSettingsFrame.contentWidthOf(context);
    final half = LoopSettingsFrame.halfWidthOf(context);
    final pitchLeft = width - half;
    const playbackTop = LoopPlaybackPage.playbackTop;
    const decayTop = LoopPlaybackPage.decayTop;
    const sliderTop = LoopPlaybackPage.sliderTop;
    const tempoTop = LoopPlaybackPage.tempoTop;
    const tempoRowTop = LoopPlaybackPage.tempoRowTop;
    const rowHeight = LoopPlaybackPage.tempoRowHeight;
    // The band the decay label is centred in: tall enough for the heading
    // on two lines and its origin tag.
    const decayLabelBand = 112.0;
    // A label wraps short of the controls rather than running under them
    // (the Spanish decay heading is wider than the column).
    final labelWidth = _controlsLeft - context.spacing.xl;
    return Positioned.fill(
      child: BlocListener<LooperBloc, LooperState>(
        listenWhen: (before, after) =>
            before.tracks.any((track) => track.isCapturing) !=
            after.tracks.any((track) => track.isCapturing),
        listener: (context, state) {
          LoopEditScope.maybeOf(context)?.cancel();
          setState(_endDecayDrag);
        },
        child: Stack(
          children: [
            Positioned(
              left: 0,
              top: LoopPlaybackPage.selectorTop,
              child: LoopScopeSelector(
                trackNames: trackDisplayNames(context, count),
                selected: scope,
                onSelected: _selectTrack,
              ),
            ),
            // ---- playback: the label is centred on the Loop/Once row.
            Positioned(
              left: 0,
              top: playbackTop,
              width: labelWidth,
              height: LoopPlaybackPage.playbackHeight,
              child: Align(
                alignment: Alignment.centerLeft,
                child: LoopFieldLabel(
                  title: l10n.loopPlaybackLabel,
                  fontSize: 32,
                  origin: scopedOrigin(
                    scoped: scope != null,
                    custom: onceCustom,
                  ),
                ),
              ),
            ),
            Positioned(
              left: _controlsLeft,
              top: playbackTop,
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
                enabled: options.oneShotReady,
                width: 584,
                height: LoopPlaybackPage.playbackHeight,
                fontSize: 28,
              ),
            ),
            if (onceCustom)
              Positioned(
                right: 0,
                top: playbackTop + 28,
                child: LoopUseDefaultButton(
                  key: const Key('loop_playback_use_default'),
                  onTap: options.oneShotReady ? () => _setOnce(null) : null,
                ),
              ),
            Positioned(
              left: _controlsLeft,
              top: playbackTop + LoopPlaybackPage.playbackHeight + 20,
              child: LoopNote(
                once ? l10n.loopPlaybackNoteOnce : l10n.loopPlaybackNoteLoop,
                key: const Key('loop_playback_note'),
              ),
            ),
            // ---- overdub decay: the label is centred on the slider.
            Positioned(
              left: 0,
              top: sliderTop + LoopSlider.height / 2 - decayLabelBand / 2,
              width: labelWidth,
              height: decayLabelBand,
              child: Align(
                alignment: Alignment.centerLeft,
                child: LoopFieldLabel(
                  title: l10n.loopDecayLabel,
                  fontSize: 32,
                  origin: scopedOrigin(
                    scoped: scope != null,
                    custom: decayCustom,
                  ),
                ),
              ),
            ),
            Positioned(
              left: _controlsLeft,
              top: decayTop,
              child: AppText(
                options.decayReady
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
            if (decayCustom && options.decayReady)
              Positioned(
                right: 0,
                top: decayTop - 10,
                child: LoopUseDefaultButton(
                  key: const Key('loop_decay_use_default'),
                  onTap: () => _setDecay(null),
                ),
              ),
            Positioned(
              left: _controlsLeft,
              top: sliderTop,
              child: LoopSlider(
                key: const Key('loop_decay_slider'),
                value: decay / 100,
                enabled: options.decayReady,
                onChanged: _previewDecay,
                onChangeEnd: _commitDecay,
                onDoubleTap: () {
                  setState(_endDecayDrag);
                  _setDecay(scope == null ? 0 : null);
                },
                onEditCancel: (_) => setState(_endDecayDrag),
                width: width - _controlsLeft,
                semanticLabel: l10n.loopDecaySliderLabel,
              ),
            ),
            Positioned(
              left: _controlsLeft,
              top: decayTop + 150,
              child: SizedBox(
                width: width - _controlsLeft,
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
              left: _controlsLeft,
              top: decayTop + 198,
              child: LoopNote(
                overdubDecayNote(l10n, decay),
                key: const Key('loop_decay_note'),
              ),
            ),
            // ---- when the tempo changes: Follow tempo and Pitch, side by
            // side, each heading over its row with Use default at its end.
            Positioned(
              left: 0,
              top: tempoTop,
              width: half,
              height: LoopPlaybackPage.tempoLabelHeight,
              child: Align(
                alignment: Alignment.centerLeft,
                child: LoopFieldLabel(
                  title: l10n.loopAudioFollowLabel,
                  fontSize: 32,
                  originBeside: true,
                  origin: scopedOrigin(
                    scoped: scope != null,
                    custom: followCustom,
                  ),
                ),
              ),
            ),
            if (followCustom)
              Positioned(
                right: width - half,
                top: tempoTop,
                child: LoopUseDefaultButton(
                  key: const Key('loop_audio_follow_use_default'),
                  onTap: follow != null ? () => _setFollow(null) : null,
                ),
              ),
            Positioned(
              left: 0,
              top: tempoRowTop,
              child: LoopChoiceRow<bool>(
                values: const [false, true],
                labelOf: (on) =>
                    on ? l10n.loopAudioFollowOn : l10n.loopAudioFollowOff,
                keyOf: (on) =>
                    Key(on ? 'loop_audio_follow_on' : 'loop_audio_follow_off'),
                iconOf: (on) => on ? LucideIcons.timer : LucideIcons.timerOff,
                selected: follows,
                enabled: follow != null,
                onSelected: _setFollow,
                width: half,
                height: rowHeight,
                fontSize: 28,
              ),
            ),
            Positioned(
              left: 0,
              top: tempoRowTop + rowHeight + 20,
              width: half,
              child: LoopNote(
                follows ? l10n.loopAudioNoteOn : l10n.loopAudioNoteOff,
                key: const Key('loop_audio_follow_note'),
              ),
            ),
            // ---- pitch
            Positioned(
              left: pitchLeft,
              top: tempoTop,
              width: half,
              height: LoopPlaybackPage.tempoLabelHeight,
              child: Align(
                alignment: Alignment.centerLeft,
                child: LoopFieldLabel(
                  title: l10n.loopAudioPitchLabel,
                  fontSize: 32,
                  originBeside: true,
                  origin: follows
                      ? scopedOrigin(scoped: scope != null, custom: pitchCustom)
                      : null,
                ),
              ),
            ),
            if (follows) ...[
              if (pitchCustom)
                Positioned(
                  right: 0,
                  top: tempoTop,
                  child: LoopUseDefaultButton(
                    key: const Key('loop_audio_pitch_use_default'),
                    onTap: pitch != null ? () => _setPitch(null) : null,
                  ),
                ),
              Positioned(
                left: pitchLeft,
                top: tempoRowTop,
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
                  iconOf: (m) => m == PitchMode.unchanged
                      ? LucideIcons.music
                      : LucideIcons.audioLines,
                  selected: mode,
                  enabled: pitch != null,
                  onSelected: _setPitch,
                  width: half,
                  height: rowHeight,
                  fontSize: 28,
                ),
              ),
            ] else
              // Keeping the recorded speed keeps the recorded pitch: a
              // readout (the pen's 06 / Keep recorded speed), not a choice.
              Positioned(
                left: pitchLeft,
                top: tempoRowTop,
                height: rowHeight,
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Row(
                    key: const Key('loop_audio_pitch_readout'),
                    children: [
                      Icon(
                        LucideIcons.music,
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
              ),
            Positioned(
              left: pitchLeft,
              top: tempoRowTop + rowHeight + 20,
              width: half,
              child: LoopNote(
                !follows
                    ? l10n.loopAudioNotePitchUnchanged
                    : mode == PitchMode.unchanged
                    ? l10n.loopAudioNotePitchKept
                    : l10n.loopAudioNotePitchFollows,
                key: const Key('loop_audio_pitch_note'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
