import AVFoundation
import Foundation
import XCTest

@testable import SegnoTransfer

@MainActor
final class PreviewPlayerTests: XCTestCase {
  func testPreviewLoadsPlaysPausesSeeksAndCloses() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString + ".wav")
    defer { try? FileManager.default.removeItem(at: url) }
    let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2))
    let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 96000))
    buffer.frameLength = 96000
    if let channels = buffer.floatChannelData {
      for channel in 0..<2 {
        for frame in 0..<96000 {
          channels[channel][frame] = Float(sin(Double(frame) * 440 * 2 * .pi / 48000)) * 0.1
        }
      }
    }
    do {
      var settings = format.settings
      settings[AVLinearPCMIsNonInterleaved] = false
      let file = try AVAudioFile(forWriting: url, settings: settings)
      try file.write(from: buffer)
    }
    let player = PreviewPlayer(muted: true)
    try await player.prepare(url)
    XCTAssertEqual(player.duration, 2, accuracy: 0.02)
    player.playPause()
    XCTAssertTrue(player.isPlaying)
    let start = Date()
    while player.position < 0.2 && Date().timeIntervalSince(start) < 5 {
      try await Task.sleep(for: .milliseconds(30))
    }
    XCTAssertGreaterThan(player.position, 0.1)
    player.playPause()
    XCTAssertFalse(player.isPlaying)
    player.seek(1.5)
    try await Task.sleep(for: .milliseconds(250))
    XCTAssertEqual(player.position, 1.5, accuracy: 0.1)
    player.stop()
    XCTAssertEqual(player.duration, 0)
    XCTAssertEqual(player.position, 0)
    XCTAssertFalse(player.isPlaying)
  }

  func testInvalidAudioFailsWithoutStartingPlayback() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString + ".wav")
    try Data("not audio".utf8).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    let player = PreviewPlayer(muted: true)
    do {
      try await player.prepare(url)
      XCTFail("Invalid audio must fail")
    } catch {
      XCTAssertFalse(player.isPlaying)
      XCTAssertEqual(player.duration, 0)
    }
  }
}
