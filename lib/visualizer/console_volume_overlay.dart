import 'dart:async';
import 'dart:math' as math;

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/view/signal_graph/signal_style.dart';
import 'package:segno/theme/theme.dart';
import 'package:segno/visualizer/performance_readout.dart';
import 'package:segno/visualizer/readout_control.dart';

/// Whether the input config panel renders the #697 conditioning stage (HPF,
/// HUM, EXPANDER, RESTORE). The pen (`STAGE / readout-volumes-input`) draws
/// the end state; the toggles arrive with #697 S6's wiring — until then the
/// section is compiled out rather than drawn dead, because a stage toggle
/// that does nothing is worse than none.
const kReadoutInputConditioning = false;

/// Which overlay screen is up; the readout face itself is the `null` page.
enum _OverlayPage { list, input, track }

/// The 7" readout's volume overlay (#698; entry, dismissal, and the fader
/// reset reworked in #707), drawn to the pen's `STAGE / readout-volumes`
/// (+ its `-input` / `-track` config panels).
///
/// The MIX pill on the readout face is the ONLY way in: [builder] receives
/// the open callback and wires it to the pill; the rest of the readout
/// glass is inert (its surfaces are reserved for future interactivity).
/// The list is a full-screen panel on the stage background (not a modal
/// over dimmed content: at 7" a modal frame wastes pixels): a pinned header
/// over a scrolling list of finger-scale volume rows — one per configured
/// input, one per live track — each with an 88-wide chevron zone opening
/// that element's own config panel.
///
/// Dismissal contract (`c/readout-volumes`, #707): the BACK chip or
/// [revertDelay] of inactivity — ONLY those two. Dead space is inert
/// everywhere in the overlay: an accidental background tap mid-mixing must
/// not eject the mixer, but it still counts as activity and re-arms the
/// timer. The timer steps one level at a time (panel → list → readout) — a
/// performance screen must never stay stuck on a menu.
///
/// Volume rows commit CONTINUOUSLY (a live mixer, not commit-on-release):
/// tap-or-drag on the fader capsule places the fader (the name and value
/// columns are deliberately inert — see [_RowFader]), updates the local
/// drawing immediately, and sends a [ReadoutControl] through [onControl]
/// throttled to one per [sendGap] with a trailing flush so the last
/// position always lands. A double tap on any fader resets it to unity
/// (0.0 dB) — one discrete commit, unthrottled (see [_RowFader]).
class ConsoleVolumeOverlay extends StatefulWidget {
  /// Creates a [ConsoleVolumeOverlay] over the readout face from [builder].
  const ConsoleVolumeOverlay({
    required this.readout,
    required this.onControl,
    required this.builder,
    super.key,
  });

  /// Live state pushed from the main window.
  final PerformanceReadout readout;

  /// Sends a control command back to the main window.
  final ValueChanged<ReadoutControl> onControl;

  /// Builds the readout face shown when no overlay page is up. The callback
  /// it receives opens the volume list; the face wires it to its MIX pill —
  /// the only affordance that opens the overlay (#707).
  final Widget Function(BuildContext context, VoidCallback openMixer) builder;

  /// Inactivity before the overlay steps back one level.
  static const revertDelay = Duration(seconds: 8);

  /// Minimum interval between channel sends while a fader drags (~30 Hz).
  static const sendGap = Duration(milliseconds: 33);

  /// How long a locally-placed fader outlives its last touch before the
  /// pushed snapshot wins again — covers the command's round trip without
  /// letting a dropped command lie forever.
  static const localHold = Duration(seconds: 1);

  @override
  State<ConsoleVolumeOverlay> createState() => _ConsoleVolumeOverlayState();
}

class _ConsoleVolumeOverlayState extends State<ConsoleVolumeOverlay> {
  _OverlayPage? _page;

  /// The config page's subject: [ReadoutInput.index] on the input page, the
  /// track channel on the track page.
  int _configIndex = 0;

  Timer? _revert;

