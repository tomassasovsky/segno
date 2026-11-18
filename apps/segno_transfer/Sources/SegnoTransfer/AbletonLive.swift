import AppKit
import Foundation

/// Ableton Live on this Mac, through Launch Services.
struct AbletonLive {
  /// The Live application Launch Services opens sets with, if one is installed.
  var application: () -> URL?
  /// Opens a set in the given Live application.
  var open: (_ set: URL, _ application: URL) async throws -> Void

  static let bundleIdentifier = "com.ableton.live"

  static let system = AbletonLive(
    application: { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) },
    open: { set, application in
      _ = try await NSWorkspace.shared.open(
        [set], withApplicationAt: application, configuration: NSWorkspace.OpenConfiguration())
    })
}
