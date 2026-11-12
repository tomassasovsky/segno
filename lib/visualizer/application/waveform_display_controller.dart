import 'dart:async';
import 'dart:typed_data';

import 'package:equatable/equatable.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/appliance/power_off/power_step.dart';
import 'package:segno/logging/app_log.dart';
import 'package:segno/visualizer/performance_readout.dart';
import 'package:segno/visualizer/waveform_window_service.dart';

/// Presentation facts supplied by the main screen, independent of its Cubits.
class WaveformDisplayContext extends Equatable {
  /// Creates a readout context for the selected track.
  const new({
    required this.cursor,
    required this.name,
    required this.defaultName,
    required this.mode,
    required this.bank,
    required this.goodbye,
    this.notice,
    this.savingStep,
    this.savingProgress = 0,
    this.brightness = 1,
    this.loop = const ReadoutLoopSettings(),
    this.dimmed = false,
  });

  /// Selected track channel.
  final int cursor;

  /// Stored selected-track name.
  final String name;

  /// Whether the second screen should localize the default track name.
  final bool defaultName;

  /// Current pedal function token.
  final String mode;

  /// Visible pedal bank.
  final int bank;

  /// The main screen's message for the readout's band, or null.
  final ReadoutNotice? notice;

  /// Current power face.
  final ReadoutGoodbye goodbye;

  /// The save's current step while [goodbye] is saving.
  final PowerStep? savingStep;

  /// The share of the save's steps finished, `0..1`.
  final double savingProgress;

  /// The software dim over the second screen's window (`1` = none).
  final double brightness;

  /// The length and record timing of the next take, from their settings
  /// owners.
  final ReadoutLoopSettings loop;

  /// The console is idle-dimmed.
  final bool dimmed;

  @override
  List<Object?> get props => [
    cursor,
    name,
    defaultName,
    mode,
    bank,
    notice,
    goodbye,
    savingStep,
    savingProgress,
    brightness,
    loop,
    dimmed,
  ];
}

/// An opening problem to present in the existing display settings/notice UI.
enum WaveformDisplayFailure {
  /// The readout did not announce itself.
  openFailed,
}

/// Owns second-window lifecycle and delivery, independently of widget rebuilds.
/// Waveform frames follow the looper state and the playheads, at most one per
/// [_frame]; a trailing gate sends the latest change. Readout retries use a
/// timer without resampling playheads.
class WaveformDisplayController {
  /// Connects the live repository to its exclusively owned window channel.
  /// Await [close] before handing the injected service to another controller.
  new({
    required this._repository,
    required this._window,
    required this._context,
  }) {
    _window.onWindowReady = _onWindowReady;
  }

  static const _frame = Duration(milliseconds: 33);
  final LooperRepository _repository;
  final WaveformWindowService _window;
  final _failures = StreamController<WaveformDisplayFailure>.broadcast();
  WaveformDisplayContext _context;
  StreamSubscription<LooperState>? _states;
  StreamSubscription<Playhead>? _playheads;
  Timer? _readoutTimer;
  Timer? _frameGate;

  /// A change arrived while the gate was closed; the gate sends it.
  bool _framePending = false;

  /// Counts the frames sent, so a failed one retries only while it is the
  /// latest.
  int _frameCount = 0;

  /// The playhead position the latest frame carried.
  double? _sentProgress;
  (LooperState, WaveformDisplayContext)? _lastReadout;
  int _readoutRevision = 0;
  int _intent = 0;
  int _handledIntent = 0;
  int _delivery = 0;
  bool _started = false;
  bool _ready = false;
  bool _enabled = false;
  bool _running = false;
  bool _closed = false;
  Future<void>? _transition;
  Future<void>? _closing;

  /// Opening failures; the controller never presents UI itself.
  Stream<WaveformDisplayFailure> get failures => _failures.stream;

  /// Begins after the persisted preference has been read.
  void start({required bool enabled}) {
    if (_closed || _started) return;
    _started = true;
    setEnabled(enabled: enabled);
    _ready = true;
    _requestTransition();
  }

  /// Updates desired state or retries an unsuccessful opening.
  void setEnabled({required bool enabled}) {
    if (_closed) return;
    _enabled = enabled;
    _intent++;
    if (!enabled) _stopDelivery();
    if (_ready) _requestTransition();
  }

  void _requestTransition() {
    if (_transition != null || _closed) return;
    _transition = _syncWindow()
        .catchError((Object error, StackTrace stack) {
          AppLog.error(
            'waveform window transition failed',
            error: error,
            stack: stack,
          );
        })
        .whenComplete(() {
          _transition = null;
          if (!_closed && _handledIntent != _intent) _requestTransition();
        });
  }

  Future<void> _syncWindow() async {
    while (!_closed) {
      final intent = _intent;
      try {
        if (!_enabled) {
          await _window.close();
        } else {
          var opened = false;
          try {
            opened = await _window.open();
          } on Object {
            // Platform failure uses the same explicit retry as no readiness.
          }
          if (_closed || intent != _intent) {
            await _window.close();
          } else if (!opened) {
            _failures.add(WaveformDisplayFailure.openFailed);
          } else {
            _startDelivery();
          }
        }
      } finally {
        // A failed platform operation consumes only the intent it attempted.
        // A newer request may retry; this one must not retry itself forever.
        _handledIntent = intent;
      }
      if (intent == _intent) return;
    }
  }