  /// Local fader positions, keyed `'i$index'` / `'t$channel'`, each stamped
  /// with its last touch. During (and just after) a drag the local value
  /// draws instead of the pushed one: the pushed snapshot lags the command's
  /// round trip by a frame or two, and a fader that snaps back mid-drag
  /// reads as a broken fader.
  final _local = <String, ({double volume, DateTime at})>{};

  /// Non-null while inside the minimum send gap; [_queued] holds the value
  /// awaiting the trailing flush.
  Timer? _gap;
  ReadoutControl? _queued;

  @override
  void didUpdateWidget(ConsoleVolumeOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.readout == oldWidget.readout) return;
    // A fresh snapshot retires local overrides the engine has caught up
    // with (or that outlived their hold, or whose subject vanished).
    final now = DateTime.now();
    _local.removeWhere((key, entry) {
      final pushed = _pushedVolume(key);
      if (pushed == null) return true;
      return (entry.volume - pushed).abs() < 0.001 ||
          now.difference(entry.at) > ConsoleVolumeOverlay.localHold;
    });
    // A config page whose subject vanished from the snapshot (a shrunk
    // roster after a device change) transitions to the list FOR REAL — the
    // build-side guard alone would only borrow the list's DRAWING while
    // [_page] stayed on the panel: the revert would then spend a whole
    // extra 8 s cycle stepping panel → list first, and a roster that later
    // regrew past [_configIndex] would resurrect the dead panel as a ghost.
    final page = _page;
    final vanished = switch (page) {
      _OverlayPage.input => _inputOf(widget.readout, _configIndex) == null,
      _OverlayPage.track => _configIndex >= widget.readout.tracks.length,
      _ => false,
    };
    if (vanished) {
      _page = _OverlayPage.list;
      _armRevert();
    }
  }

  double? _pushedVolume(String key) {
    for (final input in widget.readout.inputs) {
      if (key == 'i${input.index}') return input.volume;
    }
    for (final (channel, track) in widget.readout.tracks.indexed) {
      if (key == 't$channel') return track.volume;
    }
    return null;
  }

  @override
  void dispose() {
    _revert?.cancel();
    // A teardown inside the send gap (window close, hot restart) must not
    // eat the drag's final position: flush the queued command before the
    // trailing timer dies with the widget.
    final queued = _queued;
    if (queued != null) {
      _queued = null;
      widget.onControl(queued);
    }
    _gap?.cancel();
    super.dispose();
  }

  /// How many pointers are currently down on the overlay. While any is, the
  /// inactivity revert is suppressed entirely: a motionless held finger is
  /// still an interaction, and reverting mid-gesture would unmount the row
  /// under an active drag.
  int _pointersDown = 0;

  void _pointerDown() {
    _pointersDown++;
    _revert?.cancel();
  }

  void _pointerUp() {
    if (_pointersDown > 0) _pointersDown--;
    if (_pointersDown == 0) _armRevert();
  }

  /// (Re-)arms the inactivity revert — called on every interaction. A no-op
  /// while a pointer is held down; the release re-arms.
  void _armRevert() {
    _revert?.cancel();
    if (_page == null || _pointersDown > 0) return;
    _revert = Timer(ConsoleVolumeOverlay.revertDelay, _stepBack);
  }

  /// One level back: panel → list, list → readout.
  void _stepBack() {
    if (!mounted) return;
    setState(
      () => _page = _page == _OverlayPage.list ? null : _OverlayPage.list,
    );
    _armRevert();
  }

  void _toReadout() {
    _revert?.cancel();
    setState(() => _page = null);
  }

  void _toList() => _open(_OverlayPage.list);

  void _open(_OverlayPage page, [int index = 0]) {
    setState(() {
      _page = page;
      _configIndex = index;
    });
    _armRevert();
  }

  /// Sends [control] now if the send window is open, else queues it for the
  /// trailing flush — at most one send per [ConsoleVolumeOverlay.sendGap],
  /// and the last value always lands.
  void _sendThrottled(ReadoutControl control) {
    if (_gap == null) {
      widget.onControl(control);
      _gap = Timer(ConsoleVolumeOverlay.sendGap, _onGapElapsed);
    } else {
      _queued = control;
    }
  }

  void _onGapElapsed() {
    _gap = null;
    final queued = _queued;
    _queued = null;
    if (queued != null && mounted) {
      widget.onControl(queued);
      _gap = Timer(ConsoleVolumeOverlay.sendGap, _onGapElapsed);
    }
  }

  void _setVolume(String key, String action, int index, double volume) {
    setState(() => _local[key] = (volume: volume, at: DateTime.now()));
    _sendThrottled(ReadoutControl(action: action, index: index, value: volume));
    _armRevert();
  }

  /// The faders' default: unity gain, 0.0 dB.
  static const _unityGain = 1.0;

  /// The double-tap reset (#707): places the fader at unity and commits it
  /// NOW, bypassing [_sendThrottled]. A discrete reset is self-limiting like
  /// a toggle, and the first tap of the pair has usually just opened the
  /// send gap — throttling here would queue the reset behind it. Clearing
  /// [_queued] keeps that first tap's placement from flushing AFTER the
  /// reset and undoing it. The local echo goes through the same [_local]
  /// hold as a drag, so a stale snapshot cannot snap the fader back.
  void _resetVolume(String key, String action, int index) {
    setState(() => _local[key] = (volume: _unityGain, at: DateTime.now()));
    _queued = null;
    widget.onControl(
      ReadoutControl(action: action, index: index, value: _unityGain),
    );
    _armRevert();
  }

  /// Discrete toggles send unthrottled: taps are self-limiting, and dropping
  /// one would drop a mute.
  void _sendToggle(String action, int index) {
    widget.onControl(ReadoutControl(action: action, index: index));
    _armRevert();
  }

  double _volumeOf(String key, double pushed) => _local[key]?.volume ?? pushed;

  @override
  Widget build(BuildContext context) {
    final page = _page;
    if (page == null) {
      // The face carries its own (single) way in — the MIX pill (#707); no
      // wrapper gesture, so the rest of the glass stays genuinely inert.
      return widget.builder(context, _toList);
    }
    final readout = widget.readout;
    // A config page whose subject vanished from the snapshot (a shrunk
    // roster after a device change) falls back to the list, not a ghost.
    final input = _inputOf(readout, _configIndex);
    final body = switch (page) {
      _OverlayPage.input when input != null => _InputConfigPage(
        input: input,
        overlay: this,
      ),
      _OverlayPage.track when _configIndex < readout.tracks.length =>
        _TrackConfigPage(
          channel: _configIndex,
          track: readout.tracks[_configIndex],
          overlay: this,
        ),
      _ => _VolumeListPage(readout: readout, overlay: this),
    };
    // Every pointer observes the revert timer, whichever widget claims the
    // gesture — translucent so it observes without competing. Down suppresses
    // the timer (a held finger is an interaction); release re-arms it.
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) => _pointerDown(),
      onPointerUp: (_) => _pointerUp(),
      onPointerCancel: (_) => _pointerUp(),
      child: body,
    );
  }

  static ReadoutInput? _inputOf(PerformanceReadout readout, int index) {
    for (final input in readout.inputs) {
      if (input.index == index) return input;
    }
    return null;
  }
}

