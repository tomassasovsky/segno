import 'package:looper_repository/looper_repository.dart';
import 'package:segno/l10n/l10n.dart';

/// Fills [catalog], once, if nobody has looked yet.
///
/// Gated on whether a scan has ever COMPLETED — `cache.appVersion` is only
/// set by a finished harvest — rather than on whether it found anything.
/// Gating on `descriptors` rescans the filesystem on every open of the
/// default appliance, which has no plugins at all; gating on
/// `availablePlugins` also rescans a machine where every candidate file fails
/// to load.
///
/// A scan already in flight is JOINED, not skipped, whether or not one has
/// completed before: [PluginCatalog.scan] hands back the running future.
/// Returning early there leaves the caller subscribed to nothing while its
/// build already read `isScanning` and drew "Looking for plugins…" — stuck
/// that way for good. That is reachable on the rescan path as easily as on
/// the first scan, which is why the check is on BOTH conditions.
///
/// Shared by the two surfaces that can be the first to ask for plugins: the
/// add dialog, and the browse sheet, which the missing-plugin relink opens
/// directly. Cold, the sheet listed nothing and said so.
Future<void> scanPluginsIfCold(PluginCatalog catalog) async {
  if (catalog.cache.appVersion.isNotEmpty && !catalog.isScanning) return;
  await catalog.scan();
}

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
