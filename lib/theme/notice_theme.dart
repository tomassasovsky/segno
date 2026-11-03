import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';
import 'package:segno/theme/surface_theme.dart';

/// The sizes and type ramp of the app's notices (#1562): the message in the
/// top bar's centre, the message on a track's card, and the band on the
/// readout. Colours are not here: a notice takes them from its tone through
/// [SurfaceTheme] (`warning`, `warningTint`, `rec`, `recTint`, …), and its
/// gaps from `SpacingTheme`.
///
/// [barTitle] is the top bar's centre line, which the session name uses as
/// well, so a message that takes the name's place has the name's size and
/// sits on its baseline.
///
/// Read it with the [NoticeThemeX.noticeTheme] extension.
@immutable
class NoticeTheme extends ThemeExtension<NoticeTheme> {
  /// Creates a [NoticeTheme].
  const NoticeTheme({
    required this.barTitle,
    required this.barBody,
    required this.barAction,
    required this.barIconSize,
    required this.barActionHeight,
    required this.barActionRadius,
    required this.dotSize,
    required this.timeLineThickness,
    required this.ruleThickness,
    required this.edgeThickness,
    required this.inlineText,
    required this.trackOverline,
    required this.trackTitle,
    required this.trackBody,
    required this.readoutBandHeight,
    required this.readoutText,
    required this.readoutDotSize,
  });

  /// The top bar's centre line: the session name and every message shown in
  /// its place.
  final TextStyle barTitle;

  /// A message's second part, on the title's baseline.
  final TextStyle barBody;

  /// The label of a message's one action button.
  final TextStyle barAction;

  /// A message's icon: as tall as the title's line.
  final double barIconSize;

  /// The action button's height: the top bar's own control height.
  final double barActionHeight;

  /// The action button's corner: the top bar's controls' corner.
  final double barActionRadius;

  /// The must-act dot before the sentence.
  final double dotSize;

  /// The line on the bar's bottom edge that shows a message's time left.
  final double timeLineThickness;

  /// The rule under a bar that holds a must-act message.
  final double ruleThickness;

  /// The tone edge down the left of a notice that stands on a page.
  final double edgeThickness;

  /// A notice on a page: the sentence.
  final TextStyle inlineText;

  /// A track's message: the short cause over it, in the tone colour.
  final TextStyle trackOverline;

  /// A track's message.
  final TextStyle trackTitle;

  /// What to do about it, under the message.
  final TextStyle trackBody;

  /// The readout's band, in the readout's 1280 x 720 reference pixels: it
  /// fills the readout's top margin and no more.
  final double readoutBandHeight;

  /// The band's sentence, in reference pixels.
  final TextStyle readoutText;

  /// The band's dot, in reference pixels.
  final double readoutDotSize;

  /// The ramp every flavour shares.
  static const NoticeTheme standard = NoticeTheme(
    barTitle: TextStyle(
      fontFamily: SurfaceTheme.displayFont,
      fontSize: 30,
      fontWeight: FontWeight.w500,
      height: 1,
    ),
    barBody: TextStyle(
      fontFamily: SurfaceTheme.displayFont,
      fontSize: 24,
      height: 1,
    ),
    barAction: TextStyle(
      fontFamily: SurfaceTheme.displayFont,
      fontSize: 24,
      fontWeight: FontWeight.w500,
      height: 1,
    ),
    barIconSize: 30,
    barActionHeight: 60,
    barActionRadius: 10,
    dotSize: 10,
    timeLineThickness: 3,
    ruleThickness: 2,
    edgeThickness: 3,
    inlineText: TextStyle(
      fontFamily: SurfaceTheme.displayFont,
      fontSize: 24,
      height: 1.1,
    ),
    trackOverline: TextStyle(
      fontFamily: SurfaceTheme.monoFont,
      fontSize: 22,
      fontWeight: FontWeight.w600,
      letterSpacing: 4,
      height: 1,
    ),
    trackTitle: TextStyle(
      fontFamily: SurfaceTheme.displayFont,
      fontSize: 34,
      fontWeight: FontWeight.w600,
      height: 1.2,
    ),
    trackBody: TextStyle(
      fontFamily: SurfaceTheme.displayFont,
      fontSize: 26,
      height: 1.2,
    ),
    readoutBandHeight: 42,
    readoutText: TextStyle(
      fontFamily: SurfaceTheme.displayFont,
      fontSize: 21,
      fontWeight: FontWeight.w500,
      height: 1,
    ),
    readoutDotSize: 7,
  );

