import 'dart:convert';

import 'package:instrument_repository/instrument_repository.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/looper/application/settings_owner.dart';
import 'package:segno/looper/model/owned_setting.dart';
import 'package:settings_repository/settings_repository.dart';

/// The instruments working copy (#1197) as an owned settings family: one
/// stored record, applied to the engine through [InstrumentRepository]
/// before it is confirmed. There is no controller value: live and durable
/// are always the same copy.
final class InstrumentsFamily
    implements SettingsFamily<InstrumentsWorkingCopy, String?> {
  /// Binds the family to [instruments] and [settings]' record.
  InstrumentsFamily({
    required InstrumentRepository instruments,
    required SettingsRepository settings,
  }) : _instruments = instruments,
       _settings = settings;

  final InstrumentRepository _instruments;
  final SettingsRepository _settings;
  InstrumentsWorkingCopy _value = const InstrumentsWorkingCopy();

  @override
  OwnedSetting get key => OwnedSetting.instruments;

  @override
  List<Object?> get addresses => const [null];

  @override
  bool validate(InstrumentsWorkingCopy value) => value.instruments.every(
    (i) => i.params.length == 3 && i.params.every((v) => v >= 0 && v <= 100),
  );

  /// The exact stored bytes, after checking they decode.
  @override
  Future<String?> readCheckpoint(Object? address) async {
    final record = await _settings.readInstrumentsCheckpoint();
    if (record != null) _decode(record);
    return record;
  }

  @override
  Future<void> writeCheckpoint(Object? address, String? checkpoint) =>
      _settings.restoreInstrumentsCheckpoint(checkpoint);

  /// The record for [durable]; [stored] when it already holds it, so an
  /// absent record is not written for an empty copy.
  @override
  String? checkpointOf(
    InstrumentsWorkingCopy durable,
    Object? address,
    String? stored,
  ) {
    final current = stored == null
        ? const InstrumentsWorkingCopy()
        : _decode(stored);
    return current == durable ? stored : jsonEncode(durable.toJson());
  }

  @override
  List<Object?> supersededBy(
    Object? address,
    InstrumentsWorkingCopy before,
    InstrumentsWorkingCopy after,
  ) => const [];

  @override
  InstrumentsWorkingCopy durableAfter(
    InstrumentsWorkingCopy durable,
    InstrumentsWorkingCopy written,
    Object? address,
  ) => written;

  /// An absent record is no instruments.
  @override
  InstrumentsWorkingCopy restoreValue(Map<Object?, String?> checkpoints) {
    final record = checkpoints[null];
    return record == null ? const InstrumentsWorkingCopy() : _decode(record);
  }

  /// An unreadable record cannot be trusted, so Retry stores no instruments
  /// (owner rule 5: uncertain state is dropped with the owner's notice).
  @override
  String? repair(Object? address) => null;

  @override
  InstrumentsWorkingCopy get live => _value;

  @override
  InstrumentsWorkingCopy get durable => _value;

  @override
  bool get captureLocked => false;

  @override
  bool get recoveryRequired => false;

  @override
  Stream<EngineResult> get failures => const Stream.empty();

  /// Drives the engine from [live]; a copy the repository refuses changes
  /// nothing, and the owner rolls the stored record back.
  @override
  EngineResult request(
    InstrumentsWorkingCopy live,
    InstrumentsWorkingCopy durable,
    Object? edit,
  ) {
    final result = _instruments.apply(live);
    if (result.isOk) _value = live;
    return result;
  }

  /// The repository retries what the engine cannot take yet, so an applied
  /// copy is final here.
  @override
  Future<EngineResult> settle() => Future.value(EngineResult.ok);

  @override
  EngineResult recover() => EngineResult.ok;

  /// No controller value: nothing to retire.
  @override
  void retireLive() {}

  static InstrumentsWorkingCopy _decode(String record) =>
      InstrumentsWorkingCopy.fromJson(
        jsonDecode(record) as Map<String, dynamic>,
      );
}
