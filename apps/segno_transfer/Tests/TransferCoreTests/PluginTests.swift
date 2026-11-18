import Foundation
import XCTest

@testable import TransferCore

/// Writes a `Segno.vst3` with `short` and `build` as its versions and
/// `payload` as its module into `folder`, and returns it.
@discardableResult
func makePluginBundle(in folder: URL, short: String = "1.0.0", build: String, payload: String)
  throws -> URL
{
  let bundle = folder.appendingPathComponent(SegnoPlugins.bundleName)
  let contents = bundle.appendingPathComponent("Contents")
  try FileManager.default.createDirectory(
    at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
  let plist: [String: Any] = [
    "CFBundleIdentifier": "com.segno.vst3", "CFBundleShortVersionString": short,
    "CFBundleVersion": build,
  ]
  try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(
    to: contents.appendingPathComponent("Info.plist"))
  try Data(payload.utf8).write(to: contents.appendingPathComponent("MacOS/Segno"))
  return bundle
}

final class PluginTests: XCTestCase {
  private var root: URL!
  private var home: URL!
  private var allUsers: URL!
  private var app: URL!

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    home = root.appendingPathComponent("home")
    allUsers = root.appendingPathComponent("Library/Audio/Plug-Ins/VST3")
    app = root.appendingPathComponent("Segno Transfer.app/Contents/PlugIns")
    for folder in [home!, allUsers!, app!] {
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
  }

  override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

  private var userFolder: URL { home.appendingPathComponent("Library/Audio/Plug-Ins/VST3") }

  private func plugins(bundled: Bool = true) throws -> SegnoPlugins {
    let bundle = bundled ? try makePluginBundle(in: app, build: "3213", payload: "new") : nil
    return SegnoPlugins(bundled: bundle, home: home, allUsersFolder: allUsers)
  }

  private func version(_ short: String, _ build: String) -> PluginVersion {
    PluginVersion(short: short, build: build)
  }

  func testVersionsCompareTheShortVersionThenTheBuild() {
    XCTAssertLessThan(version("1.0.0", "1.0.0"), version("1.0.0", "3213"))
    XCTAssertLessThan(version("1.0.0", "3213"), version("1.0.0", "3214"))
    XCTAssertLessThan(version("1.0.0", "9999"), version("1.1", "1"))
    XCTAssertLessThan(version("1.9.0", "1"), version("1.10.0", "1"))
    XCTAssertEqual(version("1.0", "12"), version("1.0.0", "12"))
    XCTAssertFalse(version("1.0.0", "3213") < version("1.0.0", "3213"))
    XCTAssertLessThan(version("garbage", "x"), version("0.0.1", "0"))
  }

  func testVersionReadsTheBundleInfoPlist() throws {
    let bundle = try makePluginBundle(in: root, short: "1.2.0", build: "77", payload: "")
    XCTAssertEqual(PluginVersion(bundle: bundle)?.description, "1.2.0 (build 77)")
    XCTAssertNil(PluginVersion(bundle: root.appendingPathComponent("none.vst3")))
  }

  func testStatusAndWhetherTransferCanInstall() throws {
    let plugins = try plugins()
    XCTAssertEqual(plugins.status(), .missing)
    XCTAssertTrue(plugins.canInstall(.missing))
    try makePluginBundle(in: allUsers, build: "3000", payload: "old")
    XCTAssertEqual(
      plugins.status(),
      .olderForAllUsers(installed: version("1.0.0", "3000"), bundled: version("1.0.0", "3213")))
    XCTAssertFalse(plugins.canInstall(plugins.status()))
    try makePluginBundle(in: userFolder, build: "1.0.0", payload: "old")
    XCTAssertEqual(
      plugins.status(),
      .older(installed: version("1.0.0", "1.0.0"), bundled: version("1.0.0", "3213")))
    XCTAssertTrue(plugins.canInstall(plugins.status()))
    // A current copy of the user's own does not hide an older one for
    // every user, which Live also loads.
    try makePluginBundle(in: userFolder, build: "3213", payload: "same")
    XCTAssertEqual(
      plugins.status(),
      .olderForAllUsers(installed: version("1.0.0", "3000"), bundled: version("1.0.0", "3213")))
    try FileManager.default.removeItem(at: allUsers.appendingPathComponent("Segno.vst3"))
    XCTAssertEqual(plugins.status(), .installed)
    try makePluginBundle(in: userFolder, build: "4000", payload: "a newer build")
    XCTAssertEqual(plugins.status(), .installed)
    try makePluginBundle(in: allUsers, build: "5000", payload: "newer for every user")
    XCTAssertEqual(plugins.status(), .installed)
  }

  func testAnUnreadableInstalledCopyCountsAsOlder() throws {
    let plugins = try plugins()
    try FileManager.default.createDirectory(
      at: userFolder.appendingPathComponent("Segno.vst3"), withIntermediateDirectories: true)
    XCTAssertEqual(
      plugins.status(),
      .older(installed: version("0", "0"), bundled: version("1.0.0", "3213")))
  }

  func testWithoutABundledCopyNothingCanBeInstalled() throws {
    let plugins = try plugins(bundled: false)
    XCTAssertEqual(plugins.status(), .missing)
    XCTAssertFalse(plugins.canInstall(.missing))
    XCTAssertThrowsError(try plugins.install())
    XCTAssertFalse(FileManager.default.fileExists(atPath: userFolder.path))
    try makePluginBundle(in: userFolder, build: "1", payload: "any")
    XCTAssertEqual(plugins.status(), .installed)
  }

  func testInstallCopiesIntoTheUserFolderOnly() throws {
    let plugins = try plugins()
    try plugins.install()
    let installed = userFolder.appendingPathComponent("Segno.vst3")
    XCTAssertEqual(
      try String(
        contentsOf: installed.appendingPathComponent("Contents/MacOS/Segno"), encoding: .utf8),
      "new")
    XCTAssertEqual(plugins.status(), .installed)
    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(atPath: userFolder.path), ["Segno.vst3"])
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: allUsers.path), [])
  }

  func testInstallClearsWhatAnInterruptedInstallLeft() throws {
    let plugins = try plugins()
    let leftover = userFolder.appendingPathComponent(".segno-transfer-earlier")
    try FileManager.default.createDirectory(at: leftover, withIntermediateDirectories: true)
    try plugins.install()
    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(atPath: userFolder.path), ["Segno.vst3"])
  }

  func testInstallReplacesAnOlderCopyWhole() throws {
    let plugins = try plugins()
    let old = try makePluginBundle(in: userFolder, build: "100", payload: "old")
    try Data("stale".utf8).write(to: old.appendingPathComponent("Contents/stale"))
    try plugins.install()
    XCTAssertEqual(
      try String(contentsOf: old.appendingPathComponent("Contents/MacOS/Segno"), encoding: .utf8),
      "new")
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: old.appendingPathComponent("Contents/stale").path))
    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(atPath: userFolder.path), ["Segno.vst3"])
  }

  func testInstallKeepsTheQuarantineTheAppCarries() throws {
    let plugins = try plugins()
    let module = try XCTUnwrap(plugins.bundled).appendingPathComponent("Contents/MacOS/Segno")
    let quarantine = "0283;6afcaf62;;"
    XCTAssertEqual(
      setxattr(module.path, "com.apple.quarantine", quarantine, quarantine.utf8.count, 0, 0), 0)
    try plugins.install()
    let copy = userFolder.appendingPathComponent("Segno.vst3/Contents/MacOS/Segno")
    var buffer = [UInt8](repeating: 0, count: 64)
    let length = getxattr(copy.path, "com.apple.quarantine", &buffer, buffer.count, 0, 0)
    XCTAssertEqual(length, quarantine.utf8.count)
    XCTAssertEqual(String(decoding: buffer.prefix(max(0, length)), as: UTF8.self), quarantine)
  }
}
