import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:segno/common/console_surface.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/library/cubit/library_cubit.dart';
import 'package:segno/looper/view/loop_settings/loop_settings_widgets.dart';
import 'package:segno/session/session.dart';
import 'package:segno/theme/theme.dart';
import 'package:session_repository/session_repository.dart';

/// The preview card (pen 19/01 `session-preview`): the selected session's
/// name, tempo, signature and track count, one lane per recorded track, and
/// the footer with its effect count and `Return to tracks` or
/// `Open session`.
///
/// Selecting previews; only `Open session` loads, through
/// [SessionCubit.open].
class LibraryPreviewCard extends StatelessWidget {
  /// Creates the preview card.
  const LibraryPreviewCard({super.key});

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final library = context.watch<LibraryCubit>().state;
    final sessions = context.select<SessionCubit, List<SessionSummary>>(
      (c) => c.state.sessions,
    );
    // A selection the search or a folder chip hides is not previewed: the
    // card never describes a row the list does not show.
    final hidden =
        library.selectedId != null &&
        !library.filter(sessions).any((s) => s.id == library.selectedId);
    return DecoratedBox(
      key: const Key('library_preview'),
      decoration: BoxDecoration(
        color: surface.card,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: surface.borderSubtle),
      ),
      child: Padding(
        padding: const EdgeInsets.all(33),
        child: switch (library) {
          _ when hidden => const _PreviewNotice(
            _PreviewNoticeKind.nothingSelected,
          ),
          LibraryState(selectedId: null) => const _PreviewNotice(
            _PreviewNoticeKind.nothingSelected,
          ),
          LibraryState(:final previewError?) => _PreviewNotice(
            previewError == LibraryPreviewError.unsupportedVersion
                ? _PreviewNoticeKind.unsupportedVersion
                : _PreviewNoticeKind.unreadable,
          ),
          LibraryState(:final preview?) => LibraryPreviewBody(
            preview: preview,
          ),
          // The read is in flight; it takes a few milliseconds.
          _ => const SizedBox.shrink(),
        },
      ),
    );
  }
}

enum _PreviewNoticeKind { nothingSelected, unsupportedVersion, unreadable }

/// The card's single line when there is nothing to preview.
class _PreviewNotice extends StatelessWidget {
  const _PreviewNotice(this.kind);

  final _PreviewNoticeKind kind;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Center(
      child: AppText(
        switch (kind) {
          _PreviewNoticeKind.nothingSelected => l10n.libraryNoSelection,
          _PreviewNoticeKind.unsupportedVersion =>
            l10n.sessionErrorUnsupportedVersion,
          _PreviewNoticeKind.unreadable => l10n.libraryPreviewUnreadable,
        },
        key: Key('library_preview_${kind.name}'),
        textAlign: TextAlign.center,
        style: TextStyle(
          color: context.surface.textSecondary,
          fontSize: 23,
          height: 1.4,
        ),
      ),
    );
  }
}

/// A read preview: heading, musical facts, track lanes and footer.
class LibraryPreviewBody extends StatelessWidget {
  /// Creates the body for [preview].
  const LibraryPreviewBody({required this.preview, super.key});

