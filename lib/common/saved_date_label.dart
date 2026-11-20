import 'package:intl/intl.dart';
import 'package:material_ui/material_ui.dart';
import 'package:segno/l10n/l10n.dart';

/// The pen's saved-date label: `today 14:02`, `yesterday`, then `7 Sep`;
/// empty when the date is unknown. [now] is the clock (the wall clock when
/// omitted).
String savedDateLabel(BuildContext context, DateTime? at, {DateTime? now}) {
  if (at == null) return '';
  final l10n = context.l10n;
  final clock = now ?? DateTime.now();
  final today = DateTime(clock.year, clock.month, clock.day);
  final day = DateTime(at.year, at.month, at.day);
  if (day == today) {
    final hh = at.hour.toString().padLeft(2, '0');
    final mm = at.minute.toString().padLeft(2, '0');
    return l10n.sessionDateToday('$hh:$mm');
  }
  if (day == today.subtract(const Duration(days: 1))) {
    return l10n.sessionDateYesterday;
  }
  return DateFormat(
    'd MMM',
    Localizations.localeOf(context).toString(),
  ).format(at);
}
