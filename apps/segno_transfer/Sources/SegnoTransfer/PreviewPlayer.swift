import AVFoundation
import Foundation

@MainActor
final class PreviewPlayer: ObservableObject {
  @Published private(set) var position: Double = 0
  @Published private(set) var duration: Double = 0
  @Published private(set) var isPlaying = false
  @Published private(set) var error: String?
  private let player = AVPlayer()
  private var timeObserver: Any?
  private var endObserver: NSObjectProtocol?
  private var statusObserver: NSKeyValueObservation?

  init(muted: Bool = false) { player.isMuted = muted }

  func prepare(_ url: URL) async throws {
    stop()
    let item = AVPlayerItem(url: url)
    let time = try await item.asset.load(.duration)
    guard time.seconds.isFinite, time.seconds > 0 else {
      throw NSError(
        domain: "SegnoTransfer", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "This audio file cannot be previewed."])
    }
    duration = time.seconds
    player.replaceCurrentItem(with: item)
    statusObserver = item.observe(\.status, options: [.new]) { [weak self] item, _ in
      if item.status == .failed {
        let message = item.error?.localizedDescription ?? "This audio file could not be played."
        Task { @MainActor in
          guard let self, self.player.currentItem === item else { return }
          self.error = message
          self.isPlaying = false
        }
      }
    }
    timeObserver = player.addPeriodicTimeObserver(
      forInterval: CMTime(seconds: 0.2, preferredTimescale: 600), queue: .main
    ) { [weak self] time in
      Task { @MainActor in
        guard let self, self.player.currentItem === item, time.seconds.isFinite else { return }
        self.position = max(0, min(self.duration, time.seconds))
      }
    }
    endObserver = NotificationCenter.default.addObserver(
      forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
    ) { [weak self] _ in
      Task { @MainActor in
        guard let self, self.player.currentItem === item else { return }
        self.isPlaying = false
      }
    }
  }

  func playPause() {
    if isPlaying {
      player.pause()
      isPlaying = false
    } else {
      if position >= duration - 0.1 { seek(0) }
      player.play()
      isPlaying = true
    }
  }

  func seek(_ seconds: Double) {
    guard seconds.isFinite, duration > 0 else { return }
    position = max(0, min(duration, seconds))
    player.seek(
      to: CMTime(seconds: position, preferredTimescale: 600), toleranceBefore: .zero,
      toleranceAfter: .zero)
  }

  func stop() {
    player.pause()
    if let timeObserver { player.removeTimeObserver(timeObserver) }
    if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    timeObserver = nil
    endObserver = nil
    statusObserver?.invalidate()
    statusObserver = nil
    player.replaceCurrentItem(with: nil)
    position = 0
    duration = 0
    isPlaying = false
    error = nil
  }

  static func timeLabel(_ seconds: Double) -> String {
    let value = seconds.isFinite ? Int(max(0, min(1_000_000_000, seconds))) : 0
    return value >= 3600
      ? String(format: "%d:%02d:%02d", value / 3600, value / 60 % 60, value % 60)
      : String(format: "%d:%02d", value / 60, value % 60)
  }
}
