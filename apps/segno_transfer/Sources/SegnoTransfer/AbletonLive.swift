import AppKit
import Foundation

/// Ableton Live on this Mac, through Launch Services, and the Segno plugins
/// a set's effects need.
struct AbletonLive {
  /// The Live application Launch Services opens sets with, if one is installed.
  var application: () -> URL?
  /// Whether `Segno.vst3` is installed for this user or for every user.
  var pluginInstalled: () -> Bool
  /// Opens a set in the given Live application.
  var open: (_ set: URL, _ application: URL) async throws -> Void

  static let bundleIdentifier = "com.ableton.live"

  static let system = AbletonLive(
    application: { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) },
    pluginInstalled: {
      pluginFolders(home: FileManager.default.homeDirectoryForCurrentUser).contains {
        FileManager.default.fileExists(atPath: $0.appendingPathComponent("Segno.vst3").path)
      }
    },
    open: { set, application in
      _ = try await NSWorkspace.shared.open(
        [set], withApplicationAt: application, configuration: NSWorkspace.OpenConfiguration())
    })

  /// The VST3 folders Live scans: the user's own, then the one for every user.
  static func pluginFolders(home: URL) -> [URL] {
    [
      home.appendingPathComponent("Library/Audio/Plug-Ins/VST3"),
      URL(fileURLWithPath: "/Library/Audio/Plug-Ins/VST3"),
    ]
  }
}
