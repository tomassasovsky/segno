import AVFoundation
import Foundation
import TransferCore
import UniformTypeIdentifiers

/// Supplies only the byte ranges AVFoundation requests, over the existing SSH connection.
final class RemoteAudioLoader: NSObject, AVAssetResourceLoaderDelegate {
  let asset: AVURLAsset
  private let size: Int64
  private let read: (Int64, Int, CancellationToken) throws -> Data
  private let queue = DispatchQueue(label: "dev.segno.transfer.audio-loader")
  private let workers: OperationQueue = {
    let queue = OperationQueue()
    queue.maxConcurrentOperationCount = 2
    queue.qualityOfService = .userInitiated
    return queue
  }()
  // Accessed only on the resource-loader queue.
  private var pending: [AVAssetResourceLoadingRequest: CancellationToken] = [:]
  private var stopped = false
  private var failureHandler: ((Error) -> Void)?

  init(size: Int64, read: @escaping (Int64, Int, CancellationToken) throws -> Data) {
    self.size = size
    self.read = read
    asset = AVURLAsset(url: URL(string: "segno-audio://\(UUID().uuidString)/audio.wav")!)
    super.init()
    asset.resourceLoader.setDelegate(self, queue: queue)
  }

  func resourceLoader(
    _ resourceLoader: AVAssetResourceLoader,
    shouldWaitForLoadingOfRequestedResource request: AVAssetResourceLoadingRequest
  ) -> Bool {
    guard !stopped, size > 0 else {
      request.finishLoading(with: TransferError.cancelled)
      return true
    }
    if let info = request.contentInformationRequest {
      info.contentType = UTType.wav.identifier
      info.contentLength = size
      info.isByteRangeAccessSupported = true
    }
    let token = CancellationToken()
    pending[request] = token
    supply(request, token: token)
    return true
  }

  func resourceLoader(
    _ resourceLoader: AVAssetResourceLoader, didCancel request: AVAssetResourceLoadingRequest
  ) {
    pending.removeValue(forKey: request)?.cancel()
  }

  /// Called by the main-actor player before releasing or replacing an asset.
  func stop() {
    queue.sync {
      stopped = true
      for (request, token) in pending {
        token.cancel()
        if !request.isCancelled, !request.isFinished {
          request.finishLoading(with: TransferError.cancelled)
        }
      }
      pending.removeAll()
      workers.cancelAllOperations()
    }
  }

  func onFailure(_ handler: @escaping (Error) -> Void) {
    queue.sync { failureHandler = handler }
  }

  private func supply(_ request: AVAssetResourceLoadingRequest, token: CancellationToken) {
    guard !request.isCancelled, !request.isFinished else {
      pending.removeValue(forKey: request)?.cancel()
      return
    }
    guard let dataRequest = request.dataRequest else {
      pending.removeValue(forKey: request)
      request.finishLoading()
      return
    }
    let offset = max(dataRequest.requestedOffset, dataRequest.currentOffset)
    guard offset >= 0, offset <= size, dataRequest.requestedOffset >= 0 else {
      pending.removeValue(forKey: request)
      request.finishLoading(with: TransferError.message("The requested audio range is invalid."))
      return
    }
    let remaining =
      dataRequest.requestsAllDataToEndOfResource
      ? size - offset
      : min(
        size - offset, Int64(dataRequest.requestedLength) - (offset - dataRequest.requestedOffset))
    guard remaining > 0 else {
      pending.removeValue(forKey: request)
      request.finishLoading()
      return
    }
    let length = Int(min(1024 * 1024, remaining))
    workers.addOperation { [self] in
      let result = Result { () throws -> Data in
        try token.check()
        let data = try read(offset, length, token)
        guard data.count == length else {
          throw TransferError.message("The audio read was incomplete. Try the preview again.")
        }
        return data
      }
      queue.async { [self] in
        guard pending[request] === token, !token.isCancelled, !request.isCancelled else { return }
        switch result {
        case .success(let data):
          dataRequest.respond(with: data)
          supply(request, token: token)
        case .failure(let error):
          pending.removeValue(forKey: request)
          request.finishLoading(with: error)
          failureHandler?(error)
        }
      }
    }
  }
}