  /// The selected session's facts.
  final SessionPreview preview;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final l10n = context.l10n;
    final summary = preview.summary;
    final facts = [
      if (summary.tempoBpm > 0) l10n.libraryTempo(_bpm(summary.tempoBpm)),
      '${summary.tsNum}/${summary.tsDen}',
      l10n.libraryTrackCount(preview.tracks.length),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: 64,
          child: Align(
            alignment: Alignment.centerLeft,
            child: AppText(
              summary.name,
              key: const Key('library_preview_name'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: surface.textPrimary,
                fontSize: 34,
                height: 1.2,
              ),
            ),
          ),
        ),
        const SizedBox(height: 24),
        SizedBox(
          height: 64,
          child: Row(
            key: const Key('library_preview_facts'),
            children: [
              for (final (i, fact) in facts.indexed) ...[
                if (i > 0) const SizedBox(width: 20),
                AppText(
                  fact,
                  style: TextStyle(
                    color: surface.textSecondary,
                    fontFamily: SurfaceTheme.monoFont,
                    fontSize: 21,
                    height: 1,
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 24),
        Expanded(child: LibraryPreviewTracks(preview: preview)),
        const SizedBox(height: 24),
        SizedBox(height: 76, child: LibraryPreviewFooter(preview: preview)),
      ],
    );
  }

  /// `84`, or `84.5` for a tempo with a fraction.
  static String _bpm(double bpm) => bpm == bpm.roundToDouble()
      ? bpm.round().toString()
      : bpm.toStringAsFixed(1);
}

/// The preview's track lanes, the last open refusal above them when it
/// concerns this session, or a line when the session holds no audio.
class LibraryPreviewTracks extends StatelessWidget {
  /// Creates the lanes for [preview].
  const LibraryPreviewTracks({required this.preview, super.key});

  /// The selected session's facts.
  final SessionPreview preview;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final session = context.watch<SessionCubit>().state;
    // An Open that was refused leaves the outgoing session current. Its
    // reason shows on the session that refused, whatever the reason, and on
    // no other session; a boot recovery has its own app-wide notice.
    final refusal =
        session.status != SessionStatus.failure ||
            session.failedSessionId != preview.summary.id
        ? null
        : switch (session.error) {
            SessionError.sampleRateMismatch => l10n.sessionErrorSampleRate,
            SessionError.unsupportedVersion =>
              l10n.sessionErrorUnsupportedVersion,
            SessionError.bootPersistence => null,
            _ => l10n.sessionErrorGeneric(session.errorMessage ?? ''),
          };
    final tracks = preview.tracks;
    final longest = tracks.fold(0, (m, t) => math.max(m, t.lengthFrames));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (refusal != null) ...[
          ConsoleBanner(
            key: const Key('library_open_refused'),
            message: refusal,
            tone: ConsoleBannerTone.failure,
          ),
          const SizedBox(height: 12),
        ],
        Expanded(
          child: tracks.isEmpty
              ? AppText(
                  l10n.libraryNoTracks,
                  key: const Key('library_preview_no_tracks'),
                  style: TextStyle(
                    color: context.surface.textSecondary,
                    fontSize: 22,
                    height: 1.4,
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.only(right: 10),
                  children: [
                    for (final (i, track) in tracks.indexed)
                      LibraryPreviewTrackRow(
                        key: Key('library_track_${track.channel}'),
                        track: track,
                        first: i == 0,
                        share: longest == 0 ? 0 : track.lengthFrames / longest,
                        sampleRate: preview.sampleRate,
                      ),
                  ],
                ),
        ),
      ],
    );
  }
}

/// One recorded track: `Track N`, its bars (or seconds without a tempo),
/// layers and effect count, and a lane whose clip is the track's share of
/// the longest track. No waveform until the peaks read exists (plan D11).
class LibraryPreviewTrackRow extends StatelessWidget {
  /// Creates the row for [track].
  const LibraryPreviewTrackRow({
    required this.track,
    required this.first,
    required this.share,
    required this.sampleRate,
    super.key,
  });

  /// The track's facts.
  final SessionPreviewTrack track;

  /// Whether this is the top row (no gap above it).
  final bool first;

  /// The clip's width as a fraction of the lane, `0..1`.
  final double share;

