import 'package:daw_export/daw_export.dart';
import 'package:flutter/material.dart';
import 'package:segno/common/console_surface.dart';
import 'package:segno/l10n/l10n.dart';

/// The per-track EXPORT card on the capture dialog (part 11), drawn to
/// `SESSION & CAPTURE / capture-saved`: a group label over a card of one row
/// per exported track — the track's name, whether it carried a live, editable
/// Segno VST3 device chain or bounced (wet) audio, and — only when it bounced
/// *because* effects existed but couldn't be honestly represented as one
/// (umbrella D-CHAIN-FALLBACK) — the specific reason. A track with no effects
/// at all gets no fallback callout; there's nothing to explain there
/// (matching [DawTrack.deviceChainFallbackReason]'s own contract: never set
/// for a channel with no effects at all).
///
/// Fed [DawTrack]s directly (the same list `daw_export`'s manifest reader
/// already produces) rather than a separate app-layer summary model — no new
/// `daw_export` API work was needed for this part.
class ExportDeviceChainSummary extends StatelessWidget {
  /// Creates an [ExportDeviceChainSummary] for [tracks].
  const ExportDeviceChainSummary({required this.tracks, super.key});

  /// One entry per exported track, in `daw_export`'s own order.
  final List<DawTrack> tracks;

  /// The user-facing reason text for [reason], or `null` for no callout — a
  /// small, exhaustive `switch` so a future fourth
  /// [DeviceChainFallbackReason] fails to compile here rather than silently
  /// showing no reason.
  static String? _reasonText(
    AppLocalizations l10n,
    DeviceChainFallbackReason? reason,
  ) => switch (reason) {
    null => null,
    DeviceChainFallbackReason.mixedLaneChains =>
      l10n.perfExportReasonMixedLanes,
    DeviceChainFallbackReason.thirdPartyPlugin =>
      l10n.perfExportReasonThirdPartyPlugin,
    DeviceChainFallbackReason.unrepresentedEffectType =>
      l10n.perfExportReasonUnrepresented,
  };

  @override
  Widget build(BuildContext context) {
    if (tracks.isEmpty) return const SizedBox.shrink();
    final l10n = context.l10n;
    return Column(
      key: const Key('exportSummary'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        ConsoleGroupLabel(l10n.perfExportSummaryTitle),
        const SizedBox(height: 10),
        ConsoleCard(
          children: [
            for (final (i, track) in tracks.indexed)
              _TrackExportRow(track: track, isLast: i == tracks.length - 1),
          ],
        ),
      ],
    );
  }
}

/// One track's 70px row: name, live-vs-bounced in the trailing state slot,
/// and (when applicable) the specific fallback reason as the subtitle.
class _TrackExportRow extends StatelessWidget {
  const _TrackExportRow({required this.track, required this.isLast});

  final DawTrack track;
  final bool isLast;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final chain = track.deviceChain;
    final isLive = chain != null && chain.isNotEmpty;
    return ConsoleRow(
      title: track.name,
      subtitle: ExportDeviceChainSummary._reasonText(
        l10n,
        track.deviceChainFallbackReason,
      ),
      state: isLive ? l10n.perfExportTrackLive : l10n.perfExportTrackBounced,
      showDisclosure: false,
      showDivider: !isLast,
    );
  }
}
