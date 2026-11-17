import Foundation
import TransferCore
import XCTest

@testable import SegnoTransfer

private final class FixtureRepository: RecordingRepository {
  var failCatalog = false
  var failDownload = false
  var holdDownloadAt: Int?
  private let startLock = NSLock()
  private var starts = 0
  private var reads = 0
  var readCount: Int {
    startLock.lock()
    defer { startLock.unlock() }
    return reads
  }
  var startedCount: Int {
    startLock.lock()
    defer { startLock.unlock() }
    return starts
  }
  var names: [String] = []
  var catalogJSON =
    #"{"recordings":[{"id":"first","name":"first","timestamp":"20260915120000","modified":0,"duration":60,"files":[{"path":"master.wav","bytes":100,"version":"one"},{"path":"loops/track1.wav","bytes":50,"version":"two"}]},{"id":"second","name":"second","timestamp":"20260915130000","modified":0,"duration":30,"liveSet":{"path":"project.als","bytes":10,"version":"set"},"files":[{"path":"master.wav","bytes":200,"version":"three"}]}],"unavailable":1}"#
  func read(
    recording: Recording, file: RecordingFile, offset: Int64, length: Int,
    connection: Connection, token: CancellationToken
  ) throws -> Data {
    startLock.lock()
    reads += 1
    startLock.unlock()
    throw TransferError.message("Preview connection failed")
  }
  func catalog(connection: Connection, token: CancellationToken) throws -> RecordingCatalog {
    if failCatalog { throw TransferError.message("Appliance offline") }
    return try JSONDecoder().decode(
      RecordingCatalog.self,
      from: Data(catalogJSON.utf8))
  }
  func download(
    recording: Recording, file: RecordingFile, name: String, destination: URL,
    connection: Connection, token: CancellationToken, progress: @escaping (Int64, String) -> Void
  ) throws -> URL {
    names.append(name)
    startLock.lock()
    starts += 1
    let thisStart = starts
    startLock.unlock()
    while holdDownloadAt == thisStart && !token.isCancelled { Thread.sleep(forTimeInterval: 0.01) }
    try token.check()
    if failDownload { throw TransferError.message("Verification failed") }
    progress(file.bytes, "Verifying")
    return destination.appendingPathComponent(name)
  }
  var holdLiveSet = false
  var failLiveSet = false
  var liveSetUsesPlugins = false
  var liveSetStarted = false
  var cancelAfterLiveSet = false
  func downloadLiveSet(
    recording: Recording, destination: URL, connection: Connection, token: CancellationToken,
    progress: @escaping (Double, String) -> Void
  ) throws -> LiveSetCopy {
    startLock.lock()
    liveSetStarted = true
    starts += 1
    startLock.unlock()
    while holdLiveSet && !token.isCancelled { Thread.sleep(forTimeInterval: 0.01) }
    try token.check()
    if cancelAfterLiveSet { token.cancel() }
    if failLiveSet { throw TransferError.message("The copy did not match the original.") }
    progress(1, "Verifying")
    return LiveSetCopy(
      folder: destination.appendingPathComponent(recording.name), usesPlugins: liveSetUsesPlugins,
      reused: false)
  }
}

/// Ableton Live as the tests see it: installed or not, and every set it was
/// asked to open.
@MainActor
private final class FakeLive {
  var installed = true
  var opened: [URL] = []
  var live: AbletonLive {
    AbletonLive(
      application: { [unowned self] in
        self.installed ? URL(fileURLWithPath: "/Applications/Ableton Live 12 Suite.app") : nil
      },
      open: { [unowned self] set, _ in self.opened.append(set) })
  }
}

@MainActor
final class AppModelTests: XCTestCase {
  private let fakeLive = FakeLive()
  /// A temporary home, VST3 folder for every user and app bundle.
  private var pluginRoot: URL!
  private var home: URL { pluginRoot.appendingPathComponent("home") }
  private var userFolder: URL { home.appendingPathComponent("Library/Audio/Plug-Ins/VST3") }
  private var allUsers: URL { pluginRoot.appendingPathComponent("all-users") }
  /// Whether the app under test carries the plugins (build 3213).
  private var bundlesPlugins = false

