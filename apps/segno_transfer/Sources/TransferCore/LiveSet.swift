import Foundation

/// A take's Live set downloaded to this Mac: `project.als` and the files it
/// uses, in the layout the set expects.
public struct LiveSetCopy: Equatable {
  public let folder: URL
  /// Whether the set holds the console's Segno effects (VST3 devices).
  public let usesPlugins: Bool
  /// Whether this is the copy an earlier download left, which may hold the
  /// user's edits.
  public let reused: Bool

  public init(folder: URL, usesPlugins: Bool, reused: Bool) {
    self.folder = folder
    self.usesPlugins = usesPlugins
    self.reused = reused
  }

  public var project: URL { folder.appendingPathComponent(LiveSet.fileName) }
}

/// Reading a take's Live set (`project.als`, gzipped XML the console writes)
/// and finding the copy of it an earlier download left.
public enum LiveSet {
  public static let fileName = "project.als"
  public static let missing =
    "This take has no Live set yet. Write it on the console with Library > Audio > Performances > DAW project."
  /// Written into a copy's folder once every file in it is verified, and
  /// rewritten when a file is fetched again.
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

  /// Reads the console's set at `url`. Throws when it does not read, refers
  /// to a file outside its folder, or refers to no file at all.
  public static func read(_ url: URL) throws -> Contents {
    let contents = try parse(url)
    for path in contents.references where !isRelative(path) {
      throw TransferError.message("The Live set uses a file outside its take: \(path)")
    }
    guard !contents.references.isEmpty else {
      throw TransferError.message(
        "The Live set has no audio. Write it again on the console with Library > Audio > Performances > DAW project."
      )
    }
    return contents
  }

  /// Every `FileRef` in the set at `url`, inside its folder or not. Throws
  /// when the set does not read.
  static func parse(_ url: URL) throws -> Contents {
    let unreadable = TransferError.message(
      "The Live set could not be read. Write it again on the console and refresh.")
    guard let xml = gunzip(try Data(contentsOf: url)) else { throw unreadable }
    let reader = Reader()
    let parser = XMLParser(data: xml)
    parser.shouldResolveExternalEntities = false
    parser.delegate = reader
    guard parser.parse() else { throw unreadable }
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
      // A VST3 device's own name, as Live stores it: "Segno Delay" and the
      // like. Other vendors' plugins the user added do not count.
      if name == "Name", stack.last == "Vst3PluginInfo",
        attributes["Value"]?.hasPrefix("Segno ") == true
      {
        usesPlugins = true
      }
      stack.append(name)
    }

    func parser(
      _ parser: XMLParser, didEndElement name: String, namespaceURI: String?,
      qualifiedName: String?
    ) {
      stack.removeLast()
    }
  }

  /// What a copy holds: each file's length and SHA-256 when it was
  /// downloaded and verified.
  struct Record: Codable {
    struct Entry: Codable {
      let path: String
      let bytes: Int64
      let sha256: String
    }
    let recording: String
    var files: [Entry]

    /// Records `file`, just downloaded to `local` and verified as `sha256`,
    /// in place of what was recorded for it.
    mutating func add(_ file: RecordingFile, at local: URL, sha256: String) throws {
      guard let bytes = LiveSet.size(of: local) else {
        throw TransferError.message("The download was incomplete. Try downloading this file again.")
      }
      files.removeAll { $0.path == file.path }
      files.append(Entry(path: file.path, bytes: bytes, sha256: sha256))
    }

    func write(in folder: URL) throws {
      try JSONEncoder().encode(self).write(
        to: folder.appendingPathComponent(LiveSet.recordName), options: .atomic)
    }
  }

  /// A copy an earlier download left, as it is now: the set may hold the
  /// user's edits.
  struct LocalCopy {
    let folder: URL
    var record: Record
    let contents: Contents

    /// The recorded files the set uses, which reopening checks. Not
    /// `project.als`, which Live rewrites on save, and not files the user
    /// added, which the copy never recorded.
    var checked: [Record.Entry] {
      contents.references.compactMap { path in
        record.files.first {
          $0.path == path && $0.path != LiveSet.fileName && LiveSet.isRelative($0.path)
        }
      }
    }
  }

  /// The copy of `recording`'s Live set in `destination` an earlier download
  /// left, named `name` or a numbered name after it, whose record names this
  /// take and whose `project.als` still reads. The set is the user's once
  /// downloaded, so an edited one is found too. Of several, the one whose set
  /// was saved last: the copy the user works in.
  static func localCopy(
    of recording: Recording, in destination: URL, named name: String
  ) -> LocalCopy? {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: destination.path)) ?? []
    var found: (copy: LocalCopy, saved: Date)?
    for candidate in names
    where candidate == name || (candidate.hasPrefix(name + " (") && candidate.hasSuffix(")")) {
      let folder = destination.appendingPathComponent(candidate, isDirectory: true)
      let project = folder.appendingPathComponent(fileName)
      guard
        let data = try? Data(contentsOf: folder.appendingPathComponent(recordName)),
        let record = try? JSONDecoder().decode(Record.self, from: data),
        record.recording == recording.id,
        let contents = try? parse(project),
        let saved = try? FileManager.default.attributesOfItem(atPath: project.path)[
          .modificationDate] as? Date
      else { continue }
      if found == nil || saved > found!.saved {
        found = (LocalCopy(folder: folder, record: record, contents: contents), saved)
      }
    }
    return found?.copy
  }

  /// The length of the regular file at `url`, or nil when there is none:
  /// a link or a folder in its place counts as missing.
  static func size(of url: URL) -> Int64? {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
      attributes[.type] as? FileAttributeType == .typeRegular
    else { return nil }
    return (attributes[.size] as? NSNumber)?.int64Value
  }
}
