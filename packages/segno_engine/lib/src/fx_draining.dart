import 'package:meta/meta.dart';
import 'package:segno_engine/src/fx_recipe.dart';

/// The chain slots still running a tail after their switch went off
/// (#1733): a delay, echo, Mode delay or reverb keeps running until its
/// tail is quiet for its whole delay memory (the engine's
/// `le_fx_type_drains`), so it still costs the audio thread until then.
///
/// One mask per chain, bit `s` for slot `s`, the chain's entry `s`.
@immutable
final class FxDraining {
  /// Creates the masks, by owner, channel and lane (the lane is `0` for
  /// every owner but [FxOwner.lane]). Zero masks are dropped.
  new(Map<(FxOwner, int, int), int> masks)
    : _masks = Map.unmodifiable({
        for (final MapEntry(:key, :value) in masks.entries)
          if (value != 0) key: value,
      });

  const new _none() : _masks = const {};

  /// Nothing drains.
  static const FxDraining none = FxDraining._none();

  final Map<(FxOwner, int, int), int> _masks;

  /// The draining slots of [owner]'s chain [channel] (its [lane], for a
  /// lane), bit `s` for slot `s`; `0` when none drains.
  int mask(FxOwner owner, {int channel = 0, int lane = 0}) =>
      _masks[(owner, channel, owner == FxOwner.lane ? lane : 0)] ?? 0;

  /// Whether no slot drains anywhere.
  bool get isEmpty => _masks.isEmpty;

  /// Every chain with a slot draining, and its mask.
  Iterable<({FxOwner owner, int channel, int lane, int mask})> get chains =>
      _masks.entries.map(
        (entry) => (
          owner: entry.key.$1,
          channel: entry.key.$2,
          lane: entry.key.$3,
          mask: entry.value,
        ),
      );

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! FxDraining || other._masks.length != _masks.length) {
      return false;
    }
    for (final MapEntry(:key, :value) in _masks.entries) {
      if (other._masks[key] != value) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hashAllUnordered([
    for (final MapEntry(:key, :value) in _masks.entries)
      Object.hash(key, value),
  ]);

  @override
  String toString() => 'FxDraining($_masks)';
}
