import AppKit
import Foundation
import TransferCore

@MainActor
final class AppModel: ObservableObject {
  @Published var connection: Connection {
    didSet {
      if connection != oldValue {
        closePreview()
        connected = false
        recordings = []
        selected.removeAll()
        names.removeAll()
        focusedID = nil
      }
    }
  }
  @Published var recordings: [Recording] = []
  @Published var focusedID: String?
  @Published var selected = Set<String>()
  @Published var names: [String: String] = [:]
  @Published var search = ""
  @Published var destination: URL
  @Published var busy = false
  @Published var connected = false
  @Published var status = "Connect to your appliance to see its recordings."
  @Published var error: String?
  @Published var progress: Double = 0
  @Published var progressTitle = ""
  @Published var downloaded: [URL] = []
  @Published var settingsPresented = false
  @Published private(set) var previewTitle: String?
  let previewPlayer = PreviewPlayer()
  private var previewDirectory: URL?
  private var token = CancellationToken()
  private let repository: RecordingRepository
  private let defaults: UserDefaults

  init(repository: RecordingRepository, defaults: UserDefaults = .standard) {
    self.repository = repository
    self.defaults = defaults
    connection =
      defaults.data(forKey: "connection").flatMap {
        try? JSONDecoder().decode(Connection.self, from: $0)
      } ?? Connection()
    destination =
      defaults.string(forKey: "destination").map { URL(fileURLWithPath: $0) }
      ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
  }

