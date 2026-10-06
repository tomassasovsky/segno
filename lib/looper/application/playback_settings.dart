import 'dart:async';

import 'package:looper_repository/looper_repository.dart';
import 'package:segno/looper/application/settings_families.dart';
import 'package:segno/looper/application/settings_owner.dart';
import 'package:segno/looper/model/one_shot.dart';
import 'package:segno/looper/model/overdub_decay.dart';
import 'package:segno/looper/model/playback_options.dart';
import 'package:settings_repository/settings_repository.dart';

/// Presents the Decay and Loop/Once owners in one [PlaybackOptions]. The
/// transactions are the owners'; this only builds them and projects them.
class PlaybackSettings {
  /// Builds both owners over [repository] and [settings].
  PlaybackSettings({
    required LooperRepository repository,
    required SettingsRepository settings,
  }) : decayOwner = SettingsOwner(
         repository: repository,
         family: DecayFamily(repository: repository, settings: settings),
       ),
       oneShotOwner = SettingsOwner(
         repository: repository,
         family: OneShotFamily(repository: repository, settings: settings),
       ) {
    _subscriptions = [
      repository.looperState.listen((_) => _sync()),
      for (final owner in owners) owner.changes.listen((_) => _sync()),
    ];
  }

  /// The overdub Decay transaction.
  final SettingsOwner<DecaySnapshot, int?> decayOwner;

  /// The Loop/Once transaction.
  final SettingsOwner<OneShotSnapshot, bool?> oneShotOwner;

  /// The owners in the registry's fixed order.
  List<SettingsOwner<Object, Object?>> get owners => [decayOwner, oneShotOwner];

  /// ControlCubit's Decay port over [decayOwner].
  late final decayControl = DecayOwnerControl(decayOwner);

  /// ControlCubit's Loop/Once port over [oneShotOwner].
  late final oneShotControl = OneShotOwnerControl(oneShotOwner);

  final _states = StreamController<PlaybackOptions>.broadcast(sync: true);
  late final List<StreamSubscription<void>> _subscriptions;
  PlaybackOptions _state = const PlaybackOptions();
  Future<void>? _loadFuture;
  Future<void>? _closeFuture;

  /// Current accepted settings and independent field readiness.
  PlaybackOptions get state => _state;

  /// Accepted settings and readiness changes for borrowed views.
  Stream<PlaybackOptions> get stream => _states.stream;

  /// Loads both owners independently.
  Future<void> load() => _loadFuture ??= Future.wait([
    for (final owner in owners) owner.load(),
  ]).then((_) {});

  void _sync() {
    if (_states.isClosed) return;
    final decay = decayOwner.live;
    final once = oneShotOwner.live;
    final next = PlaybackOptions(
      overdubDecay: decay.defaultPercent,
      trackOverdubDecayOverrides: decay.trackOverrides,
      decayReady: decayOwner.ready,
      defaultOneShot: once.defaultOneShot,
      trackOneShotOverrides: once.trackOverrides,
      oneShotReady: oneShotOwner.ready,
    );
    if (next == _state) return;
    _state = next;
    _states.add(next);
  }

  /// Lets admitted work finish, then disposes both owners.
  Future<void> close() => _closeFuture ??= _close();

  Future<void> _close() async {
    await Future.wait([
      for (final subscription in _subscriptions) subscription.cancel(),
    ]);
    await Future.wait([for (final owner in owners) owner.close()]);
    await _states.close();
  }
}
