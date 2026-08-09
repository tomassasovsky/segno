import 'package:segno/l10n/l10n.dart';

/// Why a hosted plugin is showing no controls.
///
/// Declared once because three surfaces say it: the placeholder card, the
/// summary chip's tooltip, and the Signal panel's editor block. The nesting
/// is the load-bearing part — the repository sets `unsupported` ALONGSIDE
/// `unavailable` rather than instead of it, so a caller testing `unavailable`
/// first would tell a bus-stage plugin it failed to load, and a plugin still
/// being scanned would read as a failure rather than as work in progress.
///
/// Lives in `fx_editor/` rather than beside the surface it was written for:
/// `signal_graph/` goes with #533's demolition and this outlives it.
String fxPluginPlaceholderReason(
  AppLocalizations l10n, {
  required bool loading,
  required bool unsupported,
}) {
  if (loading) return l10n.signalPluginLoading;
  return unsupported
      ? l10n.signalPluginUnsupported
      : l10n.signalPluginUnavailable;
}
