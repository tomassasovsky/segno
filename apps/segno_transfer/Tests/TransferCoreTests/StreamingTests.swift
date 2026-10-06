import AVFoundation
import Foundation
import TransferCore
import XCTest

@testable import SegnoTransfer

private final class AudioRanges {
  let size: Int64 = 384_000 * 600 + 44
  private let header: Data
  private let lock = NSLock()
  private var reads: [Range<Int64>] = []
  private var disconnected = false
  private let holdReads: Bool
  private let cleanupGate: DispatchSemaphore?
  private var finished = 0
  var finishedReads: Int {
    lock.lock()
    defer { lock.unlock() }
    return finished
  }
  var ranges: [Range<Int64>] {
    lock.lock()
    defer { lock.unlock() }
    return reads
  }

  init(holdReads: Bool = false, cleanupGate: DispatchSemaphore? = nil) {
    self.holdReads = holdReads
    self.cleanupGate = cleanupGate
    var data = Data("RIFF".utf8)
    func word<T: FixedWidthInteger>(_ value: T) {
      var v = value.littleEndian
      withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
    }
    word(UInt32(size - 8))
    data.append(Data("WAVEfmt ".utf8))
    word(UInt32(16))
    word(UInt16(3))
    word(UInt16(2))
    word(UInt32(48000))
    word(UInt32(384000))
    word(UInt16(8))
    word(UInt16(32))
    data.append(Data("data".utf8))
    word(UInt32(size - 44))
    header = data
  }

  func disconnect() {
    lock.lock()
    disconnected = true
    lock.unlock()
  }

  func read(offset: Int64, length: Int, token: CancellationToken) throws -> Data {
    try token.check()
    lock.lock()
    reads.append(offset..<offset + Int64(length))
    let failed = disconnected
    lock.unlock()
    defer {
      if let cleanupGate { _ = cleanupGate.wait(timeout: .now() + 5) }
      lock.lock()
      finished += 1
      lock.unlock()
    }
    if failed { throw TransferError.message("Connection lost") }
    while holdReads && !token.isCancelled { Thread.sleep(forTimeInterval: 0.01) }
    Thread.sleep(forTimeInterval: 0.03)
    try token.check()
    var data = Data(repeating: 0, count: length)
    if offset < header.count {
      let end = min(header.count, Int(offset) + length)
      data.replaceSubrange(0..<end - Int(offset), with: header[Int(offset)..<end])
    }
    return data
  }
}

@MainActor
final class StreamingTests: XCTestCase {
  func testShutdownWaitsForCleanupOfEveryClosedPreview() async throws {
    let player = PreviewPlayer(muted: true)
    let gates = [DispatchSemaphore(value: 0), DispatchSemaphore(value: 0)]
    let sources = gates.map { AudioRanges(holdReads: true, cleanupGate: $0) }
    var preparations: [Task<Void, Never>] = []
    defer {
      player.stop()
      for gate in gates { gate.signal() }
      for task in preparations { task.cancel() }
    }
    for source in sources {
      let loader = RemoteAudioLoader(size: source.size, read: source.read)
      preparations.append(Task { try? await player.prepare(loader.asset, loader: loader) })
      let start = Date()
      while source.ranges.isEmpty && Date().timeIntervalSince(start) < 3 {
        try await Task.sleep(for: .milliseconds(10))
      }
      XCTAssertFalse(source.ranges.isEmpty)
      player.stop()
    }
    var cleanedUp = false
    let shutdown = Task {
      await player.waitForCleanup()
      cleanedUp = true
    }
    // Closing previews stays responsive while their cancelled reads finish cleanup.
    try await Task.sleep(for: .milliseconds(50))
    XCTAssertFalse(cleanedUp)
    XCTAssertTrue(sources.allSatisfy { $0.finishedReads == 0 })
    gates[1].signal()
    let newestCleanup = Date()
    while sources[1].finishedReads == 0 && Date().timeIntervalSince(newestCleanup) < 3 {
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertGreaterThan(sources[1].finishedReads, 0)
    try await Task.sleep(for: .milliseconds(50))
    XCTAssertFalse(cleanedUp)
    XCTAssertEqual(sources[0].finishedReads, 0)
    gates[0].signal()
    await shutdown.value
    for task in preparations { await task.value }
    XCTAssertTrue(cleanedUp)
    for source in sources { XCTAssertEqual(source.finishedReads, source.ranges.count) }
  }

  func testClosingDuringPreparationCancelsBlockedRead() async throws {
    let source = AudioRanges(holdReads: true)
    let loader = RemoteAudioLoader(size: source.size, read: source.read)
    let player = PreviewPlayer(muted: true)
    var completed = false
    var failed = false
    let task = Task {
      do { try await player.prepare(loader.asset, loader: loader) } catch { failed = true }
      completed = true
    }
    defer {
      player.stop()
      task.cancel()
    }
    let start = Date()
    while source.ranges.isEmpty && Date().timeIntervalSince(start) < 3 {
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertFalse(source.ranges.isEmpty)
    player.stop()
    let cancelled = Date()
    while !completed && Date().timeIntervalSince(cancelled) < 3 {
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertTrue(completed)
    XCTAssertTrue(failed)
    XCTAssertEqual(player.duration, 0)
  }

  func testConnectionFailureWhileSeekingStopsPlayback() async throws {
    let source = AudioRanges()
    let loader = RemoteAudioLoader(size: source.size, read: source.read)
    let player = PreviewPlayer(muted: true)
    defer { player.stop() }
    try await player.prepare(loader.asset, loader: loader)
    player.playPause()
    try await waitForPosition(player, above: 0.1)
    source.disconnect()
    player.seek(450)
    let start = Date()
    while player.error == nil && Date().timeIntervalSince(start) < 5 {
      try await Task.sleep(for: .milliseconds(30))
    }
    XCTAssertNotNil(player.error)
    XCTAssertFalse(player.isPlaying)
  }

  func testPlaybackStartsBeforeFullTransferAndSeeksToUnreadAudio() async throws {
    let source = AudioRanges()
    let loader = RemoteAudioLoader(size: source.size, read: source.read)
    let player = PreviewPlayer(muted: true)
    defer { player.stop() }
    try await player.prepare(loader.asset, loader: loader)
    XCTAssertEqual(player.duration, 600, accuracy: 0.01)
    player.playPause()
    try await waitForPosition(player, above: 0.1)
    let initial = source.ranges
    XCTAssertLessThan(initial.reduce(0) { $0 + $1.count }, Int(source.size / 10))
    XCTAssertFalse(initial.contains { $0.contains(384_000 * 450) })
    player.seek(450)
    try await waitForPosition(player, above: 450.1)
    XCTAssertTrue(source.ranges.contains { $0.lowerBound > 384_000 * 400 })
    XCTAssertTrue(source.ranges.allSatisfy { $0.count <= 1024 * 1024 })
    player.playPause()
    XCTAssertFalse(player.isPlaying)
    player.stop()
    try await Task.sleep(for: .milliseconds(150))
    let stoppedReads = source.ranges.count
    try await Task.sleep(for: .milliseconds(150))
    XCTAssertEqual(source.ranges.count, stoppedReads)
    XCTAssertLessThan(source.ranges.reduce(0) { $0 + $1.count }, Int(source.size / 5))
  }

  private func waitForPosition(_ player: PreviewPlayer, above minimum: Double) async throws {
    let start = Date()
    while player.position <= minimum && Date().timeIntervalSince(start) < 8 {
      try await Task.sleep(for: .milliseconds(30))
    }
    XCTAssertNil(player.error)
    XCTAssertGreaterThan(player.position, minimum)
  }
}
