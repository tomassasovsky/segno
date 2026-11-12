import 'package:material_ui/material_ui.dart';
import 'package:segno/l10n/gen/app_localizations.dart';

export 'package:segno/l10n/gen/app_localizations.dart';
export 'package:segno/l10n/localized.dart';

/// The app's strings, and the Material, Cupertino and widgets libraries'
/// own strings from material_ui.
///
/// Use this, not `AppLocalizations.localizationsDelegates`: gen-l10n still
/// lists flutter_localizations' delegates there, which supply the SDK's
/// deprecated `MaterialLocalizations` type rather than the one material_ui's
/// widgets look up, so those widgets would fall back to English.
const appLocalizationsDelegates = <LocalizationsDelegate<dynamic>>[
  AppLocalizations.delegate,
  ...GlobalMaterialLocalizations.delegates,
];

extension AppLocalizationsX on BuildContext {
  AppLocalizations get l10n => AppLocalizations.of(this);
}
