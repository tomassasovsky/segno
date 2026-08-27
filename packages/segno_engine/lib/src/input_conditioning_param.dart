/// A tunable parameter of the per-input live conditioning stage.
///
/// Mirrors the native `le_cond_param` enum (`segno_engine_api.h`). Each value
/// is carried in its own REAL unit (Hz / dB / ms / ratio) — not a normalized
/// `0..1` — because conditioning is a fixed utility stage, not an `le_fx_type`
/// chain entry. The audio thread clamps every value on apply; see each member
/// for its range and default.
enum InputConditioningParam {
  /// High-pass cutoff in Hz (`0` turns the section off). Default `40`.
  hpfHz,

  /// Mains-hum base frequency in Hz — `50` or `60` (`0` turns the section
  /// off). Default `50`.
  humHz,

  /// Number of hum notches, including the base, `1..8`. Default `4`
  /// (50/100/150/200 Hz at a 50 Hz base).
  humHarmonics,

  /// Downward-expander threshold in dB. Default `-55`.
  expThresholdDb,

  /// Downward-expander ratio (`1:N`). Default `2.0`.
  expRatio,

  /// Downward-expander release in ms. Default `150` (attack is fixed, no
  /// lookahead).
  expReleaseMs;

  /// The native `le_cond_param` integer for this parameter.
  int get code => switch (this) {
    InputConditioningParam.hpfHz => 0,
    InputConditioningParam.humHz => 1,
    InputConditioningParam.humHarmonics => 2,
    InputConditioningParam.expThresholdDb => 3,
    InputConditioningParam.expRatio => 4,
    InputConditioningParam.expReleaseMs => 5,
  };

  /// Maps a native `le_cond_param` integer to an [InputConditioningParam].
  /// Unknown values map to [InputConditioningParam.hpfHz].
  static InputConditioningParam fromCode(int code) => switch (code) {
    0 => InputConditioningParam.hpfHz,
    1 => InputConditioningParam.humHz,
    2 => InputConditioningParam.humHarmonics,
    3 => InputConditioningParam.expThresholdDb,
    4 => InputConditioningParam.expRatio,
    5 => InputConditioningParam.expReleaseMs,
    _ => InputConditioningParam.hpfHz,
  };
}