  @override
  NoticeTheme copyWith({
    TextStyle? barTitle,
    TextStyle? barBody,
    TextStyle? barAction,
    double? barIconSize,
    double? barActionHeight,
    double? barActionRadius,
    double? dotSize,
    double? timeLineThickness,
    double? ruleThickness,
    double? edgeThickness,
    TextStyle? inlineText,
    TextStyle? trackOverline,
    TextStyle? trackTitle,
    TextStyle? trackBody,
    double? readoutBandHeight,
    TextStyle? readoutText,
    double? readoutDotSize,
  }) => NoticeTheme(
    barTitle: barTitle ?? this.barTitle,
    barBody: barBody ?? this.barBody,
    barAction: barAction ?? this.barAction,
    barIconSize: barIconSize ?? this.barIconSize,
    barActionHeight: barActionHeight ?? this.barActionHeight,
    barActionRadius: barActionRadius ?? this.barActionRadius,
    dotSize: dotSize ?? this.dotSize,
    timeLineThickness: timeLineThickness ?? this.timeLineThickness,
    ruleThickness: ruleThickness ?? this.ruleThickness,
    edgeThickness: edgeThickness ?? this.edgeThickness,
    inlineText: inlineText ?? this.inlineText,
    trackOverline: trackOverline ?? this.trackOverline,
    trackTitle: trackTitle ?? this.trackTitle,
    trackBody: trackBody ?? this.trackBody,
    readoutBandHeight: readoutBandHeight ?? this.readoutBandHeight,
    readoutText: readoutText ?? this.readoutText,
    readoutDotSize: readoutDotSize ?? this.readoutDotSize,
  );

  @override
  NoticeTheme lerp(ThemeExtension<NoticeTheme>? other, double t) {
    if (other is! NoticeTheme) return this;
    double l(double a, double b) => lerpDouble(a, b, t) ?? a;
    TextStyle s(TextStyle a, TextStyle b) => TextStyle.lerp(a, b, t) ?? a;
    return NoticeTheme(
      barTitle: s(barTitle, other.barTitle),
      barBody: s(barBody, other.barBody),
      barAction: s(barAction, other.barAction),
      barIconSize: l(barIconSize, other.barIconSize),
      barActionHeight: l(barActionHeight, other.barActionHeight),
      barActionRadius: l(barActionRadius, other.barActionRadius),
      dotSize: l(dotSize, other.dotSize),
      timeLineThickness: l(timeLineThickness, other.timeLineThickness),
      ruleThickness: l(ruleThickness, other.ruleThickness),
      edgeThickness: l(edgeThickness, other.edgeThickness),
      inlineText: s(inlineText, other.inlineText),
      trackOverline: s(trackOverline, other.trackOverline),
      trackTitle: s(trackTitle, other.trackTitle),
      trackBody: s(trackBody, other.trackBody),
      readoutBandHeight: l(readoutBandHeight, other.readoutBandHeight),
      readoutText: s(readoutText, other.readoutText),
      readoutDotSize: l(readoutDotSize, other.readoutDotSize),
    );
  }
}

/// Ergonomic access to the [NoticeTheme] from a [BuildContext].
extension NoticeThemeX on BuildContext {
  /// The [NoticeTheme] for this context.
  NoticeTheme get noticeTheme => Theme.of(this).extension<NoticeTheme>()!;
}
