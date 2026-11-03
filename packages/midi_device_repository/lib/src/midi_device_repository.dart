import 'dart:async';

import 'package:controller_repository/controller_repository.dart';

import 'package:midi_client/midi_client.dart';
import 'package:midi_device_repository/src/models/midi_connection.dart';
import 'package:settings_repository/settings_repository.dart';

/// Owns the MIDI input devices and is the single source of MIDI-device truth
/// in the data layer.
///
/// Every plugged-in input is captured at once, one [MidiControllerSource]
/// (one native port) per device, so any connected controller can feed the
/// mappings learned from it; each message carries its device's capture
/// lifetime ([MidiInputSession]). Mappings name their device, so a keyboard's
/// messages never trigger a mapping learned from a foot controller.
///
/// The hotplug poll opens a device's capture when it appears, closes it when
/// it goes, and retries a port that would not open. The selection persists
/// only which controller the MIDI page shows. The projected [MidiConnection]
/// is published on [connections]; the raw input of every capture is
/// republished on [activity] and [messages].
///
/// Deliberately **independent of the audio engine**: it never touches
/// `LooperRepository`, so losing a MIDI device can never restart audio.
///
/// The `captures` factory creates one capture. It is `null` on a build with
/// no MIDI backend (or a test where the native library is absent), so the
/// page shows an empty state rather than crashing the app.
class MidiDeviceRepository {
  /// Creates a [MidiDeviceRepository] capturing through [captures], persisting
  /// the selection through [settings].
  ///
  /// [pollInterval] is the hotplug re-enumeration cadence; pass [Duration.zero]
  /// to disable the timer (tests drive [refresh] directly).
  MidiDeviceRepository({
    required MidiControllerSource Function()? captures,
    required SettingsRepository settings,
    Duration pollInterval = const Duration(seconds: 2),
  }) : _newCapture = captures,
       _settings = settings,
       // One never-opened source lists the host's inputs.
       _scanner = captures?.call() {
    // Capture what is plugged in now, so input works before the saved
    // selection loads (enumerate is a cheap synchronous native call).
    refresh();
    unawaited(_hydrate());
    if (_scanner != null && pollInterval > Duration.zero) {
      _pollTimer = Timer.periodic(pollInterval, (_) => refresh());
    }
  }

  final MidiControllerSource Function()? _newCapture;
  final MidiControllerSource? _scanner;
  final SettingsRepository _settings;
  final StreamController<MidiConnection> _controller =
      StreamController<MidiConnection>.broadcast();
  final _messages = StreamController<MidiInputMessage>.broadcast();
  final _activity = StreamController<void>.broadcast();

  /// One capture per device seen this run, kept across replugs so each open
  /// gets a new [MidiInputSession] epoch.
  final _sources = <String, MidiControllerSource>{};
  final _subscriptions = <StreamSubscription<Object?>>[];
  final _openErrors = <String, String>{};

  /// Devices present at the previous poll, or `null` before the first.
  Set<String>? _lastPresent;

  /// Devices that went absent this run, so their return is a restore.
  final _lost = <String>{};
  final _names = <String, String>{};
  Timer? _pollTimer;
  int _selectionGeneration = 0;
  bool _disposed = false;
  Future<void> _selectionTail = Future<void>.value();

  MidiConnection _connection = const MidiConnection();

  /// The open capture lifetime of each captured device. Consumers reject a
  /// message whose session is not the current one for its device.
  Map<String, MidiInputSession> get sessions => {
    for (final entry in _sources.entries) entry.key: ?entry.value.session,
  };

  /// Unmodified musical traffic from every capture; remote enable and Learn
  /// never gate this stream.
  Stream<MidiInputMessage> get messages => _messages.stream;

  /// The current connection, read synchronously.
  MidiConnection get connection => _connection;

  /// Stream of MIDI-input connection states.
  ///
  /// A new subscriber immediately receives the most recent connection before
  /// live updates, so a late listener — e.g. a cubit created after launch —
  /// shows the current devices instead of waiting for the next change.
  Stream<MidiConnection> get connections async* {
    yield _connection;
    yield* _controller.stream;
  }

  /// The raw (pre-mapping) MIDI activity of every capture, for a UI input
  /// indicator. Silent when no MIDI backend is present.
  Stream<void> get activity => _activity.stream;

  void _emit(MidiConnection next) {
    if (_disposed) return;
    _connection = next;
    if (!_controller.isClosed) _controller.add(next);
  }