/// The pen frame's size — the reference every dimension is drawn against;
/// the same proportional contract `ConsoleReadoutView` uses.
const _penSize = Size(1920, 1080);

/// Scaffolds one overlay page: the stage background and the pen's 32-inset
/// content. Dead space is deliberately INERT (#707): no tap target here, so
/// a stray background tap mid-mixing changes nothing — dismissal is the
/// BACK chip or the inactivity revert, and the page-level [Listener] still
/// sees the touch and re-arms the timer.
class _OverlayScaffold extends StatelessWidget {
  const _OverlayScaffold({required this.builder});

  final Widget Function(BuildContext context, double s) builder;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : _penSize.width;
        final height = constraints.maxHeight.isFinite
            ? constraints.maxHeight
            : _penSize.height;
        // Limiting-axis scale, as on the readout face: the pen's proportions
        // are the contract, not its pixels.
        final s = (width / _penSize.width < height / _penSize.height)
            ? width / _penSize.width
            : height / _penSize.height;
        return ColoredBox(
          key: const Key('volume_overlay_dead_space'),
          color: context.surface.background,
          child: Padding(
            padding: EdgeInsets.all(32 * s),
            child: builder(context, s),
          ),
        );
      },
    );
  }
}

/// The volume list: the pinned INPUTS header with the BACK TO STAGE chip,
/// then the scrolling rows — inputs, the TRACKS caption, one row per live
/// track.
class _VolumeListPage extends StatelessWidget {
  const _VolumeListPage({required this.readout, required this.overlay});

