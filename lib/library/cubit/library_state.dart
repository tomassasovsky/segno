part of 'library_cubit.dart';

/// Which storage the Library is browsing.
enum LibraryLocation {
  /// The appliance's own sessions root.
  internal,

  /// A removable drive.
  usb,
}

/// The folder chip the session list is filtered by: `All`, `Unfiled` (the
/// sessions directly under the root) or one named folder.
sealed class LibraryFolderFilter extends Equatable {
  const LibraryFolderFilter();

  /// Whether [summary] passes this filter.
  bool admits(SessionSummary summary);
}

/// Every session.
final class AllSessions extends LibraryFolderFilter {
  /// Creates the `All` filter.
  const AllSessions();

  @override
  bool admits(SessionSummary summary) => true;

  @override
  List<Object?> get props => const [];
}

/// The sessions directly under the root.
final class UnfiledSessions extends LibraryFolderFilter {
  /// Creates the `Unfiled` filter.
  const UnfiledSessions();

  @override
  bool admits(SessionSummary summary) => summary.folder == null;

  @override
  List<Object?> get props => const [];
}

/// The sessions in [folder].
final class FolderSessions extends LibraryFolderFilter {
  /// Creates the filter for [folder].
  const FolderSessions(this.folder);

  /// The folder's directory name.
  final String folder;

  @override
  bool admits(SessionSummary summary) => summary.folder == folder;

  @override
  List<Object?> get props => [folder];
}

/// Why the selected session's preview could not be read.
enum LibraryPreviewError {
  /// Saved by a newer build.
  unsupportedVersion,

  /// Saved by an older build in a form this one cannot convert.
  unconvertible,

  /// The manifest or its layers do not decode.
  unreadable,
}

/// A preview playing through Listen (plan D10).
class LibraryListen extends Equatable {
  /// Creates the Listen state for session [id].
  const LibraryListen({
    required this.id,
    required this.frames,
    this.position = 0,
    this.truncated = false,
    this.sampleRate = 0,
  });

  /// The session whose preview plays.
  final SessionId id;

  /// The preview's length in frames.
  final int frames;

  /// Frames of it played.
  final int position;

  /// Whether only the first [kAuditionMaxSeconds] of a longer preview play.
  final bool truncated;

  /// The rate [frames] and [position] count at.
  final int sampleRate;

  @override
  List<Object?> get props => [id, frames, position, truncated, sampleRate];
}

/// Why Listen did not start.
enum LibraryListenRefusal {
  /// The session has no preview, or it does not decode.
  unplayable,

  /// No audio device is running.
  noDevice,

  /// A performance capture is armed.
  performanceArmed,

  /// The preview before last is still being handed back.
  busy,
}

/// The Library's browsing state: location, search, folder chip, selection and
/// the selected session's preview, the drives the port reports, and the
/// footswitch's return-to-Tracks request.
///
/// The catalog itself (the rows and the current session) stays on
/// `SessionCubit`, its one owner; the page reads both.
class LibraryState extends Equatable {
  /// Creates a [LibraryState].
  const LibraryState({
    this.location = LibraryLocation.internal,
    this.query = '',
    this.folderFilter = const AllSessions(),
    this.selectedId,
    this.preview,
    this.previewError,
    this.volumes = const [],
    this.dismissalRequested = false,
    this.listen,
    this.listenRefusal,
    this.peaks = const {},
  });

  /// Internal or USB.
  final LibraryLocation location;

  /// The search text; empty lists every session.
  final String query;

  /// The folder chip that is down.
  final LibraryFolderFilter folderFilter;

  /// The selected session, or null when none is.
  final SessionId? selectedId;

  /// The selected session's preview, once read.
  final SessionPreview? preview;

  /// Why the selected session could not be previewed, when it could not.
  final LibraryPreviewError? previewError;

  /// The removable drives the port reports.
  final List<RemovableVolume> volumes;

  /// A footswitch asked the Library to return to Tracks; set once.
  final bool dismissalRequested;

  /// The preview playing through Listen, or null.
  final LibraryListen? listen;

  /// Why the last Listen did not start, until the next Listen or selection.
  final LibraryListenRefusal? listenRefusal;

  /// The selected session's lane peaks by channel, for the tracks whose live
  /// layer read (plan D11); a track missing here draws its length only.
  final Map<int, List<double>> peaks;

  /// Whether a drive is mounted and readable.
  bool get hasReadableVolume => volumes.any((v) => v.readable);

  /// A drive that is plugged in but cannot be read (an unsupported
  /// filesystem or a failed mount), or null.
  RemovableVolume? get unusableVolume => volumes
      .where(
        (v) =>
            v.status == RemovableVolumeStatus.unsupported ||
            v.status == RemovableVolumeStatus.mountFailed,
      )
      .firstOrNull;

  /// The rows of [all] that pass the folder chip and the search (a
  /// case-insensitive substring of the name), in catalog order.
  List<SessionSummary> filter(List<SessionSummary> all) {
    final needle = query.trim().toLowerCase();
    return [
      for (final summary in all)
        if (folderFilter.admits(summary) &&
            (needle.isEmpty || summary.name.toLowerCase().contains(needle)))
          summary,
    ];
  }

  /// Returns a copy for the next emit. A new selection replaces the preview
  /// fields as a set, so they are passed together; [clearPreview] drops
  /// them while a read is in flight.
  LibraryState copyWith({
    LibraryLocation? location,
    String? query,
    LibraryFolderFilter? folderFilter,
    SessionId? selectedId,
    SessionPreview? preview,
    LibraryPreviewError? previewError,
    List<RemovableVolume>? volumes,
    bool? dismissalRequested,
    LibraryListen? listen,
    LibraryListenRefusal? listenRefusal,
    Map<int, List<double>>? peaks,
    bool clearPreview = false,
    bool clearListen = false,
    bool clearListenRefusal = false,
  }) => LibraryState(
    location: location ?? this.location,
    query: query ?? this.query,
    folderFilter: folderFilter ?? this.folderFilter,
    selectedId: selectedId ?? this.selectedId,
    preview: clearPreview ? null : (preview ?? this.preview),
    previewError: clearPreview ? null : (previewError ?? this.previewError),
    volumes: volumes ?? this.volumes,
    dismissalRequested: dismissalRequested ?? this.dismissalRequested,
    listen: clearListen ? null : (listen ?? this.listen),
    listenRefusal: clearListenRefusal
        ? null
        : (listenRefusal ?? this.listenRefusal),
    peaks: clearPreview ? const {} : (peaks ?? this.peaks),
  );

  @override
  List<Object?> get props => [
    location,
    query,
    folderFilter,
    selectedId,
    preview,
    previewError,
    volumes,
    dismissalRequested,
    listen,
    listenRefusal,
    peaks,
  ];
}
