import 'dart:async';
import 'dart:typed_data';

import 'package:equatable/equatable.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/logging/app_log.dart';
import 'package:segno/visualizer/performance_readout.dart';
import 'package:segno/visualizer/waveform_window_service.dart';

/// Presentation facts supplied by the main screen, independent of its Cubits.
class WaveformDisplayContext extends Equatable {
  /// Creates a readout context for the selected track.
  const WaveformDisplayContext({
    required this.cursor,
    required this.name,
    required this.defaultName,
    required this.mode,
    required this.bank,
    required this.deviceLost,
    required this.goodbye,
    this.brightness = 1,
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

  /// Whether the selected interface is disconnected.
  final bool deviceLost;

  /// Current shutdown presentation.
  final ReadoutGoodbye goodbye;

  /// The software dim over the second screen's window (`1` = none).
  final double brightness;

  @override
  List<Object?> get props => [
    cursor,
    name,
    defaultName,
    mode,
    bank,
    deviceLost,
    goodbye,
    brightness,
  ];
}

/// An opening problem to present in the existing display settings/notice UI.
enum WaveformDisplayFailure {
  /// No secondary display is available.
  singleDisplay,

  /// The window did not acknowledge readiness.
  openFailed,
}

/// Owns second-window lifecycle and delivery, independently of widget rebuilds.
/// Waveform frames follow repository polls; a trailing gate retains the latest
/// discrete change. Readout retries use a timer without resampling playheads.
class WaveformDisplayController {
  /// Connects the live repository to its exclusively owned window channel.
  /// Await [close] before handing the injected service to another controller.
  WaveformDisplayController({
    required LooperRepository repository,
    required WaveformWindowService window,
    required WaveformDisplayContext context,
    this.openDelay = Duration.zero,
    int Function()? displayCount,
  }) : _repository = repository,
       _window = window,
       _context = context,
       _displayCount = displayCount {
    _window.onWindowReady = _onWindowReady;
  }

  /// Delay after preference restoration before opening a second OS window.
  final Duration openDelay;
  static const _frame = Duration(milliseconds: 33);
  final LooperRepository _repository;
  final WaveformWindowService _window;
  final int Function()? _displayCount;
  final _failures = StreamController<WaveformDisplayFailure>.broadcast();
  WaveformDisplayContext _context;
  StreamSubscription<LooperState>? _poll;
  Timer? _startup;
  Timer? _readoutTimer;
  Timer? _frameGate;
  LooperState? _pendingFrame;
  LooperState? _lastSentFrame;
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
  String _title = '';
  Future<void>? _transition;
  Future<void>? _closing;

  /// Opening failures; the controller never presents UI itself.
  Stream<WaveformDisplayFailure> get failures => _failures.stream;

  /// Begins after the persisted preference has been read.
  void start({required bool enabled, required String title}) {
    if (_closed || _started) return;
    _started = true;
    setEnabled(enabled: enabled, title: title);
    if (openDelay > Duration.zero) {
      _startup = Timer(openDelay, _begin);
    } else {
      _begin();
    }
  }

  void _begin() {
    if (_closed) return;
    _ready = true;
    _requestTransition();
  }

  /// Updates desired state or retries an unsuccessful opening.
  void setEnabled({required bool enabled, required String title}) {
    if (_closed) return;
    _enabled = enabled;
    _title = title;
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
        } else if ((_displayCount?.call() ?? 2) < 2) {
          _failures.add(WaveformDisplayFailure.singleDisplay);
        } else {
          var opened = false;
          try {
            opened = await _window.open(title: _title);
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
    _poll = _repository.looperState.listen(_requestFrame);
    _readoutTimer = Timer.periodic(_frame, (_) => _pushReadout());
    _onWindowReady();
  }

  /// Replaces presentation facts without touching the audio engine.
  void updateContext(WaveformDisplayContext context) {
    if (_closed || context == _context) return;
    final selectionChanged =
        context.cursor != _context.cursor || context.name != _context.name;
    _context = context;
    if (_running && selectionChanged) _requestFrame(_repository.lastState);
  }

  void _onWindowReady() {
    if (!_running || _closed) return;
    _lastReadout = null;
    _readoutRevision++;
    _requestFrame(_repository.lastState);
  }

  void _requestFrame(LooperState state) {
    if (!_running || _closed) return;
    if (_frameGate != null) {
      _pendingFrame = state;
      return;
    }
    _sendFrame(state);
  }

  void _sendFrame(LooperState state) {
    final delivery = _delivery;
    final cursor = _context.cursor;
    final name = _context.name;
    _lastSentFrame = state;
    _pendingFrame = null;
    _armFrameGate();
    final selected = _trackAt(state, cursor) ?? const Track();
    final samples = selected.hasContent
        ? _repository.readTrackWaveform(cursor)
        : Float32List(0);
    unawaited(
      _window.pushWaveform(samples, selected.progress, name).catchError((
        Object _,
      ) {
        if (!_running ||
            _closed ||
            delivery != _delivery ||
            cursor != _context.cursor ||
            name != _context.name ||
            !identical(_lastSentFrame, state)) {
          return;
        }
        _pendingFrame ??= state;
        _armFrameGate();
      }),
    );
  }

  void _armFrameGate() {
    _frameGate ??= Timer(_frame, () {
      _frameGate = null;
      final pending = _pendingFrame;
      if (pending != null && _running && !_closed) _sendFrame(pending);
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
    unawaited(_poll?.cancel());
    _poll = null;
    _pendingFrame = null;
    _lastSentFrame = null;
    _lastReadout = null;
  }

  /// Retires delivery before awaiting an opening already in progress.
  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    _closed = true;
    _startup?.cancel();
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
      deviceLost: _context.deviceLost,
      goodbye: _context.goodbye,
      brightness: _context.brightness,
    );
  }
}
