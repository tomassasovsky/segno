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
  /// Downloads `recording`'s Live set and every file it refers to into a
  /// folder named after the take, or finds the verified copy an earlier call
  /// left there. `progress` gets the fraction done and what is happening.
  func downloadLiveSet(
    recording: Recording, destination: URL, connection: Connection, token: CancellationToken,
    progress: @escaping (Double, String) -> Void
  ) throws -> LiveSetCopy
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
    let temporary = try TemporaryDownload(parent: destination)
    defer { temporary.remove() }
    _ = try fetch(
      recording: recording, file: file, to: temporary.file, connection: connection, token: token,
      progress: progress)
    try token.check()
    return try temporary.publish(filename: filename)
  }

  public func downloadLiveSet(
    recording: Recording, destination: URL, connection: Connection, token: CancellationToken,
    progress: @escaping (Double, String) -> Void
  ) throws -> LiveSetCopy {
    guard let set = recording.liveSet else { throw TransferError.message(LiveSet.missing) }
    guard let name = try? DownloadName.folder(recording.name) else {
      throw TransferError.message(
        "This performance's name cannot be used as a folder name on this Mac. Rename it on the console."
      )
    }
    progress(0, "Checking for a downloaded copy")
    if let copy = try LiveSet.verifiedCopy(
      of: recording, in: destination, named: name, token: token)
    {
      // A copy an earlier version of this app downloaded has none.
      try LiveSet.makeProject(copy.folder)
      return copy
    }
    let temporary = try TemporaryDownload(parent: destination)
    defer { temporary.remove() }
    // The take's folder sits apart from the staging file, whatever its name.
    let folder = temporary.directory.appendingPathComponent("set", isDirectory: true)
      .appendingPathComponent(name, isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try LiveSet.makeProject(folder)
    progress(0, "Downloading the Live set")
    let project = folder.appendingPathComponent(LiveSet.fileName)
    var record = LiveSet.Record(recording: recording.id, files: [])
    let setHash = try fetch(
      recording: recording, file: set, to: TemporaryDownload.emptyFile(project),
      connection: connection, token: token, progress: { _, _ in })
    try record.add(set, at: project, sha256: setHash)
    let contents = try LiveSet.read(project)
    let files = try contents.references.map { path in
      guard let file = recording.files.first(where: { $0.path == path }) else {
        throw TransferError.message(
          "The Live set uses \(path), which is missing or still being saved on the appliance.")
      }
      return file
    }
    let total = max(1, files.reduce(0) { $0 + $1.bytes })
    var done: Int64 = 0
    for (index, file) in files.enumerated() {
      let before = done
      let target = folder.appendingPathComponent(file.path)
      try FileManager.default.createDirectory(
        at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
      let hash = try fetch(
        recording: recording, file: file, to: TemporaryDownload.emptyFile(target),
        connection: connection, token: token
      ) { bytes, phase in
        progress(
          min(1, Double(before + bytes) / Double(total)),
          "\(phase) \(index + 1) of \(files.count) · \(file.path)")
      }
      try record.add(file, at: target, sha256: hash)
      done += file.bytes
    }
    try record.write(in: folder)
    try token.check()
    let published = try temporary.publish(folder: folder, name: name)
    return LiveSetCopy(
      folder: URL(fileURLWithPath: published.path, isDirectory: true),
      usesPlugins: contents.usesPlugins, reused: false)
  }

  /// Fetches `file` into the existing, empty `output` and checks its length
  /// and SHA-256 against the appliance's copy. Returns the SHA-256.
  private func fetch(
    recording: Recording, file: RecordingFile, to output: URL, connection: Connection,
    token: CancellationToken, progress: @escaping (Int64, String) -> Void
  ) throws -> String {
    guard file.bytes > 0 else {
      throw TransferError.message("This file is empty. Refresh the recordings.")
    }
    let request = [
      "action": "download", "root": connection.root, "recording": recording.id,
      "file": file.path, "version": file.version,
    ]
    try ssh.request(
      request, connection: connection, to: output, token: token, maximumBytes: file.bytes
    ) { progress($0, "Downloading") }
    let size =
      (try FileManager.default.attributesOfItem(atPath: output.path)[.size] as? NSNumber)?
      .int64Value
    guard size == file.bytes else {
      throw TransferError.message("The download was incomplete. Try downloading this file again.")
    }
    progress(file.bytes, "Verifying")
    let localHash = try Self.sha256(output, token: token)
    var hashRequest = request
    hashRequest["action"] = "hash"
    struct Hash: Decodable { let sha256: String }
    let hash = try JSONDecoder().decode(
      Hash.self, from: response(hashRequest, connection: connection, token: token))
    guard localHash == hash.sha256 else {
      throw TransferError.message(
        "The copy did not match the original. Try downloading this file again.")
    }
    return localHash
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
    do { _ = try Self.emptyFile(file) } catch {
      try? FileManager.default.removeItem(at: directory)
      throw error
    }
  }

  /// Creates `url` as a new, empty file for a download to write into. Fails
  /// rather than reuse a file already there, such as one whose name differs
  /// only in case on a case-insensitive volume.
  static func emptyFile(_ url: URL) throws -> URL {
    let descriptor = Darwin.open(url.path, O_CREAT | O_EXCL | O_WRONLY, 0o600)
    guard descriptor >= 0 else {
      if errno == EEXIST {
        throw TransferError.message(
          "Two files in this take have names that differ only in letter case, which this Mac's folder cannot hold apart: \(url.lastPathComponent)"
        )
      }
      throw TransferError.message(
        "Could not create a download in this folder. Choose another folder.")
    }
    close(descriptor)
    return url
  }

  func publish(filename: String) throws -> URL {
    let stem = (filename as NSString).deletingPathExtension
    let ext = (filename as NSString).pathExtension
    return try publish(file) { $0 == 0 ? filename : "\(stem) (\($0 + 1)).\(ext)" }
  }

  /// Publishes `folder`, a folder inside this download, as `name` or the
  /// first free numbered name after it.
  func publish(folder: URL, name: String) throws -> URL {
    try publish(folder) { Self.folderName(name, index: $0) }
  }

  static func folderName(_ name: String, index: Int) -> String {
    index == 0 ? name : "\(name) (\(index + 1))"
  }

  private func publish(_ item: URL, name: (Int) -> String) throws -> URL {
    for index in 0..<10000 {
      let target = parent.appendingPathComponent(name(index))
      // macOS's exclusive rename publishes atomically and cannot
      // overwrite another file, including one created concurrently.
      guard renamex_np(item.path, target.path, UInt32(RENAME_EXCL)) == 0 else {
        if errno == EEXIST { continue }
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
      }
      return target
    }
    throw TransferError.message("Too many files have this name. Choose a different download name.")
  }

  func remove() { try? FileManager.default.removeItem(at: directory) }
}
