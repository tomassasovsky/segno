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
  /// Information that needs no action, shown like an error but not one.
  @Published var notice: String?
  /// An offer to install or update the Segno plugins, waiting for the user.
  @Published var pluginOffer: PluginOffer?
  @Published var progress: Double = 0
  @Published var progressTitle = ""
  @Published var downloaded: [URL] = []
  @Published var settingsPresented = false
  @Published private(set) var previewTitle: String?
  /// The Live application sets open in: looked up at launch and on every
  /// connect, not on every redraw.
  @Published private(set) var liveApplication: URL?
  let previewPlayer = PreviewPlayer()
  private var preparingPreview = false
  private var token = CancellationToken()
  private let repository: RecordingRepository
  private let defaults: UserDefaults
  private let live: AbletonLive
  let plugins: SegnoPlugins

  init(
    repository: RecordingRepository, defaults: UserDefaults = .standard,
    live: AbletonLive = .system, plugins: SegnoPlugins = .thisApp
  ) {
    self.repository = repository
    self.defaults = defaults
    self.live = live
    self.plugins = plugins
    liveApplication = live.application()
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
    // Every part of the main recording: one master.wav before #1198, or the
    // ordered master-NNN.wav parts after it.
    if value {
      for file in recording.files where file.isMain { toggle(recording, file, selected: true) }
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
    liveApplication = live.application()
    busy = true
    error = nil
    notice = nil
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
    notice = nil
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

  /// Why `recording`'s Live set cannot be opened, or nil when it can.
  func liveSetUnavailable(_ recording: Recording) -> String? {
    if liveApplication == nil { return "Install Ableton Live to open this take's Live set." }
    if recording.liveSet == nil { return LiveSet.missing }
    return nil
  }

  /// Downloads `recording`'s Live set into the download folder, or finds the
  /// verified copy already there, and opens it in Live. A cancelled or failed
  /// download opens nothing.
  func openInLive(_ recording: Recording) {
    liveApplication = live.application()
    guard !busy, connected, liveSetUnavailable(recording) == nil,
      let application = liveApplication
    else { return }
    let settings = connection
    let folder = destination
    token = CancellationToken()
    let cancellation = token
    let repository = repository
    let live = live
    busy = true
    error = nil
    notice = nil
    downloaded = []
    progress = 0
    progressTitle = "Preparing the Live set · \(recording.name)"
    Task {
      do {
        let copy = try await Task.detached {
          try repository.downloadLiveSet(
            recording: recording, destination: folder, connection: settings, token: cancellation
          ) { fraction, phase in
            Task { @MainActor in
              guard self.busy, self.token === cancellation else { return }
              self.progress = fraction
              self.progressTitle = phase
            }
          }
        }.value
        downloaded = [copy.folder]
        // A cancel that arrives once the copy is verified and in place keeps
        // the copy but does not open it.
        if cancellation.isCancelled {
          status = "Cancelled · the Live set is downloaded and verified but was not opened"
          busy = false
          progressTitle = ""
          return
        }
        if copy.usesPlugins, plugins.canInstall(plugins.status()) {
          // The user decides before the set opens (`installPlugins`,
          // `skipPlugins`).
          pluginOffer = PluginOffer(status: plugins.status(), set: copy, application: application)
          status = "Live set downloaded and verified"
          busy = false
          progressTitle = ""
          return
        }
        try await open(copy, in: application)
      } catch {
        if !cancellation.isCancelled { self.error = error.localizedDescription }
        status =
          cancellation.isCancelled
          ? "Cancelled · the Live set was not opened" : "Could not open the Live set"
      }
      busy = false
      progressTitle = ""
    }
  }

  /// Opens a downloaded set and says what the Segno plugins on this Mac
  /// mean for its effects.
  private func open(_ copy: LiveSetCopy, in application: URL) async throws {
    try await live.open(copy.project, application)
    status =
      copy.reused
      ? "Opened the Live set downloaded earlier"
      : "Live set downloaded, verified and opened"
    guard copy.usesPlugins else { return }
    switch plugins.status() {
    case .missing:
      error =
        "The Segno plugins are not installed on this Mac, so the set's effects open as missing devices."
    case .olderForAllUsers(let installed, let bundled):
      error =
        "An older Segno.vst3 (\(installed)) is installed for every user in /Library/Audio/Plug-Ins/VST3. Segno Transfer does not change that folder; remove it there to install \(bundled) from Plug-ins > Install Segno Plugins."
    case .installed, .older: break
    }
  }

  /// Offers to install or update the Segno plugins (the Plug-ins menu).
  func offerPlugins() {
    guard !busy else { return }
    let current = plugins.status()
    if plugins.canInstall(current) {
      pluginOffer = PluginOffer(status: current, set: nil, application: nil)
      return
    }
    switch current {
    case .installed: notice = "The Segno plugins on this Mac are up to date."
    case .missing: error = "This copy of Segno Transfer does not carry the Segno plugins."
    case .olderForAllUsers(let installed, _):
      error =
        "An older Segno.vst3 (\(installed)) is installed for every user in /Library/Audio/Plug-Ins/VST3. Segno Transfer does not change that folder; remove it there, then install from this menu."
    case .older: break
    }
  }

  /// The offer's title, message and confirming button.
  var pluginOfferText: (title: String, message: String, action: String)? {
    guard let offer = pluginOffer else { return nil }
    let folder = "~/Library/Audio/Plug-Ins/VST3"
    let effects = offer.set == nil ? "" : " This set's effects need them."
    switch offer.status {
    case .older(let installed, let bundled):
      return (
        "Update the Segno plugins?",
        "Segno.vst3 \(installed) is installed in \(folder). Replace it with \(bundled), the version this app carries?\(effects)",
        "Replace"
      )
    default:
      let version = plugins.bundledVersion.map { " \($0)" } ?? ""
      return (
        "Install the Segno plugins?",
        "Segno Transfer can install Segno.vst3\(version) into \(folder), where Live finds it.\(effects)",
        "Install"
      )
    }
  }

  /// Installs the plugins the offer names, then opens the set it was made for.
  func installPlugins() {
    guard let offer = pluginOffer else { return }
    pluginOffer = nil
    do {
      try plugins.install()
      notice =
        "Segno.vst3 is installed. If Live is open, rescan plug-ins (Settings > Plug-Ins > Rescan) or restart Live. If macOS says Segno.vst3 cannot be opened, allow it in System Settings > Privacy & Security."
    } catch {
      self.error = error.localizedDescription
    }
    openPending(offer)
  }

  /// Declines the offer and opens the set it was made for as it is.
  func skipPlugins() {
    guard let offer = pluginOffer else { return }
    pluginOffer = nil
    openPending(offer)
  }

  /// Declines the offer and opens nothing.
  func dismissPluginOffer() { pluginOffer = nil }

  private func openPending(_ offer: PluginOffer) {
    guard let set = offer.set, let application = offer.application else { return }
    Task {
      do { try await open(set, in: application) } catch {
        self.error = error.localizedDescription
        status = "Could not open the Live set"
      }
    }
  }

  func cancel() {
    token.cancel()
    if preparingPreview { previewPlayer.stop() }
  }

  func preparePreview(_ recording: Recording, _ file: RecordingFile) {
    guard !busy else { return }
    closePreview()
    token = CancellationToken()
    let cancellation = token
    let repository = repository
    let settings = connection
    let loader = RemoteAudioLoader(size: file.bytes) { offset, length, token in
      try repository.read(
        recording: recording, file: file, offset: offset, length: length,
        connection: settings, token: token)
    }
    preparingPreview = true
    busy = true
    error = nil
    notice = nil
    progress = 0
    progressTitle = "Opening stream · \(file.role)"
    Task {
      do {
        try cancellation.check()
        try await previewPlayer.prepare(loader.asset, loader: loader)
        try cancellation.check()
        previewTitle = "\(recording.name) · \(file.role)"
        previewPlayer.playPause()
        status = "Streaming preview · Download to keep a copy"
      } catch {
        closePreview()
        if !cancellation.isCancelled { self.error = error.localizedDescription }
        status = cancellation.isCancelled ? "Preview cancelled" : "Could not open preview"
      }
      preparingPreview = false
      busy = false
      progressTitle = ""
    }
  }

  func closePreview() {
    previewPlayer.stop()
    previewTitle = nil
  }

  func finishForTermination() async {
    busy = true
    closePreview()
    await previewPlayer.waitForCleanup()
  }

  func reveal() {
    if downloaded.isEmpty {
      NSWorkspace.shared.open(destination)
    } else {
      NSWorkspace.shared.activateFileViewerSelecting(downloaded)
    }
  }
}

/// An offer to install the Segno plugins, and the set waiting to open
/// once the user answers (none when the offer came from the menu).
struct PluginOffer {
  let status: SegnoPlugins.Status
  let set: LiveSetCopy?
  let application: URL?
}

extension SegnoPlugins {
  /// The plugins inside this app (`Contents/PlugIns`), for this user.
  static var thisApp: SegnoPlugins {
    let bundled = Bundle.main.builtInPlugInsURL?.appendingPathComponent(bundleName)
    return SegnoPlugins(
      bundled: bundled.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil },
      home: FileManager.default.homeDirectoryForCurrentUser)
  }
}