  var visibleRecordings: [Recording] {
    recordings.filter {
      search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)
        || $0.date.formatted(date: .abbreviated, time: .shortened).localizedCaseInsensitiveContains(
          search)
    }
  }
  var focused: Recording? { recordings.first { $0.id == focusedID } }
  func key(_ recording: Recording, _ file: RecordingFile) -> String {
    recording.id + "\0" + file.path
  }
  func isSelected(_ recording: Recording, _ file: RecordingFile) -> Bool {
    selected.contains(key(recording, file))
  }
  func name(_ recording: Recording, _ file: RecordingFile) -> String {
    names[key(recording, file)] ?? file.suggestedName(recording: recording)
  }
  func toggle(_ recording: Recording, _ file: RecordingFile, selected value: Bool) {
    let id = key(recording, file)
    if value { selected.insert(id) } else { selected.remove(id) }
  }
  func selectMain(_ recording: Recording, _ value: Bool) {
    if value, let file = recording.files.first(where: { $0.path == "master.wav" }) {
      toggle(recording, file, selected: true)
    }
    if !value { for file in recording.files { selected.remove(key(recording, file)) } }
  }
  func hasSelection(_ recording: Recording) -> Bool {
    recording.files.contains { isSelected(recording, $0) }
  }

  var selection: [(Recording, RecordingFile)] {
    recordings.flatMap { recording in
      recording.files.filter { isSelected(recording, $0) }.map { (recording, $0) }
    }
  }
  var selectionBytes: Int64 { selection.reduce(0) { $0 + $1.1.bytes } }

  func connect() {
    guard !busy else { return }
    do { try connection.validate() } catch {
      self.error = error.localizedDescription
      return
    }
    busy = true
    error = nil
    status = "Connecting…"
    progressTitle = "Loading recordings"
    token = CancellationToken()
    let settings = connection
    let cancellation = token
    let repository = repository
    Task {
      do {
        let catalog = try await Task.detached {
          try repository.catalog(connection: settings, token: cancellation)
        }.value
        let wasConnected = connected
        recordings = catalog.recordings.sorted { $0.date > $1.date }
        let available = Set(
          recordings.flatMap { recording in recording.files.map { key(recording, $0) } })
        selected.formIntersection(available)
        if focused == nil { focusedID = recordings.first?.id }
        if !wasConnected, let first = recordings.first { selectMain(first, true) }
        connected = true
        defaults.set(try JSONEncoder().encode(settings), forKey: "connection")
        status = "\(recordings.count) performances"
        if catalog.unavailable > 0 { status += " · \(catalog.unavailable) not ready" }
      } catch {
        self.error = error.localizedDescription
        connected = false
        recordings = []
        selected.removeAll()
        status = "Could not load recordings."
      }
      busy = false
      progressTitle = ""
    }
  }

  func chooseFolder() {
    let panel = NSOpenPanel()
    panel.title = "Choose a download folder"
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.canCreateDirectories = true
    panel.directoryURL = destination
    if panel.runModal() == .OK, let url = panel.url {
      destination = url
      defaults.set(url.path, forKey: "destination")
    }
  }

  func chooseIdentity() {
    let panel = NSOpenPanel()
    panel.title = "Choose your SSH private key"
    panel.showsHiddenFiles = true
    panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
      ".ssh")
    if panel.runModal() == .OK, let url = panel.url { connection.identityFile = url.path }
  }

  func download() {
    guard !busy, !selection.isEmpty else { return }
    let jobs = selection.map { ($0.0, $0.1, name($0.0, $0.1)) }
    do { for job in jobs { _ = try DownloadName.validated(job.2) } } catch {
      self.error = error.localizedDescription
      return
    }
    let settings = connection
    let folder = destination
    let total = max(1, selectionBytes)
    token = CancellationToken()
    let cancellation = token
    let repository = repository
    busy = true
    error = nil
    downloaded = []
    progress = 0
    progressTitle = "Starting download"
    Task {
      var completedBytes: Int64 = 0
      var failures: [String] = []
      for (index, job) in jobs.enumerated() {
        if cancellation.isCancelled { break }
        let (recording, file, name) = job
        let before = completedBytes
        do {
          let result = try await Task.detached {
            try repository.download(
              recording: recording, file: file, name: name,
              destination: folder, connection: settings, token: cancellation
            ) { bytes, phase in
              Task { @MainActor in
                guard self.busy, self.token === cancellation else { return }
                self.progress = min(1, Double(before + bytes) / Double(total))
                self.progressTitle = "\(phase) \(index + 1) of \(jobs.count) · \(name)"
              }
            }
          }.value
          downloaded.append(result)
          selected.remove(key(recording, file))
        } catch {
          if !cancellation.isCancelled { failures.append("\(name): \(error.localizedDescription)") }
        }
        completedBytes += file.bytes
      }
      busy = false
      progressTitle = ""
      status =
        cancellation.isCancelled
        ? "Cancelled · \(downloaded.count) files downloaded and verified"
        : "\(downloaded.count) files downloaded and verified"
      if !failures.isEmpty { error = failures.joined(separator: "\n") }
    }
  }

  func cancel() { token.cancel() }

  func preparePreview(_ recording: Recording, _ file: RecordingFile) {
    guard !busy else { return }
    closePreview()
    token = CancellationToken()
    let cancellation = token
    let repository = repository
    let settings = connection
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
      "segno-preview-" + UUID().uuidString)
    do {
      try FileManager.default.createDirectory(
        at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    } catch {
      self.error = error.localizedDescription
      return
    }
    previewDirectory = folder
    busy = true
    error = nil
    progress = 0
    progressTitle = "Preparing preview · \(file.role)"
    Task {
      do {
        let url = try await Task.detached {
          try repository.download(
            recording: recording, file: file, name: "preview.wav", destination: folder,
            connection: settings, token: cancellation
          ) { bytes, phase in
            Task { @MainActor in
              guard self.busy, self.token === cancellation else { return }
              self.progress = Double(bytes) / Double(max(1, file.bytes))
              self.progressTitle =
                "\(phase == "Verifying" ? "Verifying preview" : "Preparing preview") · \(file.role)"
            }
          }
        }.value
        try cancellation.check()
        try await previewPlayer.prepare(url)
        try cancellation.check()
        previewTitle = "\(recording.name) · \(file.role)"
        previewPlayer.playPause()
        status = "Preview ready · Download to keep a copy"
      } catch {
        closePreview()
        if !cancellation.isCancelled { self.error = error.localizedDescription }
        status = cancellation.isCancelled ? "Preview cancelled" : "Could not prepare preview"
      }
      busy = false
      progressTitle = ""
    }
  }

  func closePreview() {
    previewPlayer.stop()
    previewTitle = nil
    if let previewDirectory { try? FileManager.default.removeItem(at: previewDirectory) }
    previewDirectory = nil
  }

  func reveal() {
    if downloaded.isEmpty {
      NSWorkspace.shared.open(destination)
    } else {
      NSWorkspace.shared.activateFileViewerSelecting(downloaded)
    }
  }
}
