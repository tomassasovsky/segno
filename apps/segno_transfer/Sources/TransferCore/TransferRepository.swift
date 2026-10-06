import CryptoKit
import Darwin
import Foundation

public protocol RecordingRepository {
  func catalog(connection: Connection, token: CancellationToken) throws -> RecordingCatalog
  func read(
    recording: Recording, file: RecordingFile, offset: Int64, length: Int,
    connection: Connection, token: CancellationToken
  ) throws -> Data
  func download(
    recording: Recording, file: RecordingFile, name: String, destination: URL,
    connection: Connection, token: CancellationToken,
    progress: @escaping (Int64, String) -> Void
  ) throws -> URL
}

public final class TransferRepository: RecordingRepository {
  private let ssh: SSHClient
  public init(ssh: SSHClient) { self.ssh = ssh }

  public func catalog(connection: Connection, token: CancellationToken) throws -> RecordingCatalog {
    let data = try response(
      ["action": "catalog", "root": connection.root], connection: connection, token: token)
    return try JSONDecoder().decode(RecordingCatalog.self, from: data)
  }

  public func read(
    recording: Recording, file: RecordingFile, offset: Int64, length: Int,
    connection: Connection, token: CancellationToken
  ) throws -> Data {
    guard offset >= 0, length > 0, length <= 1024 * 1024, file.bytes >= Int64(length),
      offset <= file.bytes - Int64(length)
    else { throw TransferError.message("The requested audio range is invalid.") }
    let temporary = try TemporaryDownload(parent: FileManager.default.temporaryDirectory)
    defer { temporary.remove() }
    try ssh.request(
      [
        "action": "read", "root": connection.root, "recording": recording.id,
        "file": file.path, "version": file.version, "offset": String(offset),
        "length": String(length),
      ],
      connection: connection, to: temporary.file, token: token,
      maximumBytes: Int64(length), inactivityTimeout: 15)
    let data = try Data(contentsOf: temporary.file)
    guard data.count == length else {
      throw TransferError.message("The audio read was incomplete. Try the preview again.")
    }
    return data
  }

  private func response(
    _ request: [String: String], connection: Connection, token: CancellationToken
  ) throws -> Data {
    let temporary = try TemporaryDownload(parent: FileManager.default.temporaryDirectory)
    defer { temporary.remove() }
    try ssh.request(
      request, connection: connection, to: temporary.file, token: token,
      maximumBytes: 16 * 1024 * 1024)
    return try Data(contentsOf: temporary.file)
  }

  public func download(
    recording: Recording, file: RecordingFile, name: String, destination: URL,
    connection: Connection, token: CancellationToken,
    progress: @escaping (Int64, String) -> Void
  ) throws -> URL {
    let filename = try DownloadName.validated(name)
    guard file.bytes > 0 else {
      throw TransferError.message("This file is empty. Refresh the recordings.")
    }
    let temporary = try TemporaryDownload(parent: destination)
    defer { temporary.remove() }
    let request = [
      "action": "download", "root": connection.root, "recording": recording.id,
      "file": file.path, "version": file.version,
    ]
    try ssh.request(
      request, connection: connection, to: temporary.file, token: token,
      maximumBytes: file.bytes
    ) { progress($0, "Downloading") }
    let size =
      (try FileManager.default.attributesOfItem(atPath: temporary.file.path)[.size] as? NSNumber)?
      .int64Value
    guard size == file.bytes else {
      throw TransferError.message("The download was incomplete. Try downloading this file again.")
    }
    progress(file.bytes, "Verifying")
    let localHash = try Self.sha256(temporary.file, token: token)
    var hashRequest = request
    hashRequest["action"] = "hash"
    struct Hash: Decodable { let sha256: String }
    let hash = try JSONDecoder().decode(
      Hash.self, from: response(hashRequest, connection: connection, token: token))
    guard localHash == hash.sha256 else {
      throw TransferError.message(
        "The copy did not match the original. Try downloading this file again.")
    }
    try token.check()
    return try temporary.publish(filename: filename)
  }

  public static func sha256(_ file: URL, token: CancellationToken) throws -> String {
    let input = try FileHandle(forReadingFrom: file)
    defer { try? input.close() }
    var hash = SHA256()
    while let data = try input.read(upToCount: 1024 * 1024), !data.isEmpty {
      try token.check()
      hash.update(data: data)
    }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
  }
}

final class TemporaryDownload {
  let directory: URL
  let parent: URL
  let file: URL

  init(parent: URL) throws {
    self.parent = parent
    directory = parent.appendingPathComponent(
      ".segno-transfer-" + UUID().uuidString, isDirectory: true)
    file = directory.appendingPathComponent("download.part")
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    guard
      FileManager.default.createFile(
        atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
    else {
      try? FileManager.default.removeItem(at: directory)
      throw TransferError.message(
        "Could not create a download in this folder. Choose another folder.")
    }
  }

  func publish(filename: String) throws -> URL {
    let stem = (filename as NSString).deletingPathExtension
    let ext = (filename as NSString).pathExtension
    for index in 0..<10000 {
      let name = index == 0 ? filename : "\(stem) (\(index + 1)).\(ext)"
      let target = parent.appendingPathComponent(name)
      // macOS's exclusive rename publishes atomically and cannot
      // overwrite another file, including one created concurrently.
      guard renamex_np(file.path, target.path, UInt32(RENAME_EXCL)) == 0 else {
        if errno == EEXIST { continue }
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
      }
      return target
    }
    throw TransferError.message("Too many files have this name. Choose a different download name.")
  }

  func remove() { try? FileManager.default.removeItem(at: directory) }
}
