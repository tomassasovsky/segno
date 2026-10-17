import 'dart:async';

import 'package:backing_repository/backing_repository.dart';
import 'package:bloc/bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:segno/backing/model/backing_mix.dart';
import 'package:segno/looper/application/backing_settings.dart';

part 'backing_mix_state.dart';

/// Presents the backing mix (level, pan, outputs, End) and the click pan
/// owners (#1200 Part 6) to Audio routing and the Mixer's `Backing & click`
/// dialog. It borrows the owners; closing it never closes them.
class BackingMixCubit extends Cubit<BackingMixState> {
  /// Follows [settings].
  BackingMixCubit({required BackingSettings settings})
    : _settings = settings,
      super(_read(settings)) {
    _subscriptions = [
      settings.mixOwner.changes.listen((_) => _sync()),
      settings.clickPanOwner.changes.listen((_) => _sync()),
    ];
  }

  final BackingSettings _settings;
  late final List<StreamSubscription<void>> _subscriptions;

  static BackingMixState _read(BackingSettings settings) => BackingMixState(
    mix: settings.mixOwner.live,
    mixReady: settings.mixOwner.ready,
    clickPan: settings.clickPanOwner.live,
    clickPanReady: settings.clickPanOwner.ready,
  );

  void _sync() {
    if (!isClosed) emit(_read(_settings));
  }

  /// Sets the backing gain, clamped to `0..2`.
  void setLevel(double level) =>
      unawaited(_settings.setLevel(level.clamp(0.0, 2.0)));

  /// Sets the backing balance, clamped to `-1..1`.
  void setPan(double pan) => unawaited(_settings.setPan(pan.clamp(-1.0, 1.0)));

  /// Sets the output channels the backing sounds on.
  void setOutput(int mask) => unawaited(_settings.setOutput(mask));

  /// Sets what happens at the loaded file's end.
  void setEnd(BackingEnd end) => unawaited(_settings.setEnd(end));

  /// Sets the click pan, clamped to `-1..1`.
  void setClickPan(double pan) =>
      unawaited(_settings.setClickPan(pan.clamp(-1.0, 1.0)));

  @override
  Future<void> close() async {
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    return super.close();
  }
}
