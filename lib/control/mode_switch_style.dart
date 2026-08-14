/// How the pedal's MODE footswitch reaches the three interaction modes
/// (#632).
///
/// Detected APP-SIDE: the pedal firmware keeps sending the same
/// press/release events whichever style is chosen — only `ControlCubit`'s
/// interpretation of them changes. Per-rig, persisted by
/// `SettingsRepository.saveModeSwitchStyle` as this enum's [token].
enum ModeSwitchStyle {
  /// The original behaviour: a tap cycles Record → Mute → FX → Record, and a
  /// MODE hold arms/disarms performance recording (D-PEDAL). The default —
  /// existing rigs see no change until the setting is flipped.
  cycleThree,

  /// A tap cycles Record ↔ Mute only; a MODE hold enters FX, and a second
  /// hold (or a tap) returns to the mode FX was entered from. The MODE hold
  /// is re-purposed as the FX door, so performance recording keeps only its
  /// other surfaces (the toolbar and the keyboard's `A`).
  holdFx;

  /// The persisted token for this style. Derived from the member name, so a
  /// member rename changes what new saves write — [fromToken] must keep
  /// accepting every token older builds ever wrote.
  String get token => name;

  /// Parses a persisted [token] back to a style, defaulting to [cycleThree]:
  /// the unset (and pre-#632) behaviour, so an absent or unrecognised value
  /// reads as "nothing changed".
  static ModeSwitchStyle fromToken(String? token) => values.firstWhere(
    (style) => style.name == token,
    orElse: () => cycleThree,
  );
}
