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
      from: Data(
        #"{"recordings":[{"id":"first","name":"first","timestamp":"20260915120000","modified":0,"duration":60,"files":[{"path":"master.wav","bytes":100,"version":"one"},{"path":"loops/track1.wav","bytes":50,"version":"two"}]},{"id":"second","name":"second","timestamp":"20260915130000","modified":0,"duration":30,"files":[{"path":"master.wav","bytes":200,"version":"three"}]}],"unavailable":1}"#
          .utf8))
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
}

@MainActor
final class AppModelTests: XCTestCase {
  private func fixture() -> (AppModel, FixtureRepository) {
    let repository = FixtureRepository()
    let suite = "segno-transfer-tests-" + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
    let model = AppModel(repository: repository, defaults: defaults)
    model.connection.host = "appliance.example"
    return (model, repository)
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
}
