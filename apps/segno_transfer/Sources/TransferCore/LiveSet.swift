import Foundation

/// A take's Live set downloaded to this Mac: `project.als` and the files it
/// uses, in the layout the set expects.
public struct LiveSetCopy: Equatable {
  public let folder: URL
  /// Whether the set holds VST3 devices, the console's Segno effects.
  public let usesPlugins: Bool
  /// Whether this is a verified copy an earlier download left.
  public let reused: Bool

  public init(folder: URL, usesPlugins: Bool, reused: Bool) {
    self.folder = folder
    self.usesPlugins = usesPlugins
    self.reused = reused
  }

  public var project: URL { folder.appendingPathComponent(LiveSet.fileName) }
}

/// Reading a take's Live set (`project.als`, gzipped XML the console writes)
/// and recognising a verified copy of it.
public enum LiveSet {
  public static let fileName = "project.als"
  public static let missing =
    "This take has no Live set yet. Write it on the console with Library > Audio > Performances > DAW project."
  /// Written into a copy's folder once every file in it is verified.
  static let recordName = ".segno-transfer.json"
  /// The folder that makes a copy's folder a Live Project, so Live saves the
  /// set in place (#1837). Live 12 creates it empty.
  public static let projectInfoName = "Ableton Project Info"

  /// Makes the existing `folder` a Live Project: adds its empty
  /// `projectInfoName` folder. Throws when `folder` is gone or already has
  /// one.
  static func makeProject(_ folder: URL) throws {
    try FileManager.default.createDirectory(
      at: folder.appendingPathComponent(projectInfoName, isDirectory: true),
      withIntermediateDirectories: false)
  }

  public struct Contents: Equatable {
    /// Every `FileRef`'s relative path, in the set's order, each once.
    public let references: [String]
    public let usesPlugins: Bool
  }

  /// Reads the set at `url`. Throws when it does not read, refers to a
  /// file outside its folder, or refers to no file at all.
  public static func read(_ url: URL) throws -> Contents {
    let unreadable = TransferError.message(
      "The Live set could not be read. Write it again on the console and refresh.")
    guard let xml = gunzip(try Data(contentsOf: url)) else { throw unreadable }
    let reader = Reader()
    let parser = XMLParser(data: xml)
    parser.shouldResolveExternalEntities = false
    parser.delegate = reader
    guard parser.parse() else { throw unreadable }
    for path in reader.references where !isRelative(path) {
      throw TransferError.message("The Live set uses a file outside its take: \(path)")
    }
    guard !reader.references.isEmpty else {
      throw TransferError.message(
        "The Live set has no audio. Write it again on the console with Library > Audio > Performances > DAW project."
      )
    }
    return Contents(references: reader.references, usesPlugins: reader.usesPlugins)
  }

  static func isRelative(_ path: String) -> Bool {
    let parts = path.split(separator: "/", omittingEmptySubsequences: false)
    return !path.contains("\0") && !path.contains("\\")
      && parts.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
  }

  /// The DEFLATE stream inside a gzip file (RFC 1952), inflated.
  static func gunzip(_ data: Data) -> Data? {
    let bytes = [UInt8](data)
    guard bytes.count >= 18, bytes[0] == 0x1f, bytes[1] == 0x8b, bytes[2] == 8 else { return nil }
    let flags = bytes[3]
    var position = 10
    if flags & 0x04 != 0 {
      position += 2 + Int(bytes[10]) + Int(bytes[11]) << 8
    }
    for flag: UInt8 in [0x08, 0x10] where flags & flag != 0 {
      while position < bytes.count && bytes[position] != 0 { position += 1 }
      position += 1
    }
    if flags & 0x02 != 0 { position += 2 }
    guard position <= bytes.count - 8 else { return nil }
    let size = bytes[(bytes.count - 4)...].reversed().reduce(0) { $0 << 8 | UInt32($1) }
    guard
      let inflated = try? (Data(bytes[position..<(bytes.count - 8)]) as NSData).decompressed(
        using: .zlib) as Data,
      UInt32(truncatingIfNeeded: inflated.count) == size
    else { return nil }
    return inflated
  }

