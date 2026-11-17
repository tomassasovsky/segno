import Darwin
import Foundation

/// A plugin bundle's version: its `CFBundleShortVersionString`, then its
/// `CFBundleVersion` (the build number), each compared as dotted numbers.
public struct PluginVersion: Comparable, CustomStringConvertible {
  public let short: String
  public let build: String

  public init(short: String, build: String) {
    self.short = short
    self.build = build
  }

  /// The version in `bundle`'s `Contents/Info.plist`, read fresh from disk.
  public init?(bundle: URL) {
    guard
      let data = try? Data(contentsOf: bundle.appendingPathComponent("Contents/Info.plist")),
      let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
        as? [String: Any]
    else { return nil }
    self.init(
      short: plist["CFBundleShortVersionString"] as? String ?? "0",
      build: plist["CFBundleVersion"] as? String ?? "0")
  }

  public var description: String { "\(short) (build \(build))" }

  public static func < (lhs: Self, rhs: Self) -> Bool {
    let left = Self.numbers(lhs.short)
    let right = Self.numbers(rhs.short)
    if left != right { return Self.less(left, right) }
    return Self.less(Self.numbers(lhs.build), Self.numbers(rhs.build))
  }

  public static func == (lhs: Self, rhs: Self) -> Bool { !(lhs < rhs) && !(rhs < lhs) }

  private static func numbers(_ value: String) -> [Int] {
    value.split(separator: ".").map { Int($0) ?? 0 }
  }

  private static func less(_ left: [Int], _ right: [Int]) -> Bool {
    for index in 0..<max(left.count, right.count) {
      let a = index < left.count ? left[index] : 0
      let b = index < right.count ? right[index] : 0
      if a != b { return a < b }
    }
    return false
  }
}

/// The Segno plugins (`Segno.vst3`) that Segno Transfer carries, and the
/// copy this Mac has where Live looks for VST3 plugins. Transfer installs
/// only into the user's own folder, `~/Library/Audio/Plug-Ins/VST3`.
public struct SegnoPlugins {
  public static let bundleName = "Segno.vst3"

  /// What this Mac has, compared with the copy Transfer carries.
  public enum Status: Equatable {
    /// A copy at least as new as the one Transfer carries (any copy when
    /// Transfer carries none).
    case installed
    /// No copy in either folder.
    case missing
    /// The user's copy is older than the one Transfer carries.
    case older(installed: PluginVersion, bundled: PluginVersion)
    /// The copy for every user, in `/Library/Audio/Plug-Ins/VST3`, which
    /// Transfer does not write to, is older (the user's own copy, if any,
    /// is not).
    case olderForAllUsers(installed: PluginVersion, bundled: PluginVersion)
  }

  /// The copy inside the app, or nil when this build carries none.
  public let bundled: URL?
  /// The user's VST3 folder.
  public let userFolder: URL
  /// The VST3 folder for every user.
  public let allUsersFolder: URL

  public init(
    bundled: URL?, home: URL,
    allUsersFolder: URL = URL(fileURLWithPath: "/Library/Audio/Plug-Ins/VST3")
  ) {
    self.bundled = bundled
    self.userFolder = home.appendingPathComponent("Library/Audio/Plug-Ins/VST3")
    self.allUsersFolder = allUsersFolder
  }

  public var bundledVersion: PluginVersion? { bundled.flatMap { PluginVersion(bundle: $0) } }

  public func status() -> Status {
    let user = userFolder.appendingPathComponent(Self.bundleName)
    let allUsers = allUsersFolder.appendingPathComponent(Self.bundleName)
    let exists = { (url: URL) in FileManager.default.fileExists(atPath: url.path) }
    // An unreadable version reads as 0, older than any build.
    let installed = { (url: URL) in
      PluginVersion(bundle: url) ?? PluginVersion(short: "0", build: "0")
    }
    let bundled = bundledVersion
    if exists(user), let bundled, installed(user) < bundled {
      return .older(installed: installed(user), bundled: bundled)
    }
    // Live also loads the copy for every user, which has the same class IDs.
    if exists(allUsers), let bundled, installed(allUsers) < bundled {
      return .olderForAllUsers(installed: installed(allUsers), bundled: bundled)
    }
    if exists(user) || exists(allUsers) { return .installed }
    return .missing
  }

  /// Whether Transfer can install or replace the user's copy for `status`.
  public func canInstall(_ status: Status) -> Bool {
    switch status {
    case .missing: return bundledVersion != nil
    case .older: return true
    case .installed, .olderForAllUsers: return false
    }
  }

  /// Copies the bundled plugins into the user's VST3 folder, replacing the
  /// copy there in one rename. The copy keeps the bundle's signature and
  /// extended attributes, quarantine included, as a Finder copy would.
  /// Nothing is written outside the user's VST3 folder.
  public func install() throws {
    guard let bundled, bundledVersion != nil else {
      throw TransferError.message("This copy of Segno Transfer does not carry the Segno plugins.")
    }
    let manager = FileManager.default
    try manager.createDirectory(at: userFolder, withIntermediateDirectories: true)
    let target = userFolder.appendingPathComponent(Self.bundleName)
    // Staged without the .vst3 extension, so no host scanning the folder
    // meanwhile takes the half-copied bundle for a plugin.
    let staged = userFolder.appendingPathComponent(".segno-transfer-" + UUID().uuidString)
    defer { try? manager.removeItem(at: staged) }
    try manager.copyItem(at: bundled, to: staged)
    if renamex_np(staged.path, target.path, UInt32(RENAME_EXCL)) == 0 { return }
    guard errno == EEXIST,
      renamex_np(staged.path, target.path, UInt32(RENAME_SWAP)) == 0
    else {
      throw TransferError.message(
        "Could not install the Segno plugins: \(String(cString: strerror(errno)))")
    }
    // `staged` now holds the replaced copy, which the defer removes.
  }
}