  override func setUpWithError() throws {
    pluginRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws { try? FileManager.default.removeItem(at: pluginRoot) }

  private func fixture() -> (AppModel, FixtureRepository) {
    let repository = FixtureRepository()
    let suite = "segno-transfer-tests-" + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
    let bundled =
      bundlesPlugins
      ? try! makePluginBundle(
        in: pluginRoot.appendingPathComponent("app"), build: "3213", payload: "new")
      : nil
    let model = AppModel(
      repository: repository, defaults: defaults, live: fakeLive.live,
      plugins: SegnoPlugins(bundled: bundled, home: home, allUsersFolder: allUsers))
    model.connection.host = "appliance.example"
    return (model, repository)
  }

  private func waitUntil(_ condition: () -> Bool) async throws {
    let start = Date()
    while !condition() && Date().timeIntervalSince(start) < 3 {
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertTrue(condition())
  }

  private func installedBuild() -> String? {
    PluginVersion(bundle: userFolder.appendingPathComponent("Segno.vst3"))?.build
  }

  private func waitUntilIdle(_ model: AppModel) async throws {
    let start = Date()
    while model.busy && Date().timeIntervalSince(start) < 5 {
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertFalse(model.busy)
  }

  func testConnectSortsNewestFirstAndSelectsItsMainAudio() async throws {
    let (model, _) = fixture()
    model.connect()
    try await waitUntilIdle(model)
    XCTAssertEqual(model.recordings.map(\.id), ["second", "first"])
    XCTAssertEqual(model.selection.count, 1)
    XCTAssertEqual(model.selection.first?.0.id, "second")
    XCTAssertEqual(model.selectionBytes, 200)
    XCTAssertTrue(model.status.contains("1 not ready"))
  }

  func testATakeRecordedInPartsSelectsEveryMainPart() async throws {
    let (model, repository) = fixture()
    repository.catalogJSON =
      #"{"recordings":[{"id":"parts","name":"Set","timestamp":"20261006120000","modified":0,"duration":60,"files":[{"path":"master-001.wav","bytes":100,"version":"a"},{"path":"master-002.wav","bytes":40,"version":"b"},{"path":"input-0-001.wav","bytes":70,"version":"c"},{"path":"input-raw-0-001.wav","bytes":35,"version":"d"}]}],"unavailable":0}"#
    model.connect()
    try await waitUntilIdle(model)
    XCTAssertEqual(model.selection.map(\.1.path), ["master-001.wav", "master-002.wav"])
    XCTAssertEqual(model.selectionBytes, 140)
    let recording = try XCTUnwrap(model.recordings.first)
    XCTAssertEqual(
      recording.files.map(\.role),
      [
        "Main recording · Part 1", "Main recording · Part 2", "Live input 0 · Part 1",
        "Raw input 0 · Part 1",
      ])
    XCTAssertEqual(
      recording.files.map { $0.suggestedName(recording: recording) },
      [
        "Set · Part 001.wav", "Set · Part 002.wav", "Set — input-0-001.wav",
        "Set — input-raw-0-001.wav",
      ])
  }

  func testOlderAppliancesStillListTheirSingleMainRecording() throws {
    func recorded(_ path: String) throws -> RecordingFile {
      try JSONDecoder().decode(
        RecordingFile.self, from: Data(#"{"path":"\#(path)","bytes":1,"version":"v"}"#.utf8))
    }
    let file = try recorded("master.wav")
    XCTAssertTrue(file.isMain)
    XCTAssertEqual(file.role, "Main recording")
    XCTAssertNil(file.mainPart)
    for path in ["master-000.wav", "master-01.wav", "master-0001.wav", "loops/master-001.wav"] {
      XCTAssertNil(try recorded(path).mainPart, path)
    }
    XCTAssertNil(try recorded("input-x-001.wav").inputPart)
    XCTAssertNil(try recorded("input-raw-0-001.wav").inputPart)
    XCTAssertNil(try recorded("input-0-001.wav").rawInputPart)
    XCTAssertNil(try recorded("input-raw-x-001.wav").rawInputPart)
  }

  func testChangingApplianceClearsCatalogAndSelection() async throws {
    let (model, _) = fixture()
    model.connect()
    try await waitUntilIdle(model)
    model.connection.host = "another.example"
    XCTAssertFalse(model.connected)
    XCTAssertTrue(model.recordings.isEmpty)
    XCTAssertTrue(model.selected.isEmpty)
  }

  func testConnectionFailureClearsStaleRecordingsAndAllowsRetry() async throws {
    let (model, repository) = fixture()
    model.connect()
    try await waitUntilIdle(model)
    repository.failCatalog = true
    model.connect()
    try await waitUntilIdle(model)
    XCTAssertFalse(model.connected)
    XCTAssertTrue(model.recordings.isEmpty)
    XCTAssertEqual(model.error, "Appliance offline")
    repository.failCatalog = false
    model.connect()
    try await waitUntilIdle(model)
    XCTAssertTrue(model.connected)
    XCTAssertNil(model.error)
  }

  func testSelectedFilesAndCustomNamesReachDownload() async throws {
    let (model, repository) = fixture()
    model.connect()
    try await waitUntilIdle(model)
    model.selected.removeAll()
    let recording = try XCTUnwrap(model.recordings.last)
    let loop = recording.files[1]
    model.toggle(recording, loop, selected: true)
    model.names[model.key(recording, loop)] = "My loop.wav"
    model.download()
    try await waitUntilIdle(model)
    XCTAssertEqual(repository.names, ["My loop.wav"])
    XCTAssertEqual(model.downloaded.first?.lastPathComponent, "My loop.wav")
    XCTAssertTrue(model.selected.isEmpty)
  }

  func testFailedDownloadRemainsSelectedForRetry() async throws {
    let (model, repository) = fixture()
    model.connect()
    try await waitUntilIdle(model)
    repository.failDownload = true
    model.download()
    try await waitUntilIdle(model)
    XCTAssertEqual(model.selection.count, 1)
    XCTAssertTrue(model.downloaded.isEmpty)
    XCTAssertTrue(model.error?.contains("Verification failed") == true)
  }

  func testCancellationRestoresControlsAndKeepsSelection() async throws {
    let (model, repository) = fixture()
    model.connect()
    try await waitUntilIdle(model)
    for recording in model.recordings {
      for file in recording.files { model.toggle(recording, file, selected: true) }
    }
    repository.holdDownloadAt = 2
    model.download()
    let start = Date()
    while repository.startedCount < 2 && Date().timeIntervalSince(start) < 3 {
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertEqual(repository.startedCount, 2)
    model.cancel()
    try await waitUntilIdle(model)
    XCTAssertTrue(model.status.contains("Cancelled"))
    XCTAssertEqual(model.selection.count, 2)
    XCTAssertEqual(model.downloaded.count, 1)
    XCTAssertFalse(model.hasSelection(model.recordings[0]))
    XCTAssertTrue(model.hasSelection(model.recordings[1]))
  }

  func testFailedPreviewPreservesDownloadSelectionAndDestination() async throws {
    let (model, repository) = fixture()
    model.connect()
    try await waitUntilIdle(model)
    let before = model.selected
    let folder = model.destination
    let recording = try XCTUnwrap(model.recordings.first)
    model.preparePreview(recording, recording.files[0])
    try await waitUntilIdle(model)
    XCTAssertEqual(model.selected, before)
    XCTAssertEqual(model.destination, folder)
    XCTAssertNil(model.previewTitle)
    XCTAssertNotNil(model.error)
    XCTAssertTrue(repository.names.isEmpty)
  }

  func testImmediatePreviewCancellationDoesNotStartReading() async throws {
    let (model, repository) = fixture()
    model.connect()
    try await waitUntilIdle(model)
    let before = model.selected
    let recording = try XCTUnwrap(model.recordings.first)
    model.preparePreview(recording, recording.files[0])
    model.cancel()
    try await waitUntilIdle(model)
    XCTAssertEqual(repository.readCount, 0)
    XCTAssertEqual(model.selected, before)
    XCTAssertNil(model.previewTitle)
    XCTAssertNil(model.error)
    XCTAssertEqual(model.status, "Preview cancelled")
  }

  private func connectedWithSet() async throws -> (AppModel, FixtureRepository, Recording) {
    let (model, repository) = fixture()
    model.connect()
    try await waitUntilIdle(model)
    return (model, repository, try XCTUnwrap(model.recordings.first { $0.liveSet != nil }))
  }

  func testOpenInLiveOpensTheVerifiedSet() async throws {
    let (model, _, recording) = try await connectedWithSet()
    XCTAssertNil(model.liveSetUnavailable(recording))
    model.openInLive(recording)
    try await waitUntilIdle(model)
    let folder = model.destination.appendingPathComponent("second")
    XCTAssertEqual(fakeLive.opened, [folder.appendingPathComponent("project.als")])
    XCTAssertEqual(model.downloaded, [folder])
    XCTAssertNil(model.error)
    XCTAssertEqual(model.status, "Live set downloaded, verified and opened")
  }

  func testMissingPluginsWarnButTheSetStillOpens() async throws {
    let (model, repository, recording) = try await connectedWithSet()
    repository.liveSetUsesPlugins = true
    model.openInLive(recording)
    try await waitUntilIdle(model)
    XCTAssertEqual(fakeLive.opened.count, 1)
    XCTAssertNil(model.pluginOffer)
    XCTAssertTrue(model.error?.contains("missing devices") == true)
    try makePluginBundle(in: userFolder, build: "1", payload: "installed")
    model.openInLive(recording)
    try await waitUntilIdle(model)
    XCTAssertEqual(fakeLive.opened.count, 2)
    XCTAssertNil(model.error)
  }

  func testASetWithoutEffectsDoesNotAskForThePlugins() async throws {
    bundlesPlugins = true
    let (model, _, recording) = try await connectedWithSet()
    model.openInLive(recording)
    try await waitUntilIdle(model)
    XCTAssertEqual(fakeLive.opened.count, 1)
    XCTAssertNil(model.pluginOffer)
    XCTAssertNil(model.error)
  }

  func testMissingPluginsAreOfferedBeforeTheSetOpens() async throws {
    bundlesPlugins = true
    let (model, repository, recording) = try await connectedWithSet()
    repository.liveSetUsesPlugins = true
    model.openInLive(recording)
    try await waitUntilIdle(model)
    XCTAssertTrue(fakeLive.opened.isEmpty)
    XCTAssertEqual(model.pluginOffer?.status, .missing)
    let offer = try XCTUnwrap(model.pluginOffer)
    XCTAssertEqual(model.text(for: offer).action, "Install")
    XCTAssertEqual(model.text(for: offer).decline, "Open Without Plugins")
    XCTAssertNil(installedBuild())
    model.installPlugins(offer)
    try await waitUntil { fakeLive.opened.count == 1 }
    XCTAssertEqual(installedBuild(), "3213")
    XCTAssertNil(model.pluginOffer)
    XCTAssertTrue(model.notice?.contains("Rescan") == true)
    XCTAssertNil(model.error)
  }

  func testAnOlderCopyIsReplacedOnlyWhenTheUserConfirms() async throws {
    bundlesPlugins = true
    try makePluginBundle(in: userFolder, build: "100", payload: "old")
    let (model, repository, recording) = try await connectedWithSet()
    repository.liveSetUsesPlugins = true
    model.openInLive(recording)
    try await waitUntilIdle(model)
    let offer = try XCTUnwrap(model.pluginOffer)
    XCTAssertEqual(model.text(for: offer).action, "Replace")
    XCTAssertEqual(model.text(for: offer).decline, "Open Without Updating")
    XCTAssertTrue(model.text(for: offer).message.contains("1.0.0 (build 100)"))
    // Declined: the set opens with the copy the Mac has.
    model.skipPlugins(offer)
    try await waitUntil { fakeLive.opened.count == 1 }
    XCTAssertEqual(installedBuild(), "100")
    XCTAssertNil(model.error)
    // Confirmed: replaced, then opened.
    model.openInLive(recording)
    try await waitUntilIdle(model)
    model.installPlugins(try XCTUnwrap(model.pluginOffer))
    try await waitUntil { fakeLive.opened.count == 2 }
    XCTAssertEqual(installedBuild(), "3213")
  }

  func testCancellingTheOfferOpensAndWritesNothing() async throws {
    bundlesPlugins = true
    let (model, repository, recording) = try await connectedWithSet()
    repository.liveSetUsesPlugins = true
    model.openInLive(recording)
    try await waitUntilIdle(model)
    model.dismissPluginOffer()
    try await Task.sleep(for: .milliseconds(50))
    XCTAssertTrue(fakeLive.opened.isEmpty)
    XCTAssertNil(installedBuild())
    XCTAssertFalse(FileManager.default.fileExists(atPath: userFolder.path))
  }

  func testAnOlderCopyForEveryUserIsLeftAlone() async throws {
    bundlesPlugins = true
    try makePluginBundle(in: allUsers, build: "100", payload: "old")
    let (model, repository, recording) = try await connectedWithSet()
    repository.liveSetUsesPlugins = true
    model.openInLive(recording)
    try await waitUntilIdle(model)
    XCTAssertNil(model.pluginOffer)
    XCTAssertEqual(fakeLive.opened.count, 1)
    XCTAssertTrue(model.error?.contains("/Library/Audio/Plug-Ins/VST3") == true)
    XCTAssertNil(installedBuild())
    XCTAssertEqual(
      PluginVersion(bundle: allUsers.appendingPathComponent("Segno.vst3"))?.build, "100")
  }

  func testTheMenuOffersAnInstallOrSaysTheCopyIsCurrent() async throws {
    bundlesPlugins = true
    let (model, _) = fixture()
    model.offerPlugins()
    XCTAssertEqual(model.pluginOffer?.status, .missing)
    let offer = try XCTUnwrap(model.pluginOffer)
    XCTAssertNil(offer.set)
    XCTAssertNil(model.text(for: offer).decline)
    model.installPlugins(offer)
    try await waitUntilIdle(model)
    XCTAssertEqual(installedBuild(), "3213")
    model.offerPlugins()
    XCTAssertNil(model.pluginOffer)
    XCTAssertEqual(model.notice, "The Segno plugins on this Mac are up to date.")
    try await Task.sleep(for: .milliseconds(50))
    XCTAssertTrue(fakeLive.opened.isEmpty)
  }

  func testWithoutLiveTheActionSaysWhyAndDoesNothing() async throws {
    let (model, repository, recording) = try await connectedWithSet()
    fakeLive.installed = false
    model.connect()
    try await waitUntilIdle(model)
    XCTAssertEqual(
      model.liveSetUnavailable(recording), "Install Ableton Live to open this take's Live set.")
    model.openInLive(recording)
    try await waitUntilIdle(model)
    XCTAssertFalse(repository.liveSetStarted)
    XCTAssertTrue(fakeLive.opened.isEmpty)
  }

  func testATakeWithoutALiveSetSaysToWriteItOnTheConsole() async throws {
    let (model, repository, _) = try await connectedWithSet()
    let take = try XCTUnwrap(model.recordings.first { $0.liveSet == nil })
    XCTAssertEqual(model.liveSetUnavailable(take), LiveSet.missing)
    model.openInLive(take)
    try await waitUntilIdle(model)
    XCTAssertFalse(repository.liveSetStarted)
    XCTAssertTrue(fakeLive.opened.isEmpty)
  }

  func testACancelledLiveSetDownloadOpensNothing() async throws {
    let (model, repository, recording) = try await connectedWithSet()
    repository.holdLiveSet = true
    model.openInLive(recording)
    let start = Date()
    while !repository.liveSetStarted && Date().timeIntervalSince(start) < 3 {
      try await Task.sleep(for: .milliseconds(10))
    }
    model.cancel()
    try await waitUntilIdle(model)
    XCTAssertTrue(fakeLive.opened.isEmpty)
    XCTAssertTrue(model.downloaded.isEmpty)
    XCTAssertNil(model.error)
    XCTAssertEqual(model.status, "Cancelled · the Live set was not opened")
  }

  func testAFailedLiveSetDownloadOpensNothing() async throws {
    let (model, repository, recording) = try await connectedWithSet()
    repository.failLiveSet = true
    model.openInLive(recording)
    try await waitUntilIdle(model)
    XCTAssertTrue(fakeLive.opened.isEmpty)
    XCTAssertTrue(model.downloaded.isEmpty)
    XCTAssertEqual(model.error, "The copy did not match the original.")
    XCTAssertEqual(model.status, "Could not open the Live set")
  }

  func testACancelAfterTheCopyIsVerifiedKeepsItButDoesNotOpen() async throws {
    let (model, repository, recording) = try await connectedWithSet()
    repository.cancelAfterLiveSet = true
    model.openInLive(recording)
    try await waitUntilIdle(model)
    XCTAssertTrue(fakeLive.opened.isEmpty)
    XCTAssertEqual(model.downloaded, [model.destination.appendingPathComponent("second")])
    XCTAssertEqual(
      model.status, "Cancelled · the Live set is downloaded and verified but was not opened")
  }

  func testAFailedInstallSaysWhyAndOpensNothing() async throws {
    bundlesPlugins = true
    // A file where the VST3 folder should be: the install cannot create it.
    try FileManager.default.createDirectory(
      at: userFolder.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data().write(to: userFolder)
    let (model, repository, recording) = try await connectedWithSet()
    repository.liveSetUsesPlugins = true
    model.openInLive(recording)
    try await waitUntilIdle(model)
    model.installPlugins(try XCTUnwrap(model.pluginOffer))
    try await waitUntilIdle(model)
    try await Task.sleep(for: .milliseconds(50))
    XCTAssertTrue(fakeLive.opened.isEmpty)
    XCTAssertNotNil(model.error)
    XCTAssertFalse(model.error?.contains("missing devices") == true)
    XCTAssertNil(model.notice)
  }

  func testAnOlderCopyForEveryUserBesideACurrentOneStillWarns() async throws {
    bundlesPlugins = true
    try makePluginBundle(in: userFolder, build: "3213", payload: "current")
    try makePluginBundle(in: allUsers, build: "100", payload: "old")
    let (model, _) = fixture()
    model.offerPlugins()
    XCTAssertNil(model.pluginOffer)
    XCTAssertTrue(model.error?.contains("/Library/Audio/Plug-Ins/VST3") == true)
  }
}