  /// Loads the saved selection, tolerating a saved device that is absent (the
  /// page keeps showing it and its mappings).
  Future<void> _hydrate() async {
    final generation = _selectionGeneration;
    final ({String id, String name})? saved;
    try {
      saved = await _settings.loadMidiDevice();
    } on Object catch (error) {
      if (!_disposed && generation == _selectionGeneration) {
        _emit(_connection.copyWith(errorDetail: '$error', pinUncertain: true));
      }
      return;
    }
    if (_disposed || generation != _selectionGeneration || saved == null) {
      return;
    }
    if (_scanner == null) return;
    _emit(
      _connection.copyWith(selectedId: saved.id, selectedName: saved.name),
    );
  }

  /// Shows the device [id] on the MIDI page and persists the choice. Capture
  /// does not depend on it. A failed write reports an uncertain selection so
  /// the page can retry.
  Future<void> select(String id) {
    if (id.isEmpty || _scanner == null || _disposed) {
      return Future<void>.value();
    }
    if (id == _connection.selectedId && !_connection.pinUncertain) {
      return Future<void>.value();
    }
    final generation = ++_selectionGeneration;
    final name = _nameFor(id);
    _emit(_connection.copyWith(selectedId: id, selectedName: name));
    return _queueSelection(() async {
      if (_disposed || generation != _selectionGeneration) return;
      try {
        await _settings.saveMidiDevice(id: id, name: name);
      } on Object catch (error) {
        if (!_disposed && generation == _selectionGeneration) {
          _emit(
            _connection.copyWith(errorDetail: '$error', pinUncertain: true),
          );
        }
        rethrow;
      }
      if (_disposed || generation != _selectionGeneration) return;
      _emit(_connection.copyWith(clearError: true, pinUncertain: false));
    });
  }

  Future<void> _queueSelection(Future<void> Function() write) {
    final next = _selectionTail.then((_) => write());
    _selectionTail = next.catchError((Object _, StackTrace _) {});
    return next;
  }

  /// Re-enumerates the host's MIDI inputs and reconciles the captures: opens
  /// each device that appeared (or whose port would not open last time),
  /// closes each that vanished, and raises a transient lost/restored
  /// transition. Invoked by the hotplug poll timer; also callable directly.
  void refresh() {
    final scanner = _scanner;
    if (scanner == null || _disposed) return;
    final devices = scanner.enumerate();
    for (final device in devices) {
      _names[device.id] = device.name;
    }
    // A device with several ports lists one entry per port under one id;
    // its capture opens the first.
    final present = {for (final device in devices) device.id};
    for (final entry in _sources.entries) {
      if (!present.contains(entry.key) && entry.value.session != null) {
        // Invalidates already queued callbacks from this lifetime.
        entry.value.close();
      }
    }
    _openErrors.removeWhere((id, _) => !present.contains(id));
    for (final id in present) {
      final source = _sources[id] ?? _capture(id);
      if (source.session != null) continue;
      try {
        final code = source.open(id);
        if (code == 0) {
          _openErrors.remove(id);
        } else {
          _openErrors[id] = '$code';
        }
      } on Object catch (error) {
        // One device that cannot open never stops the others.
        _openErrors[id] = '$error';
      }
    }

    var next = _connection.copyWith(
      devices: devices,
      open: sessions.keys.toSet(),
      openErrors: Map.unmodifiable(_openErrors),
    );
    // A change with no prior sample is the initial reading, not a transition.
    final previous = _lastPresent;
    _lastPresent = present;
    if (previous != null) {
      final gone = previous.difference(present);
      final back = present.intersection(_lost).difference(previous);
      _lost
        ..addAll(gone)
        ..removeAll(back);
      final changed = gone.isNotEmpty ? gone.first : back.firstOrNull;
      if (changed != null) {
        next = next.copyWith(
          connectivity: gone.isNotEmpty
              ? MidiConnectivity.lost
              : MidiConnectivity.restored,
          connectivityDeviceId: changed,
          connectivityDeviceName: _names[changed] ?? changed,
        );
      }
    }
    _emit(next);
  }

  MidiControllerSource _capture(String id) {
    final source = _newCapture!();
    _sources[id] = source;
    _subscriptions
      ..add(source.messages.listen(_messages.add))
      ..add(source.activity.listen((_) => _activity.add(null)));
    return source;
  }

  /// The human-readable name for [id] from the current enumeration, falling
  /// back to the id itself when the device is not (yet) listed.
  String _nameFor(String id) => _names[id] ?? id;

  /// Releases the timer, every capture and the streams.
  Future<void> dispose() async {
    _disposed = true;
    ++_selectionGeneration;
    _pollTimer?.cancel();
    await _selectionTail;
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    for (final source in _sources.values) {
      await source.dispose();
    }
    await _scanner?.dispose();
    await _messages.close();
    await _activity.close();
    await _controller.close();
  }
}
