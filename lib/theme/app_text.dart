import 'package:flutter/widgets.dart';
import 'package:segno/theme/text_metrics.dart';

/// App text with forced strut and a content-based optical nudge.
///
/// Prefer this over Flutter's [Text] for labels, chips, and icon rows. Ambient
/// [AppTextDefaults] still applies height behavior to Flutter [Text] inside
/// Material widgets; strut and the nudge require [AppText].
///
/// The nudge is [appTextOpticalOffsetFor] unless an [AppTextOptics] ancestor
/// forces one.
class AppText extends StatelessWidget {
  /// Creates an [AppText].
  const AppText(
    String this.data, {
    super.key,
    this.style,
    this.strutStyle,
    this.textAlign,
    this.textDirection,
    this.locale,
    this.softWrap,
    this.overflow,
    this.textScaler,
    this.maxLines,
    this.semanticsLabel,
    this.semanticsIdentifier,
    this.textWidthBasis,
    this.textHeightBehavior,
    this.selectionColor,
  }) : textSpan = null;

  /// Creates an [AppText] with an [InlineSpan].
  const AppText.rich(
    InlineSpan this.textSpan, {
    super.key,
    this.style,
    this.strutStyle,
    this.textAlign,
    this.textDirection,
    this.locale,
    this.softWrap,
    this.overflow,
    this.textScaler,
    this.maxLines,
    this.semanticsLabel,
    this.semanticsIdentifier,
    this.textWidthBasis,
    this.textHeightBehavior,
    this.selectionColor,
  }) : data = null;

  /// The text to display.
  final String? data;

  /// The text to display as an [InlineSpan].
  final InlineSpan? textSpan;

  /// Merged onto the ambient [DefaultTextStyle].
  final TextStyle? style;

  /// When null, a forced strut is derived from the effective style.
  final StrutStyle? strutStyle;

  /// Horizontal alignment.
  final TextAlign? textAlign;

  /// Text directionality.
  final TextDirection? textDirection;

  /// Locale for the text.
  final Locale? locale;

  /// Whether soft wrapping is enabled.
  final bool? softWrap;

  /// Overflow behavior.
  final TextOverflow? overflow;

  /// Text scaler.
  final TextScaler? textScaler;

  /// Max lines.
  final int? maxLines;

  /// Semantics label override.
  final String? semanticsLabel;

  /// Semantics identifier.
  final String? semanticsIdentifier;

  /// Width basis.
  final TextWidthBasis? textWidthBasis;

  /// When null, [kAppTextHeightBehavior] is used.
  final TextHeightBehavior? textHeightBehavior;

  /// Selection color.
  final Color? selectionColor;

  @override
  Widget build(BuildContext context) {
    // No synthesised strut. A forcing one CANCELS the very collapse this
    // widget exists for: `applyHeightToFirstAscent: false` trims the first
    // line's ascent, and then `forceStrutHeight: true` puts a full line box
    // back underneath it. Measured on the shipping Inter at 14/1.43 — plain
    // `Text` 20.0, `Text` + the height behaviour 17.0, and with the strut
    // 20.0 again. It also carries no `leadingDistribution`, so it reverted
    // `even` to `proportional` and undid `withAppTextMetrics` everywhere.
    //
    // A caller may still pass one; nothing is built here on their behalf.
    final resolvedStrut = strutStyle;
    final text = data != null
        ? Text(
            data!,
            style: style,
            strutStyle: resolvedStrut,
            textAlign: textAlign,
            textDirection: textDirection,
            locale: locale,
            softWrap: softWrap,
            overflow: overflow,
            textScaler: textScaler,
            maxLines: maxLines,
            semanticsLabel: semanticsLabel,
            semanticsIdentifier: semanticsIdentifier,
            textWidthBasis: textWidthBasis,
            textHeightBehavior: textHeightBehavior ?? kAppTextHeightBehavior,
            selectionColor: selectionColor,
          )
        : Text.rich(
            textSpan!,
            style: style,
            strutStyle: resolvedStrut,
            textAlign: textAlign,
            textDirection: textDirection,
            locale: locale,
            softWrap: softWrap,
            overflow: overflow,
            textScaler: textScaler,
            maxLines: maxLines,
            semanticsLabel: semanticsLabel,
            semanticsIdentifier: semanticsIdentifier,
            textWidthBasis: textWidthBasis,
            textHeightBehavior: textHeightBehavior ?? kAppTextHeightBehavior,
            selectionColor: selectionColor,
          );
    final plain = data ?? textSpan!.toPlainText();
    final offset =
        AppTextOptics.maybeOf(context) ?? appTextOpticalOffsetFor(plain);
    if (offset == Offset.zero) return text;
    return Transform.translate(offset: offset, child: text);
  }
}
