import Foundation

public struct Connection: Codable, Equatable {
  public var host: String
  public var user: String
  public var root: String
  public var identityFile: String

  public init(
    host: String = "", user: String = "root", root: String = "/data/Documents/exports",
    identityFile: String = ""
  ) {
    self.host = host
    self.user = user
    self.root = root
    self.identityFile = identityFile
  }

  public func validate() throws {
    let allowed = CharacterSet(
      charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_:[]")
    guard !host.isEmpty, !host.hasPrefix("-"), host.unicodeScalars.allSatisfy(allowed.contains),
      !user.isEmpty,
      user.unicodeScalars.allSatisfy(
        CharacterSet(
          charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-"
        ).contains),
      !user.hasPrefix("-"), root.hasPrefix("/"), !root.contains("\0")
    else {
      throw TransferError.message("Enter a valid appliance address and connection details.")
    }
  }
}

public struct RecordingCatalog: Decodable {
  public let recordings: [Recording]
  public let unavailable: Int
}

public struct Recording: Decodable, Identifiable {
  public let id: String
  public let name: String
  public let timestamp: String
  public let modified: Double
  public let duration: Double
  public let files: [RecordingFile]

  public var date: Date {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyyMMddHHmmss"
    return formatter.date(from: timestamp) ?? Date(timeIntervalSince1970: modified)
  }

  public var durationLabel: String {
    guard duration.isFinite, duration >= 0, duration < 1_000_000_000 else { return "Unknown" }
    let seconds = Int(duration)
    return seconds >= 3600
      ? String(format: "%d:%02d:%02d", seconds / 3600, (seconds / 60) % 60, seconds % 60)
      : String(format: "%d:%02d", seconds / 60, seconds % 60)
  }
}

public struct RecordingFile: Decodable, Identifiable, Hashable {
  public var id: String { path }
  public let path: String
  public let bytes: Int64
  public let version: String

  public var role: String {
    if path == "master.wav" { return "Main recording" }
    if path.hasPrefix("live-input-") { return "Live input · " + baseName }
    if path.hasPrefix("stems/dry/") { return "Dry track · " + baseName }
    if path == "stems/wet/master.wav" { return "Rendered track mix" }
    if path.hasPrefix("stems/wet/") { return "Track with effects · " + baseName }
    if path.hasPrefix("loops/") { return "Loop · " + baseName }
    return path
  }

  public var baseName: String {
    URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
  }
  public var sizeLabel: String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
  }

  public func suggestedName(recording: Recording) -> String {
    path == "master.wav"
      ? recording.name + ".wav"
      : recording.name + " — " + path.replacingOccurrences(of: "/", with: "-")
  }
}

public enum TransferError: LocalizedError {
  case message(String)
  case cancelled

  public var errorDescription: String? {
    switch self {
    case .message(let message): return message
    case .cancelled: return "Download cancelled."
    }
  }
}

public final class CancellationToken: @unchecked Sendable {
  private let lock = NSLock()
  private var stopped = false
  public init() {}
  public func cancel() {
    lock.lock()
    stopped = true
    lock.unlock()
  }
  public var isCancelled: Bool {
    lock.lock()
    defer { lock.unlock() }
    return stopped
  }
  public func check() throws { if isCancelled { throw TransferError.cancelled } }
}

public enum DownloadName {
  public static func validated(_ input: String) throws -> String {
    var value = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty, value != ".", value != "..", !value.hasPrefix("."),
      !value.contains("/"), !value.contains(":"), !value.contains("\\"),
      !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    else {
      throw TransferError.message("Use a filename without slashes, colons or control characters.")
    }
    if !value.lowercased().hasSuffix(".wav") { value += ".wav" }
    guard value.utf8.count <= 240 else {
      throw TransferError.message("This filename is too long. Use a shorter name.")
    }
    return value
  }
}
