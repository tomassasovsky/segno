import 'package:segno/backing/application/backing_player.dart';
import 'package:segno/backing/model/backing_mix.dart';
import 'package:segno/looper/application/backing_settings.dart';
import 'package:session_repository/session_repository.dart';

/// The backing's share of a Session (#1200 Part 5, plan D9), as the Session
/// coordinator sees it: what Save captures, what Open installs, and the
/// stop Open and New Loop make.
class SessionBackingPort {
  /// Joins the [player] (prepared order and loaded item) and the [settings]
  /// owners (mix, End and click pan).
  const SessionBackingPort({
    required BackingPlayer player,
    required BackingSettings settings,
  }) : _player = player,
       _settings = settings;

  final BackingPlayer _player;
  final BackingSettings _settings;

  /// The durable setup a Save writes.
  SessionBacking get backing => _player.capture(_settings.mix);

  /// The durable click pan a Save writes.
  double get clickPan => _settings.clickPan;

  /// Stops the backing (Open and New Loop: plan D9, "prepared backing
  /// remains stopped").
  void stop() => _player.stop();

  /// Installs a recalled Session's setup inside the registry's Session
  /// exclusion: the mix and click pan through their owners, then the
  /// prepared order and the loaded item, loaded again stopped at 0.
  Future<void> install(SessionBacking backing, double clickPan) async {
    await _settings.installSession(
      BackingMix(
        level: backing.level,
        pan: backing.pan,
        outputMask: backing.outputMask,
        end: backing.endMode,
      ),
      clickPan,
    );
    await _player.recall(backing);
  }
}