  void _startDelivery() {
    if (_running) return;
    _running = true;
    _states = _repository.looperState.listen((_) => _requestFrame());
    // Only the selected track's playhead is drawn there; another track
    // moving changes nothing on that screen.
    _playheads = _repository.playheads.listen((playhead) {
      if (playhead.track(_context.cursor) != _sentProgress) _requestFrame();
    });
    _readoutTimer = Timer.periodic(_frame, (_) => _pushReadout());
    _onWindowReady();
  }

  /// Replaces presentation facts without touching the audio engine.
  void updateContext(WaveformDisplayContext context) {
    if (_closed || context == _context) return;
    final selectionChanged =
        context.cursor != _context.cursor || context.name != _context.name;
    _context = context;
    if (_running && selectionChanged) _requestFrame();
  }

  void _onWindowReady() {
    if (!_running || _closed) return;
    _lastReadout = null;
    _readoutRevision++;
    _requestFrame();
  }

  void _requestFrame() {
    if (!_running || _closed) return;
    if (_frameGate != null) {
      _framePending = true;
      return;
    }
    _sendFrame();
  }

  void _sendFrame() {
    final delivery = _delivery;
    final cursor = _context.cursor;
    final name = _context.name;
    final frame = ++_frameCount;
    _framePending = false;
    _armFrameGate();
    final selected = _trackAt(_repository.lastState, cursor) ?? const Track();
    final samples = selected.hasContent
        ? _repository.readTrackWaveform(cursor)
        : Float32List(0);
    final progress = _repository.playhead.track(cursor);
    _sentProgress = progress;
    unawaited(
      _window.pushWaveform(samples, progress, name).catchError((Object _) {
        if (!_running ||
            _closed ||
            delivery != _delivery ||
            cursor != _context.cursor ||
            name != _context.name ||
            frame != _frameCount) {
          return;
        }
        _framePending = true;
        _armFrameGate();
      }),
    );
  }

  void _armFrameGate() {
    _frameGate ??= Timer(_frame, () {
      _frameGate = null;
      if (_framePending && _running && !_closed) _sendFrame();
    });
  }

  void _pushReadout() {
    if (!_running || _closed) return;
    final state = _repository.lastState;
    final last = _lastReadout;
    if (last != null &&
        last.$2 == _context &&
        _sameReadoutFacts(state, last.$1, _context.cursor)) {
      return;
    }
    final revision = ++_readoutRevision;
    _lastReadout = (state, _context);
    unawaited(
      _window.pushReadout(_readoutOf(state)).catchError((Object _) {
        if (!_closed && _readoutRevision == revision) _lastReadout = null;
      }),
    );
  }

  void _stopDelivery() {
    _running = false;
    _delivery++;
    _readoutRevision++;
    _readoutTimer?.cancel();
    _readoutTimer = null;
    _frameGate?.cancel();
    _frameGate = null;
    unawaited(_states?.cancel());
    _states = null;
    unawaited(_playheads?.cancel());
    _playheads = null;
    _framePending = false;
    _sentProgress = null;
    _lastReadout = null;
  }

  /// Retires delivery before awaiting an opening already in progress.
  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    _closed = true;
    _stopDelivery();
    _window.onWindowReady = null;
    try {
      await _transition;
    } finally {
      try {
        await _window.close();
      } finally {
        await _failures.close();
      }
    }
  }

  static bool _sameReadoutFacts(LooperState a, LooperState b, int cursor) {
    if (identical(a, b)) return true;
    if (a.tempoFollow != b.tempoFollow) return false;
    final ta = a.transport;
    final tb = b.transport;
    if (ta.tempoBpm != tb.tempoBpm ||
        ta.tempoSource != tb.tempoSource ||
        ta.tsNum != tb.tsNum ||
        ta.tsDen != tb.tsDen ||
        ta.primaryTrack != tb.primaryTrack) {
      return false;
    }
    if (a.tracks.length != b.tracks.length) return false;
    final x = _trackAt(a, cursor);
    final y = _trackAt(b, cursor);
    if (x == null || y == null) return x == y;
    return x.state == y.state &&
        x.muted == y.muted &&
        x.wholeBars(transport: ta, sampleRate: a.status.sampleRate) ==
            y.wholeBars(transport: tb, sampleRate: b.status.sampleRate);
  }

  static Track? _trackAt(LooperState state, int channel) {
    for (final track in state.tracks) {
      if (track.channel == channel) return track;
    }
    return null;
  }

  PerformanceReadout _readoutOf(LooperState looper) {
    final transport = looper.transport;
    final track = _trackAt(looper, _context.cursor);
    return PerformanceReadout(
      selected: track == null
          ? null
          : ReadoutTrack(
              channel: track.channel,
              name: _context.name,
              defaultName: _context.defaultName,
              state: track.state.name,
              muted: track.muted,
              primary: track.channel == transport.primaryTrack,
              bars:
                  track.wholeBars(
                    transport: transport,
                    sampleRate: looper.status.sampleRate,
                  ) ??
                  0,
            ),
      tempoBpm: transport.tempoBpm,
      hasTempo: transport.tempoSource != TempoSource.none,
      tsNum: transport.tsNum,
      tsDen: transport.tsDen,
      mode: _context.mode,
      activeBank: _context.bank,
      notice: _context.notice,
      goodbye: _context.goodbye,
      savingStep: _context.savingStep,
      savingProgress: _context.savingProgress,
      brightness: _context.brightness,
      tempoFollow: looper.tempoFollow,
      clockOwnsTempo: transport.tempoSource == TempoSource.external,
      loop: _context.loop,
      dimmed: _context.dimmed,
    );
  }
}