  /// The session's rate, for a length in seconds.
  final int sampleRate;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final l10n = context.l10n;
    final length = track.bars > 0
        ? (track.bars.toString(), l10n.stageBarsUnit(track.bars))
        : (
            sampleRate > 0
                ? (track.lengthFrames / sampleRate).toStringAsFixed(1)
                : '0',
            l10n.librarySecondsUnit,
          );
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: surface.line)),
      ),
      child: Padding(
        padding: EdgeInsets.only(top: first ? 8 : 20, bottom: 23),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              height: 31,
              child: Row(
                children: [
                  Expanded(
                    child: AppText(
                      l10n.libraryTrackName(track.channel + 1),
                      style: TextStyle(
                        color: surface.textPrimary,
                        fontSize: 25,
                        height: 1,
                      ),
                    ),
                  ),
                  _TrackFact(value: length.$1, unit: length.$2),
                  const SizedBox(width: 23),
                  _TrackFact(
                    value: track.layers.toString(),
                    unit: l10n.stageLayersUnit(track.layers),
                  ),
                  const SizedBox(width: 23),
                  _FxChip(count: track.fxCount),
                ],
              ),
            ),
            const SizedBox(height: 14),
            _Lane(share: share),
          ],
        ),
      ),
    );
  }
}

/// A figure and its unit: `2 bars`.
class _TrackFact extends StatelessWidget {
  const _TrackFact({required this.value, required this.unit});

  final String value;
  final String unit;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        AppText(
          value,
          style: TextStyle(
            color: surface.textPrimary,
            fontFamily: SurfaceTheme.monoFont,
            fontSize: 21,
            height: 1,
          ),
        ),
        const SizedBox(width: 12),
        AppText(
          unit,
          style: TextStyle(
            color: surface.textSecondary,
            fontSize: 20,
            height: 1,
          ),
        ),
      ],
    );
  }
}

/// The track's effect count, outlined: `FX 3`.
class _FxChip extends StatelessWidget {
  const _FxChip({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: surface.borderStrong),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: AppText(
          context.l10n.libraryTrackFx(count),
          style: TextStyle(
            color: surface.textSecondary,
            fontSize: 18,
            height: 1,
          ),
        ),
      ),
    );
  }
}

/// The 74-tall lane with the track's clip at its length share.
class _Lane extends StatelessWidget {
  const _Lane({required this.share});

  final double share;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return Container(
      height: 74,
      decoration: BoxDecoration(
        color: surface.background,
        borderRadius: BorderRadius.circular(4),
      ),
      alignment: Alignment.centerLeft,
      child: FractionallySizedBox(
        widthFactor: share.clamp(0, 1),
        heightFactor: 1,
        child: DecoratedBox(
          key: const Key('library_track_clip'),
          decoration: BoxDecoration(
            color: surface.accentSurface,
            border: Border.all(color: surface.accent),
          ),
        ),
      ),
    );
  }
}

/// The footer: the session's effect and backing counts, then `Return to
/// tracks` on the current session or `Open session` on any other.
class LibraryPreviewFooter extends StatelessWidget {
  /// Creates the footer for [preview].
  const LibraryPreviewFooter({required this.preview, super.key});

  /// The selected session's facts.
  final SessionPreview preview;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final l10n = context.l10n;
    final session = context.watch<SessionCubit>().state;
    final id = preview.summary.id;
    final isCurrent = id == session.currentSessionId;
    final busy = session.status == SessionStatus.working;
    return Row(
      children: [
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(top: 31),
            child: AppText(
              l10n.libraryFooterFacts(
                preview.fxCount,
                l10n.libraryBackingCount(preview.backingCount),
              ),
              key: const Key('library_preview_footer_facts'),
              style: TextStyle(
                color: surface.textSecondary,
                fontSize: 22,
                height: 1,
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: isCurrent
              ? LoopOutlinedButton(
                  key: const Key('library_return_to_tracks'),
                  width: 235,
                  tone: LoopButtonTone.accent,
                  label: l10n.libraryReturnToTracks,
                  onTap: () => Navigator.popUntil(
                    context,
                    (route) => route.isFirst,
                  ),
                )
              : Opacity(
                  // Inert while another session action runs, and drawn so.
                  opacity: busy ? surface.disabledOpacity : 1,
                  child: LoopOutlinedButton(
                    key: const Key('library_open_session'),
                    width: 208,
                    tone: LoopButtonTone.accent,
                    label: l10n.libraryOpenSession,
                    onTap: busy
                        ? null
                        : () =>
                              unawaited(context.read<SessionCubit>().open(id)),
                  ),
                ),
        ),
      ],
    );
  }
}
