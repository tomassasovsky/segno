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

  /// The manifest or its layers do not decode.
  unreadable,
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
    this.folders = const [],
    this.selectedId,
    this.preview,
    this.previewError,
    this.volumes = const [],
    this.dismissalRequested = false,
  });

  /// Internal or USB.
  final LibraryLocation location;

  /// The search text; empty lists every session.
  final String query;

  /// The folder chip that is down.
  final LibraryFolderFilter folderFilter;

  /// The one-level folders under the root, for the chips.
  final List<String> folders;

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

  /// Whether a drive is mounted and readable.
  bool get hasReadableVolume => volumes.any((v) => v.readable);

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
    List<String>? folders,
    SessionId? selectedId,
    SessionPreview? preview,
    LibraryPreviewError? previewError,
    List<RemovableVolume>? volumes,
    bool? dismissalRequested,
    bool clearPreview = false,
  }) => LibraryState(
    location: location ?? this.location,
    query: query ?? this.query,
    folderFilter: folderFilter ?? this.folderFilter,
    folders: folders ?? this.folders,
    selectedId: selectedId ?? this.selectedId,
    preview: clearPreview ? null : (preview ?? this.preview),
    previewError: clearPreview ? null : (previewError ?? this.previewError),
    volumes: volumes ?? this.volumes,
    dismissalRequested: dismissalRequested ?? this.dismissalRequested,
  );

  @override
  List<Object?> get props => [
    location,
    query,
    folderFilter,
    folders,
    selectedId,
    preview,
    previewError,
    volumes,
    dismissalRequested,
  ];
}
