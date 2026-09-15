import AVFoundation
import Foundation
import TransferCore

@MainActor
final class PreviewPlayer: ObservableObject {
  @Published private(set) var position: Double = 0
  @Published private(set) var duration: Double = 0
  @Published private(set) var isPlaying = false
  @Published private(set) var isBuffering = false
  @Published private(set) var error: String?
  private let player = AVPlayer()
  private var timeObserver: Any?
  private var endObserver: NSObjectProtocol?
  private var statusObserver: NSKeyValueObservation?
  private var playbackObserver: NSKeyValueObservation?
  private var asset: AVURLAsset?
  private var loader: RemoteAudioLoader?
  private var pendingSeek: UUID?

  init(muted: Bool = false) { player.isMuted = muted }

  func prepare(_ asset: AVURLAsset, loader: RemoteAudioLoader? = nil) async throws {
    stop()
    self.asset = asset
    self.loader = loader
    loader?.onFailure { [weak self] error in
      Task { @MainActor in
        guard let self, self.asset === asset else { return }
        self.player.pause()
        self.loader?.stop()
        self.error = error.localizedDescription
        self.isPlaying = false
        self.isBuffering = false
      }
    }
    let item = AVPlayerItem(asset: asset)
    item.preferredForwardBufferDuration = 3
    let time = try await asset.load(.duration)
    guard self.asset === asset else { throw TransferError.cancelled }
    guard time.seconds.isFinite, time.seconds > 0 else {
      throw NSError(
        domain: "SegnoTransfer", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "This audio file cannot be previewed."])
    }
    duration = time.seconds
    player.replaceCurrentItem(with: item)
    playbackObserver = player.observe(\.timeControlStatus, options: [.initial, .new]) {
      [weak self] player, _ in
      let buffering = player.timeControlStatus == .waitingToPlayAtSpecifiedRate
      Task { @MainActor in
        guard let self, self.player.currentItem === item else { return }
        self.isBuffering = buffering && self.error == nil
      }
    }
    statusObserver = item.observe(\.status, options: [.new]) { [weak self] item, _ in
      if item.status == .failed {
        let message = item.error?.localizedDescription ?? "This audio file could not be played."
        Task { @MainActor in
          guard let self, self.player.currentItem === item else { return }
          self.error = message
          self.isPlaying = false
          self.isBuffering = false
        }
      }
    }
    timeObserver = player.addPeriodicTimeObserver(
      forInterval: CMTime(seconds: 0.2, preferredTimescale: 600), queue: .main
    ) { [weak self] time in
      Task { @MainActor in
        guard let self, self.player.currentItem === item, self.pendingSeek == nil,
          time.seconds.isFinite
        else { return }
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
    guard error == nil, player.currentItem != nil else { return }
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
    guard seconds.isFinite, duration > 0, error == nil, let item = player.currentItem else {
      return
    }
    position = max(0, min(duration, seconds))
    let id = UUID()
    pendingSeek = id
    player.seek(
      to: CMTime(seconds: position, preferredTimescale: 600), toleranceBefore: .zero,
      toleranceAfter: .zero
    ) { [weak self] _ in
      Task { @MainActor in
        guard let self, self.player.currentItem === item, self.pendingSeek == id else { return }
        self.pendingSeek = nil
        let time = self.player.currentTime().seconds
        if time.isFinite { self.position = max(0, min(self.duration, time)) }
      }
    }
  }

  func stop() {
    player.pause()
    asset?.cancelLoading()
    loader?.stop()
    loader = nil
    asset = nil
    pendingSeek = nil
    if let timeObserver { player.removeTimeObserver(timeObserver) }
    if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    timeObserver = nil
    endObserver = nil
    statusObserver?.invalidate()
    statusObserver = nil
    playbackObserver?.invalidate()
    playbackObserver = nil
    player.replaceCurrentItem(with: nil)
    position = 0
    duration = 0
    isPlaying = false
    isBuffering = false
    error = nil
  }

  static func timeLabel(_ seconds: Double) -> String {
    let value = seconds.isFinite ? Int(max(0, min(1_000_000_000, seconds))) : 0
    return value >= 3600
      ? String(format: "%d:%02d:%02d", value / 3600, value / 60 % 60, value % 60)
      : String(format: "%d:%02d", value / 60, value % 60)
  }
}
