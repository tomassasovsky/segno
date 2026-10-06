part of 'library_audio_cubit.dart';

/// The Audio tab's two folders (pen 18/01's file browser; deviation 4 adds
/// `Sessions`).
enum LibraryAudioFolder {
  /// Finished recordings, the recovered ones included.
  performances,

  /// Each saved session's mixdown.
  sessions,
}

/// One file the Audio tab lists.
sealed class LibraryAudioItem extends Equatable {
  const LibraryAudioItem();

  /// What identifies it in the list and the selection.
  String get key;

  /// What the player calls it.
  String get name;

  /// How long it plays.
  Duration get duration;
}

/// A finished recording.
final class LibraryRecording extends LibraryAudioItem {
  /// Creates the item for [capture].
  const LibraryRecording(this.capture);

  /// The take.
  final CaptureSummary capture;

  @override
  String get key => capture.path;

  @override
  String get name => capture.name;

  @override
  Duration get duration => capture.duration;

  @override
  List<Object?> get props => [capture];
}

/// A saved session's mixdown.
final class LibraryMixdown extends LibraryAudioItem {
  /// Creates the item for [session]'s [mixdown].
  const LibraryMixdown(this.session, this.mixdown);

  /// The catalog entry.
  final SessionSummary session;

  /// Its mixdown's length and size.
  final SessionMixdown mixdown;

  @override
  String get key => 'session:${session.id}';

  @override
  String get name => session.name;

  @override
  Duration get duration => mixdown.duration;

  @override
  List<Object?> get props => [session.id, session.name, mixdown];
}

/// What an `Export to USB` writes.
enum LibraryAudioExportKind {
  /// A recording's main output: one WAV, or its parts as consecutive files.
  recording,

  /// A recording's DAW package: its parts, rendered stems and the Live Set.
  dawPackage,

  /// A session's mixdown.
  mixdown,

  /// A session's stems, one per lane.
  stems,
}

/// An export in front of the player.
sealed class LibraryAudioExport extends Equatable {
  const LibraryAudioExport();
}

/// Copying (pen 20/08).
final class LibraryExportRunning extends LibraryAudioExport {
  /// Creates the running export of [name] into [folder].
  const LibraryExportRunning({
    required this.name,
    required this.folder,
    this.fraction = 0,
  });

  /// What is being exported.
  final String name;

  /// Where it goes on the drive.
  final LibraryAudioFolder folder;

  /// The share of its bytes copied.
  final double fraction;

  @override
  List<Object?> get props => [name, folder, fraction];
}

/// The name is taken on the drive (pen 20/09): `Keep both` or `Replace`.
final class LibraryExportConflict extends LibraryAudioExport {
  /// Creates the conflict for [name].
  const LibraryExportConflict(this.name);

  /// The export's name.
  final String name;

  @override
  List<Object?> get props => [name];
}

/// No writable drive, or it went away (pen 20/10).
final class LibraryExportNeedsDrive extends LibraryAudioExport {
  /// Creates the request for a drive.
  const LibraryExportNeedsDrive();

  @override
  List<Object?> get props => const [];
}

/// Done (pen 20/12).
final class LibraryExportDone extends LibraryAudioExport {
  /// Creates the done state for [name], written into [folder].
  const LibraryExportDone({required this.name, required this.folder});

  /// What landed on the drive: the file or the package's name.
  final String name;

  /// The folder it is in.
  final LibraryAudioFolder folder;

  @override
  List<Object?> get props => [name, folder];
}

/// What the preview card's line reports (pen 20/11's place).
enum LibraryAudioError {
  /// The drive has too little room for the export.
  notEnoughSpace,

  /// The drive is mounted read-only.
  readOnly,

  /// The export failed for another reason; the drive was left as it was.
  exportFailed,

  /// The DAW project could not be written into the recording.
  dawProjectFailed,

  /// A take is being recorded or rendered, or the console is shutting down.
  deleteBusy,

  /// The recording could not be deleted.
  deleteFailed,
}

/// A file playing through `Preview`.
class LibraryAudioPreview extends Equatable {
  /// Creates the preview of the item [key].
  const LibraryAudioPreview({
    required this.key,
    required this.frames,
    required this.sampleRate,
    this.position = 0,
    this.truncated = false,
  });

  /// The item that plays.
  final String key;

  /// Its length as decoded, in frames.
  final int frames;