  private final class Reader: NSObject, XMLParserDelegate {
    var references: [String] = []
    var usesPlugins = false
    private var stack: [String] = []

    func parser(
      _ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
      qualifiedName: String?, attributes: [String: String] = [:]
    ) {
      if name == "RelativePath", stack.last == "FileRef", let value = attributes["Value"],
        !value.isEmpty, !references.contains(value)
      {
        references.append(value)
      }
      if name == "Vst3PluginInfo" { usesPlugins = true }
      stack.append(name)
    }

    func parser(
      _ parser: XMLParser, didEndElement name: String, namespaceURI: String?,
      qualifiedName: String?
    ) {
      stack.removeLast()
    }
  }

  /// What a verified copy holds: each file's appliance version, length,
  /// modification time on this Mac and SHA-256 when it was downloaded.
  struct Record: Codable {
    struct Entry: Codable {
      let path: String
      let bytes: Int64
      let modified: Double
      let version: String
      let sha256: String
    }
    let recording: String
    var files: [Entry]

    /// Records `file`, just downloaded to `local` and verified as `sha256`.
    mutating func add(_ file: RecordingFile, at local: URL, sha256: String) throws {
      guard let state = LiveSet.state(of: local) else {
        throw TransferError.message("The download was incomplete. Try downloading this file again.")
      }
      files.append(
        Entry(
          path: file.path, bytes: state.bytes, modified: state.modified, version: file.version,
          sha256: sha256))
    }

    func write(in folder: URL) throws {
      try JSONEncoder().encode(self).write(to: folder.appendingPathComponent(LiveSet.recordName))
    }
  }

  /// The copy of `recording`'s Live set in `destination` that an earlier
  /// download verified, named `name` or a numbered name after it, when the
  /// appliance's files have not changed since, every file in the copy still
  /// has the length and modification time it was verified with, and
  /// `project.als` still has its SHA-256. A set saved over in Live no longer
  /// matches. Throws only when `token` is cancelled.
  static func verifiedCopy(
    of recording: Recording, in destination: URL, named name: String, token: CancellationToken
  ) throws -> LiveSetCopy? {
    guard let set = recording.liveSet else { return nil }
    var current = [set.path: set.version]
    for file in recording.files { current[file.path] = file.version }
    let names = (try? FileManager.default.contentsOfDirectory(atPath: destination.path)) ?? []
    let candidates = names.filter {
      $0 == name || ($0.hasPrefix(name + " (") && $0.hasSuffix(")"))
    }.sorted { $0.count == $1.count ? $0 < $1 : $0.count < $1.count }
    for candidate in candidates {
      let folder = destination.appendingPathComponent(candidate, isDirectory: true)
      let project = folder.appendingPathComponent(fileName)
      guard
        let data = try? Data(contentsOf: folder.appendingPathComponent(recordName)),
        let record = try? JSONDecoder().decode(Record.self, from: data),
        record.recording == recording.id,
        let setEntry = record.files.first(where: { $0.path == set.path }),
        setEntry.version == set.version,
        record.files.allSatisfy({ entry in
          guard current[entry.path] == entry.version, isRelative(entry.path),
            let state = state(of: folder.appendingPathComponent(entry.path))
          else { return false }
          return state.bytes == entry.bytes && state.modified == entry.modified
        }),
        let contents = try? read(project),
        Set(contents.references).isSubset(of: record.files.map(\.path))
      else { continue }
      let hash = try? TransferRepository.sha256(project, token: token)
      try token.check()
      if hash == setEntry.sha256 {
        return LiveSetCopy(folder: folder, usesPlugins: contents.usesPlugins, reused: true)
      }
    }
    return nil
  }

  fileprivate static func state(of url: URL) -> (bytes: Int64, modified: Double)? {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
      attributes[.type] as? FileAttributeType == .typeRegular,
      let bytes = (attributes[.size] as? NSNumber)?.int64Value,
      let modified = attributes[.modificationDate] as? Date
    else { return nil }
    return (bytes, modified.timeIntervalSinceReferenceDate)
  }
}
