import 'dart:async';

import 'package:looper_repository/looper_repository.dart';
import 'package:segno/looper/application/settings_families.dart';
import 'package:segno/looper/application/settings_owner.dart';
import 'package:segno/looper/model/owned_setting.dart';
import 'package:segno/looper/model/record_timing.dart';
import 'package:settings_repository/settings_repository.dart';

/// Presents the Record timing owner: ControlCubit's port, the page's edits
/// and the [RecordTimingState] projection. The transaction is the owner's.
class RecordTimingSettings implements RecordTimingControl {
  /// Builds the owner over [repository] and [settings].
  RecordTimingSettings({
    required LooperRepository repository,
    required SettingsRepository settings,
  }) : owner = SettingsOwner(
         repository: repository,
         family: RecordTimingFamily(repository: repository, settings: settings),
       ) {
    _subscriptions = [
      repository.looperState.listen((_) => _sync()),
      owner.changes.listen((_) => _sync()),
    ];
  }

  /// The Record timing transaction.
  final SettingsOwner<RecordTimingVector, Object?> owner;

  /// The owners in the registry's fixed order.
  List<SettingsOwner<Object, Object?>> get owners => [owner];

  final _states = StreamController<RecordTimingState>.broadcast(sync: true);
  late final List<StreamSubscription<void>> _subscriptions;
  RecordTimingState _state = const RecordTimingState();
  Future<void>? _closeFuture;

  /// The last confirmed publication, including current edit availability.
  RecordTimingState get state => _state;

  /// Read-only publications for presentation.
  Stream<RecordTimingState> get stream => _states.stream;

  /// Restores the stored timing once.
  Future<void> load() => owner.load();

  void _sync() {
    if (_states.isClosed) return;
    final live = owner.live;
    final next = RecordTimingState(
      defaultTiming: live.defaultTiming,
      rememberedDivision: live.rememberedDivision,
      trackOverrides: live.trackOverrides,
      captureLocked: owner.captureLocked,
      recordTimingReady: owner.ready,
    );
    if (next == _state) return;
    _state = next;
    _states.add(next);
  }

  @override
  RecordTimingSnapshot? get recordTimingSnapshot => state.recordTimingSnapshot;

  @override
  RecordTimingSnapshot get durableRecordTimingSnapshot {
    final durable = owner.durable;
    return RecordTimingSnapshot(
      defaultTiming: durable.defaultTiming,
      rememberedDivision: durable.rememberedDivision,
      trackOverrides: durable.trackOverrides,
      captureLocked: owner.captureLocked,
    );
  }

  @override
  RecordTimingLifetime get recordTimingLifetime => owner.lifetime;

  @override
  int recordTimingRevision(RecordTimingAddress address) =>
      owner.revisionOf(address);

  @override
  Stream<({RecordTimingAddress address, RecordTiming? timing})>
  get ordinaryRecordTimingChanges => owner.ordinaryChanges.map((change) {
    final address = change.address! as RecordTimingAddress;
    return (address: address, timing: change.value.at(address));
  });

  /// [live] with [address] set to [timing]. A default without a gate takes
  /// the durable remembered division, so a released hold does not keep the
  /// held division.
  RecordTimingVector _with(
    RecordTimingVector live,
    RecordTimingAddress address,
    RecordTiming? timing,
  ) => address.channel == null && timing != null && !timing.quantize
      ? RecordTimingVector(
          defaultTiming: timing,
          rememberedDivision: owner.durable.rememberedDivision,
          trackOverrides: live.trackOverrides,
        )
      : live.withValue(address, timing);

  /// Changes the ordinary default.
  Future<RecordTimingOutcome> setTiming(RecordTiming timing) async => _convert(
    await owner.update(
      (live) => _with(live, const RecordTimingAddress.defaults(), timing),
      address: const RecordTimingAddress.defaults(),
      edit: const RecordTimingAddress.defaults(),
    ),
  );

  /// Toggles the gate while keeping the confirmed remembered division.
  Future<RecordTimingOutcome> setEnabled({required bool value}) async {
    await load();
    return setTiming(
      RecordTiming.of(quantize: value, division: state.rememberedDivision),
    );
  }

  @override
  Future<RecordTimingOutcome> setTrackTiming({
    required int channel,
    required RecordTiming? timing,
  }) async {
    final address = RecordTimingAddress.track(channel);
    return _convert(
      await owner.update(
        (live) => _with(live, address, timing),
        address: address,
        edit: address,
      ),
    );
  }

  @override
  Future<RecordTimingOutcome> setControllerTiming(
    RecordTimingAddress address,
    RecordTiming timing, {
    required RecordTimingLifetime lifetime,
    required int revision,
    RecordTiming? releasedTiming,
  }) async => _convert(
    await owner.updateController(
      (live) => _with(live, address, timing),
      address: address,
      edit: address,
      lifetime: lifetime,
      revision: revision,
      released: releasedTiming == null
          ? null
          : (held) => held.withValue(address, releasedTiming),
    ),
  );

  static RecordTimingOutcome _convert(SettingOutcome outcome) =>
      RecordTimingOutcome(
        RecordTimingStatus.values.byName(outcome.status.name),
        deferred: outcome.deferred,
        engineResult: outcome.engineResult,
        error: outcome.error,
      );

  /// Lets admitted work finish, then disposes the owner.
  Future<void> close() => _closeFuture ??= _close();

  Future<void> _close() async {
    await Future.wait([
      for (final subscription in _subscriptions) subscription.cancel(),
    ]);
    await owner.close();
    await _states.close();
  }
}
