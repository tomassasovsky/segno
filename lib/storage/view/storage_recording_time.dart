import 'package:flutter/material.dart';
import 'package:segno/theme/theme.dart';

/// How much recording Internal still holds (pen 31 `storage-recording-time`):
/// the estimate, the format it is made at, and the reserve behind it.
///
/// Stepped in from the cards' edges, as the pen draws it: it belongs to the
/// Internal card above it rather than being a volume of its own.
class StorageRecordingTime extends StatelessWidget {
  /// Creates a [StorageRecordingTime].
  const StorageRecordingTime({
    required this.headline,
    required this.note,
    this.format,
    super.key,
  });

  /// `60 hr 45 min recording remaining · estimated`, `No recording space`,
  /// or `Remaining time unavailable`.
  final String headline;

  /// `48 kHz · 24-bit · Stereo`, or null when there is no applied rate.
  final String? format;

  /// The reserve and what it is for.
  final String note;

  /// How far the panel is stepped in from the cards on each side.
  static const double inset = 20;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: inset),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: surface.accentSurface,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: surface.borderStrong),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 14, 18, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Flexible(
                    child: AppText(
                      headline,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: surface.textPrimary,
                        fontSize: 17,
                        height: 1.2,
                      ),
                    ),
                  ),
                  if (format case final words?) ...[
                    const SizedBox(width: 18),
                    AppText(
                      words,
                      style: TextStyle(
                        color: surface.textSecondary,
                        fontSize: 14,
                        height: 1.2,
                      ),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 8),
              AppText(
                note,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: surface.textMuted,
                  fontSize: 13,
                  height: 1.2,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A one-line warning under the block it is about (pen `Eject failed`, `Low
/// internal space`): amber text, no box, stepped in like the recording panel.
class StorageNotice extends StatelessWidget {
  /// Creates a [StorageNotice].
  const StorageNotice(this.message, {super.key});

  /// The sentence.
  final String message;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: StorageRecordingTime.inset,
      ),
      child: AppText(
        message,
        style: TextStyle(
          color: context.surface.warning,
          fontSize: 15,
          height: 1.2,
        ),
      ),
    );
  }
}