  /// The rate [frames] and [position] count at.
  final int sampleRate;

  /// Frames played.
  final int position;

  /// Whether only the first [kAuditionMaxSeconds] play.
  final bool truncated;

  /// This preview at [position].
  LibraryAudioPreview at(int position) => LibraryAudioPreview(
    key: key,
    frames: frames,
    sampleRate: sampleRate,
    position: position,
    truncated: truncated,
  );

  @override
  List<Object?> get props => [key, frames, sampleRate, position, truncated];
}

/// The Audio tab's state: the two folders' items, where the browser is,
/// the selection with its waveform, `Preview`, and the export in front of
/// the player.
class LibraryAudioState extends Equatable {
  /// Creates a [LibraryAudioState].
  const LibraryAudioState({
    this.loaded = false,
    this.folder,
    this.query = '',
    this.recordings = const [],
    this.mixdowns = const [],
    this.selectedKey,
    this.peaks,
    this.preview,
    this.previewRefusal,
    this.export,
    this.error,
    this.dawProjectWritten = false,
  });

  /// Whether the folders have been read once.
  final bool loaded;

  /// The open folder, or null at the top.
  final LibraryAudioFolder? folder;

  /// The search text; empty lists every item.
  final String query;

  /// Finished recordings, newest first.
  final List<LibraryRecording> recordings;

  /// Saved sessions that have a mixdown, in catalog order.
  final List<LibraryMixdown> mixdowns;

  /// The selected item's key.
  final String? selectedKey;

  /// The selected item's waveform, once read; null while reading or when it
  /// does not read.
  final List<double>? peaks;

  /// What `Preview` plays, or null.
  final LibraryAudioPreview? preview;

  /// Why the last `Preview` did not start.
  final LibraryListenRefusal? previewRefusal;

  /// The export in front of the player, or null.
  final LibraryAudioExport? export;

  /// What the card's line reports, or null.
  final LibraryAudioError? error;

  /// Whether `DAW project` just wrote the project into the recording.
  final bool dawProjectWritten;

  /// The open folder's items that match the search; empty at the top.
  List<LibraryAudioItem> get items {
    final needle = query.trim().toLowerCase();
    final all = switch (folder) {
      LibraryAudioFolder.performances => recordings,
      LibraryAudioFolder.sessions => mixdowns,
      null => const <LibraryAudioItem>[],
    };
    return [
      for (final item in all)
        if (needle.isEmpty || item.name.toLowerCase().contains(needle)) item,
    ];
  }

  /// The selected item, while the browser shows it.
  LibraryAudioItem? get selected =>
      items.where((i) => i.key == selectedKey).firstOrNull;

  /// Returns a copy for the next emit.
  LibraryAudioState copyWith({
    bool? loaded,
    LibraryAudioFolder? folder,
    String? query,
    List<LibraryRecording>? recordings,
    List<LibraryMixdown>? mixdowns,
    String? selectedKey,
    List<double>? peaks,
    LibraryAudioPreview? preview,
    LibraryListenRefusal? previewRefusal,
    LibraryAudioExport? export,
    LibraryAudioError? error,
    bool? dawProjectWritten,
    bool atTop = false,
    bool clearSelection = false,
    bool clearPeaks = false,
    bool clearPreview = false,
    bool clearRefusal = false,
    bool clearExport = false,
    bool clearError = false,
  }) => LibraryAudioState(
    loaded: loaded ?? this.loaded,
    folder: atTop ? null : (folder ?? this.folder),
    query: query ?? this.query,
    recordings: recordings ?? this.recordings,
    mixdowns: mixdowns ?? this.mixdowns,
    selectedKey: clearSelection ? null : (selectedKey ?? this.selectedKey),
    peaks: clearPeaks || clearSelection ? null : (peaks ?? this.peaks),
    preview: clearPreview ? null : (preview ?? this.preview),
    previewRefusal: clearRefusal
        ? null
        : (previewRefusal ?? this.previewRefusal),
    export: clearExport ? null : (export ?? this.export),
    error: clearError ? null : (error ?? this.error),
    dawProjectWritten: dawProjectWritten ?? this.dawProjectWritten,
  );

  @override
  List<Object?> get props => [
    loaded,
    folder,
    query,
    recordings,
    mixdowns,
    selectedKey,
    peaks,
    preview,
    previewRefusal,
    export,
    error,
    dawProjectWritten,
  ];
}