  final PerformanceReadout readout;
  final _ConsoleVolumeOverlayState overlay;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return _OverlayScaffold(
      builder: (context, s) {
        final rows = <Widget>[
          for (final input in readout.inputs)
            _VolumeRow(
              key: Key('volume_row_input_${input.index}'),
              s: s,
              name: input.name,
              secondaryTone: false,
              volume: overlay._volumeOf('i${input.index}', input.volume),
              onVolume: (v) => overlay._setVolume(
                'i${input.index}',
                ReadoutControl.inputVolume,
                input.index,
                v,
              ),
              onDefault: () => overlay._resetVolume(
                'i${input.index}',
                ReadoutControl.inputVolume,
                input.index,
              ),
              onConfig: () => overlay._open(_OverlayPage.input, input.index),
              configKey: Key('volume_row_config_input_${input.index}'),
            ),
          _Caption(l10n.readoutVolumesTracks, s: s),
          for (final (channel, track) in readout.tracks.indexed)
            _VolumeRow(
              key: Key('volume_row_track_$channel'),
              s: s,
              name: track.defaultName
                  ? l10n.defaultTrackName(channel + 1)
                  : track.name,
              secondaryTone: track.defaultName,
              volume: overlay._volumeOf('t$channel', track.volume),
              onVolume: (v) => overlay._setVolume(
                't$channel',
                ReadoutControl.trackVolume,
                channel,
                v,
              ),
              onDefault: () => overlay._resetVolume(
                't$channel',
                ReadoutControl.trackVolume,
                channel,
              ),
              onConfig: () => overlay._open(_OverlayPage.track, channel),
              configKey: Key('volume_row_config_track_$channel'),
            ),
        ];
        return Column(
          key: const Key('volume_overlay_list'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              height: 72 * s,
              child: Row(
                children: [
                  _Caption(l10n.readoutVolumesInputs, s: s),
                  const Spacer(),
                  _BackChip(
                    key: const Key('volume_overlay_back_to_stage'),
                    label: l10n.readoutVolumesBackToStage,
                    s: s,
                    onTap: overlay._toReadout,
                  ),
                ],
              ),
            ),
            SizedBox(height: 14 * s),
            Expanded(
              child: ListView.separated(
                padding: EdgeInsets.zero,
                itemCount: rows.length,
                itemBuilder: (context, index) => rows[index],
                separatorBuilder: (context, index) => SizedBox(height: 12 * s),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// An input's config panel (`STAGE / readout-volumes-input`): its volume,
/// the (flag-gated) conditioning stage, and the read-only listening-tracks
/// pills — routing is edited on the main screen.
class _InputConfigPage extends StatelessWidget {
  const _InputConfigPage({required this.input, required this.overlay});

  final ReadoutInput input;
  final _ConsoleVolumeOverlayState overlay;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return _OverlayScaffold(
      builder: (context, s) => Column(
        key: const Key('volume_overlay_input_config'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _ConfigHeader(
            kind: l10n.readoutVolumesInputKind,
            title: input.name,
            s: s,
            onBack: overlay._toList,
          ),
          SizedBox(height: 28 * s),
          _Caption(l10n.readoutVolumesVolume, s: s),
          SizedBox(height: 14 * s),
          SizedBox(
            height: 110 * s,
            child: _RowFader(
              key: const Key('volume_config_fader'),
              s: s,
              valueGap: 14 * s,
              valueWidth: 200 * s,
              volume: overlay._volumeOf('i${input.index}', input.volume),
              onVolume: (v) => overlay._setVolume(
                'i${input.index}',
                ReadoutControl.inputVolume,
                input.index,
                v,
              ),
              onDefault: () => overlay._resetVolume(
                'i${input.index}',
                ReadoutControl.inputVolume,
                input.index,
              ),
            ),
          ),
          if (kReadoutInputConditioning) ...[
            // The #697 conditioning stage, drawn in the pen but not wired
            // yet — see [kReadoutInputConditioning].
            SizedBox(height: 28 * s),
            _Caption(l10n.readoutVolumesConditioning, s: s),
            SizedBox(height: 14 * s),
            Row(
              children: [
                for (final label in [
                  l10n.readoutVolumesHpf,
                  l10n.readoutVolumesHum,
                  l10n.readoutVolumesExpander,
                  l10n.readoutVolumesRestore,
                ]) ...[
                  Expanded(
                    child: _BigToggle(label: label, on: false, s: s),
                  ),
                  if (label != l10n.readoutVolumesRestore)
                    SizedBox(width: 24 * s),
                ],
              ],
            ),
          ],
          if (input.listeningTracks.isNotEmpty) ...[
            SizedBox(height: 28 * s),
            _Caption(l10n.readoutVolumesListeningTracks, s: s),
            SizedBox(height: 14 * s),
            Row(
              children: [
                for (final name in input.listeningTracks) ...[
                  _Pill(label: name, s: s),
                  SizedBox(width: 16 * s),
                ],
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// A track's config panel (`STAGE / readout-volumes-track`): its volume,
/// MUTE and FX CHAIN toggles, and the read-only input-source pills — routing
/// is edited on the main screen.
class _TrackConfigPage extends StatelessWidget {
  const _TrackConfigPage({
    required this.channel,
    required this.track,
    required this.overlay,
  });

  final int channel;
  final ReadoutTrack track;
  final _ConsoleVolumeOverlayState overlay;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return _OverlayScaffold(
      builder: (context, s) => Column(
        key: const Key('volume_overlay_track_config'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _ConfigHeader(
            kind: l10n.readoutVolumesTrackKind,
            title: track.defaultName
                ? l10n.defaultTrackName(channel + 1)
                : track.name,
            s: s,
            onBack: overlay._toList,
          ),
          SizedBox(height: 28 * s),
          _Caption(l10n.readoutVolumesVolume, s: s),
          SizedBox(height: 14 * s),
          SizedBox(
            height: 110 * s,
            child: _RowFader(
              key: const Key('volume_config_fader'),
              s: s,
              valueGap: 14 * s,
              valueWidth: 200 * s,
              volume: overlay._volumeOf('t$channel', track.volume),
              onVolume: (v) => overlay._setVolume(
                't$channel',
                ReadoutControl.trackVolume,
                channel,
                v,
              ),
              onDefault: () => overlay._resetVolume(
                't$channel',
                ReadoutControl.trackVolume,
                channel,
              ),
            ),
          ),
          SizedBox(height: 28 * s),
          Row(
            children: [
              Expanded(
                child: _BigToggle(
                  key: const Key('volume_config_mute'),
                  label: l10n.readoutVolumesMute,
                  on: track.muted,
                  s: s,
                  onTap: () => overlay._sendToggle(
                    ReadoutControl.trackMuteToggle,
                    channel,
                  ),
                ),
              ),
              SizedBox(width: 24 * s),
              Expanded(
                child: _BigToggle(
                  key: const Key('volume_config_fx_chain'),
                  label: l10n.readoutVolumesFxChain,
                  on: track.chainEnabled,
                  s: s,
                  onTap: () => overlay._sendToggle(
                    ReadoutControl.trackChainToggle,
                    channel,
                  ),
                ),
              ),
            ],
          ),
          if (track.inputNames.isNotEmpty) ...[
            SizedBox(height: 28 * s),
            _Caption(l10n.readoutVolumesInputKind, s: s),
            SizedBox(height: 14 * s),
            Row(
              children: [
                for (final name in track.inputNames) ...[
                  _Pill(label: name, s: s),
                  SizedBox(width: 16 * s),
                ],
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// One finger-scale volume row: name column, fader, dB value, and the
/// 88-wide chevron zone that opens the element's config panel.
class _VolumeRow extends StatelessWidget {
  const _VolumeRow({
    required this.s,
    required this.name,
    required this.secondaryTone,
    required this.volume,
    required this.onVolume,
    required this.onDefault,
    required this.onConfig,
    required this.configKey,
    super.key,
  });

  final double s;
  final String name;

  /// The default-identity tone: an unnamed track's name renders in the
  /// secondary colour, the tone the tracks screen uses for a default name.
  final bool secondaryTone;

  final double volume;
  final ValueChanged<double> onVolume;
  final VoidCallback onDefault;
  final VoidCallback onConfig;
  final Key configKey;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return SizedBox(
      height: 110 * s,
      child: Row(
        children: [
          Expanded(
            child: _RowFader(
              s: s,
              leadingWidth: 300 * s,
              leadingGap: 28 * s,
              valueGap: 28 * s,
              valueWidth: 220 * s,
              volume: volume,
              onVolume: onVolume,
              onDefault: onDefault,
              leading: Align(
                alignment: Alignment.centerLeft,
                child: AppText(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: secondaryTone
                        ? surface.textSecondary
                        : surface.textPrimary,
                    fontSize: 42 * s,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.84 * s,
                    height: 1.2,
                    leadingDistribution: TextLeadingDistribution.even,
                  ),
                ),
              ),
            ),
          ),
          SizedBox(width: 28 * s),
          GestureDetector(
            key: configKey,
            behavior: HitTestBehavior.opaque,
            onTap: onConfig,
            child: SizedBox(
              width: 88 * s,
              child: Center(
                child: Icon(
                  Icons.chevron_right,
                  size: 44 * s,
                  color: surface.textMuted,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The fader strip: optional leading name column, the capsule track with its
/// accent fill and right-edge marker, and the signed-dB value.
///
/// The drag surface is the CAPSULE's horizontal span at the full row height
/// — deliberately NOT the whole row the pen note describes ("tap/drag
/// anywhere on the row"): with the name and value columns live, an
/// accidental label tap committed volume 0 (silencing a track
/// mid-performance) and a value tap committed max. Owner-directed deviation
/// for performance safety, since written back into `c/readout-volumes`. The
/// name and value columns absorb their taps inertly so a label touch
/// neither moves the fader nor reaches anything behind the row.
///
/// **Double tap = default** (#707): two clean taps in quick succession on
/// the capsule reset the fader to unity (0.0 dB) via `onDefault`. Detection
/// is manual, on the raw pointer stream — a [Listener] beside the existing
/// recognizers — because `GestureDetector.onDoubleTap` would put a
/// double-tap recognizer in the arena, and that recognizer HOLDS the arena
/// after every first tap: single taps and drag starts would wait out its
/// ~300 ms window, and the hard contract here is zero added latency on
/// singles. The observer costs nothing: a tap is down→up with < `_tapSlop`
/// movement in < `_maxTapDuration`; a second down within `_doubleTapWindow`
/// of the first's up fires the reset at the DOWN (snappiest honest moment)
/// and suppresses that gesture's own tap placement. Drag recognizers are
/// untouched, so a press that moves keeps placing from its first frame.
class _RowFader extends StatefulWidget {
  const _RowFader({
    required this.s,
    required this.volume,
    required this.onVolume,
    required this.onDefault,
    required this.valueGap,
    required this.valueWidth,
    this.leading,
    this.leadingWidth = 0,
    this.leadingGap = 0,
    super.key,
  });

  final double s;

  /// Linear gain `0..kSignalMaxGain`.
  final double volume;

  final ValueChanged<double> onVolume;

  /// Resets the fader to its default — the double-tap commit (#707).
  final VoidCallback onDefault;

  final Widget? leading;
  final double leadingWidth;
  final double leadingGap;
  final double valueGap;
  final double valueWidth;

  @override
  State<_RowFader> createState() => _RowFaderState();
}

class _RowFaderState extends State<_RowFader> {
  /// A press that travels farther than this is a drag, not a tap.
  static const _tapSlop = 12.0;

  /// A press held longer than this is a hold, not a tap.
  static const _maxTapDuration = Duration(milliseconds: 250);

  /// How soon after a clean tap's release the next down counts as the
  /// double tap.
  static const _doubleTapWindow = Duration(milliseconds: 300);

  /// When the last clean tap lifted; null when the last touch was anything
  /// else. `package:clock` so widget tests' fake clock drives the windows —
  /// test pointer events carry no usable timestamps.
  DateTime? _lastTapUp;

  /// The pointer being tracked. Bookkeeping is single-touch: a second
  /// simultaneous finger is never part of a tap pair.
  int? _pointer;

  DateTime _downAt = DateTime.fromMillisecondsSinceEpoch(0);
  Offset _downPosition = Offset.zero;
  bool _moved = false;

  /// True while the current gesture is the pair's second tap: the reset
  /// already fired at its down, so its own tap placement must not land on
  /// top. Drag callbacks stay live — a moving finger always wins.
  bool _resetTap = false;

  void _onPointerDown(PointerDownEvent event) {
    if (_pointer != null) {
      // A second finger mid-gesture: whatever this was, it is not a tap.
      _lastTapUp = null;
      return;
    }
    final now = clock.now();
    _resetTap =
        _lastTapUp != null && now.difference(_lastTapUp!) < _doubleTapWindow;
    _lastTapUp = null;
    _pointer = event.pointer;
    _downAt = now;
    _downPosition = event.position;
    _moved = false;
    if (_resetTap) widget.onDefault();
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (event.pointer != _pointer) return;
    if ((event.position - _downPosition).distance > _tapSlop) _moved = true;
  }

  void _onPointerUp(PointerUpEvent event) {
    if (event.pointer != _pointer) return;
    _pointer = null;
    final clean =
        !_moved &&
        !_resetTap &&
        clock.now().difference(_downAt) < _maxTapDuration;
    // The reset tap itself never opens the next window: a triple tap is
    // two fresh taps away from another reset, not one.
    _lastTapUp = clean ? clock.now() : null;
  }

  void _onPointerCancel(PointerCancelEvent event) {
    if (event.pointer != _pointer) return;
    _pointer = null;
    _lastTapUp = null;
  }

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final fraction = (widget.volume / kSignalMaxGain).clamp(0.0, 1.0);
    // The empty-tap absorber: the strip outside the capsule (name, value)
    // reacts to nothing — and, sitting outside the capsule's Listener, it
    // can never be part of a double tap. The capsule's own detector is
    // deeper, so it wins the arena over this one.
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {},
      child: Row(
        children: [
          if (widget.leading != null) ...[
            SizedBox(width: widget.leadingWidth, child: widget.leading),
            SizedBox(width: widget.leadingGap),
          ],
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final trackWidth = math.max(1, constraints.maxWidth);
                void place(Offset local) {
                  final f = (local.dx / trackWidth).clamp(0.0, 1.0);
                  widget.onVolume(f * kSignalMaxGain);
                }

                return Listener(
                  onPointerDown: _onPointerDown,
                  onPointerMove: _onPointerMove,
                  onPointerUp: _onPointerUp,
                  onPointerCancel: _onPointerCancel,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTapDown: (details) {
                      if (_resetTap) return;
                      place(details.localPosition);
                    },
                    onHorizontalDragStart: (details) =>
                        place(details.localPosition),
                    onHorizontalDragUpdate: (details) =>
                        place(details.localPosition),
                    child: Container(
                      clipBehavior: Clip.antiAlias,
                      decoration: BoxDecoration(
                        color: surface.surface,
                        borderRadius: BorderRadius.circular(14 * widget.s),
                        border: Border.all(color: surface.line),
                      ),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: FractionallySizedBox(
                          widthFactor: fraction,
                          heightFactor: 1,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: surface.accentSurface,
                              border: Border(
                                right: BorderSide(
                                  color: surface.accent,
                                  width: 4 * widget.s,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          SizedBox(width: widget.valueGap),
          SizedBox(
            width: widget.valueWidth,
            child: AppText(
              signalGainReadout(widget.volume),
              maxLines: 1,
              style: TextStyle(
                color: surface.textSecondary,
                fontSize: 40 * widget.s,
                height: 1.2,
                fontFeatures: const [FontFeature.tabularFigures()],
                leadingDistribution: TextLeadingDistribution.even,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A config panel's header: the kind caption over the stage-sized title,
/// with the BACK chip on the right.
class _ConfigHeader extends StatelessWidget {
  const _ConfigHeader({
    required this.kind,
    required this.title,
    required this.s,
    required this.onBack,
  });

  final String kind;
  final String title;
  final double s;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _Caption(kind, s: s),
              SizedBox(height: 8 * s),
              AppText(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: surface.textPrimary,
                  fontSize: 72 * s,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.44 * s,
                  height: 1,
                  leadingDistribution: TextLeadingDistribution.even,
                ),
              ),
            ],
          ),
        ),
        SizedBox(width: 28 * s),
        _BackChip(
          key: const Key('volume_overlay_back'),
          label: context.l10n.readoutVolumesBack,
          s: s,
          onTap: onBack,
        ),
      ],
    );
  }
}

/// A section caption in the pen's muted 36-tracking face.
class _Caption extends StatelessWidget {
  const _Caption(this.text, {required this.s});

  final String text;
  final double s;

  @override
  Widget build(BuildContext context) {
    return AppText(
      text,
      style: TextStyle(
        color: context.surface.textMuted,
        fontSize: 36 * s,
        letterSpacing: 2.52 * s,
        height: 1,
        leadingDistribution: TextLeadingDistribution.even,
      ),
    );
  }
}

/// The outlined pill that leaves an overlay screen — BACK TO STAGE on the
/// list, BACK on the config panels.
class _BackChip extends StatelessWidget {
  const _BackChip({
    required this.label,
    required this.s,
    required this.onTap,
    super.key,
  });

  final String label;
  final double s;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        height: 72 * s,
        padding: EdgeInsets.symmetric(horizontal: 32 * s),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: surface.borderStrong, width: 2 * s),
        ),
        child: AppText(
          label,
          style: TextStyle(
            color: surface.textSecondary,
            fontSize: 36 * s,
            fontWeight: FontWeight.w600,
            letterSpacing: 2.52 * s,
            height: 1,
            leadingDistribution: TextLeadingDistribution.even,
          ),
        ),
      ),
    );
  }
}

/// A 110-high stage toggle: accent surface and stroke when on, quiet surface
/// and muted label when off — the same on/off vocabulary on both panels.
class _BigToggle extends StatelessWidget {
  const _BigToggle({
    required this.label,
    required this.on,
    required this.s,
    this.onTap,
    super.key,
  });

  final String label;
  final bool on;
  final double s;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        height: 110 * s,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: on ? surface.accentSurface : surface.surface,
          borderRadius: BorderRadius.circular(14 * s),
          border: Border.all(
            color: on ? surface.accent : surface.line,
            width: 2 * s,
          ),
        ),
        child: AppText(
          label,
          style: TextStyle(
            color: on ? surface.textPrimary : surface.textMuted,
            fontSize: 40 * s,
            fontWeight: FontWeight.w700,
            letterSpacing: 2 * s,
            height: 1,
            leadingDistribution: TextLeadingDistribution.even,
          ),
        ),
      ),
    );
  }
}

/// A read-only routing pill — informational here; routing is edited on the
/// main screen.
class _Pill extends StatelessWidget {
  const _Pill({required this.label, required this.s});

  final String label;
  final double s;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return Container(
      height: 76 * s,
      padding: EdgeInsets.symmetric(horizontal: 32 * s),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: surface.control,
        borderRadius: BorderRadius.circular(999),
      ),
      child: AppText(
        label,
        style: TextStyle(
          color: surface.textSecondary,
          fontSize: 36 * s,
          fontWeight: FontWeight.w600,
          letterSpacing: 1 * s,
          height: 1,
          leadingDistribution: TextLeadingDistribution.even,
        ),
      ),
    );
  }
}
