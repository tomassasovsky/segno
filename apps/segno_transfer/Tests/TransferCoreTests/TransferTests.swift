import Foundation
import XCTest

@testable import TransferCore

final class TransferTests: XCTestCase {
  private var root: URL!
  private var destination: URL!
  private var executable: URL!
  private var connection: Connection!
  private var repository: TransferRepository!

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    destination = root.appendingPathComponent("downloads")
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    executable = root.appendingPathComponent("fake-ssh")
    try writeExecutable(
      """
      #!/usr/bin/python3
      import os, shlex, sys
      command = shlex.split(sys.argv[-1])
      assert len(sys.argv[-1]) < 4096, 'The helper must travel over stdin, not the command line'
      os.execv('/usr/bin/python3', ['/usr/bin/python3'] + command[1:])
      """)
    let take = root.appendingPathComponent("a 'quoted' take")
    try FileManager.default.createDirectory(at: take, withIntermediateDirectories: true)
    try Data(
      #"{"slug":"perf-20260915-144716","sample_rate":48000,"capture_frames":16,"finalized":true}"#
        .utf8
    ).write(to: take.appendingPathComponent("performance.json"))
    var bytes = Data("RIFF".utf8)
    func word<T: FixedWidthInteger>(_ value: T) {
      var v = value.littleEndian
      withUnsafeBytes(of: &v) { bytes.append(contentsOf: $0) }
    }
    word(UInt32(164))
    bytes.append(Data("WAVEfmt ".utf8))
    word(UInt32(16))
    word(UInt16(3))
    word(UInt16(2))
    word(UInt32(48000))
    word(UInt32(384000))
    word(UInt16(8))
    word(UInt16(32))
    bytes.append(Data("data".utf8))
    word(UInt32(128))
    bytes.append(Data(repeating: 0, count: 128))
    try bytes.write(to: take.appendingPathComponent("master.wav"))
    connection = Connection(host: "appliance.example", root: root.path)
    repository = TransferRepository(ssh: try SSHClient(executable: executable))
  }

  override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

  private func writeExecutable(_ code: String) throws {
    try Data(code.utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
  }

  private func take() throws -> Recording {
    try XCTUnwrap(
      repository.catalog(connection: connection, token: CancellationToken()).recordings.first)
  }

  func testReadFetchesOnlyRequestedBytesAndRejectsChangedSource() throws {
    let recording = try take()
    let file = recording.files[0]
    let source = root.appendingPathComponent(recording.id).appendingPathComponent(file.path)
    let bytes = try Data(contentsOf: source)
    for range in [0..<2, 40..<52, 160..<172] {
      let data = try repository.read(
        recording: recording, file: file, offset: Int64(range.lowerBound), length: range.count,
        connection: connection, token: CancellationToken())
      XCTAssertEqual(data, bytes[range])
    }
    try bytes.write(to: source)
    XCTAssertThrowsError(
      try repository.read(
        recording: recording, file: file, offset: 0, length: 2,
        connection: connection, token: CancellationToken()))
  }

  func testReadRejectsInvalidRangesAndShortResponses() throws {
    let recording = try take()
    let file = recording.files[0]
    for (offset, length) in [(-1, 2), (0, 0), (0, 1_048_577), (171, 2), (Int64.max, 1)] {
      XCTAssertThrowsError(
        try repository.read(
          recording: recording, file: file, offset: Int64(offset), length: length,
          connection: connection, token: CancellationToken()))
    }
    try writeExecutable("#!/usr/bin/python3\nimport sys\nsys.stdout.buffer.write(b'x')\n")
    XCTAssertThrowsError(
      try repository.read(
        recording: recording, file: file, offset: 0, length: 2,
        connection: connection, token: CancellationToken()))
  }

  func testDownloadVerifiesAndRenamesWithoutOverwriting() throws {
    let recording = try take()
    let file = try XCTUnwrap(recording.files.first)
    let existing = destination.appendingPathComponent("My performance.wav")
    try Data("keep me".utf8).write(to: existing)
    var phases: [String] = []
    let result = try repository.download(
      recording: recording, file: file, name: "My performance",
      destination: destination, connection: connection, token: CancellationToken()
    ) { _, phase in phases.append(phase) }
    XCTAssertEqual(result.lastPathComponent, "My performance (2).wav")
    XCTAssertEqual(try Data(contentsOf: existing), Data("keep me".utf8))
    XCTAssertEqual(
      try Data(contentsOf: result),
      try Data(
        contentsOf: root.appendingPathComponent(recording.id).appendingPathComponent(file.path)))
    XCTAssertTrue(phases.contains("Verifying"))
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path).count, 2)
  }

  func testStaleSelectionLeavesNoPartialOrCompletedFile() throws {
    let recording = try take()
    let file = try XCTUnwrap(recording.files.first)
    try Data("changed".utf8).write(
      to: root.appendingPathComponent(recording.id).appendingPathComponent(file.path))
    XCTAssertThrowsError(
      try repository.download(
        recording: recording, file: file, name: "take.wav", destination: destination,
        connection: connection, token: CancellationToken(), progress: { _, _ in }))
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path), [])
  }

  func testHashMismatchRemovesTemporaryDownload() throws {
    let recording = try take()
    try writeExecutable(
      """
      #!/usr/bin/python3
      import json, os, shlex, sys
      command = shlex.split(sys.argv[-1])
      if command[2] == 'hash':
          print(json.dumps({'sha256': 'incorrect'}))
      else:
          os.execv('/usr/bin/python3', ['/usr/bin/python3'] + command[1:])
      """)
    XCTAssertThrowsError(
      try repository.download(
        recording: recording, file: recording.files[0], name: "take", destination: destination,
        connection: connection, token: CancellationToken(), progress: { _, _ in })
    ) { error in
      XCTAssertTrue(error.localizedDescription.contains("did not match"))
    }
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path), [])
  }

  func testCancelRunningTransferCleansUp() throws {
    let recording = try take()
    try writeExecutable(
      """
      #!/usr/bin/python3
      import sys, time
      sys.stdout.buffer.write(b'RIFF')
      sys.stdout.buffer.flush()
      time.sleep(30)
      """)
    let token = CancellationToken()
    let start = Date()
    XCTAssertThrowsError(
      try repository.download(
        recording: recording, file: recording.files[0], name: "take", destination: destination,
        connection: connection, token: token
      ) { bytes, _ in
        if bytes > 0 { token.cancel() }
      }
    ) { error in XCTAssertTrue(error is TransferError) }
    XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path), [])
  }

  func testNonzeroExitAfterPartialOutputDoesNotPublish() throws {
    let recording = try take()
    try writeExecutable(
      "#!/usr/bin/python3\nimport sys\nsys.stdout.write('partial')\nsys.exit(1)\n")
    XCTAssertThrowsError(
      try repository.download(
        recording: recording, file: recording.files[0], name: "take", destination: destination,
        connection: connection, token: CancellationToken(), progress: { _, _ in }))
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path), [])
  }

  func testConnectionAndFilenameValidationRejectsUnsafeInput() throws {
    for host in ["-oProxyCommand=evil", "a b", "a;pwd", ""] {
      XCTAssertThrowsError(try Connection(host: host).validate())
    }
    for name in ["../outside", "a/b", ".", "", "a:b", "a\0b", "a\\b"] {
      XCTAssertThrowsError(try DownloadName.validated(name))
    }
    XCTAssertEqual(try DownloadName.validated(" Live session "), "Live session.wav")
    XCTAssertEqual(try DownloadName.validated("Song.WAV"), "Song.WAV")
  }

  func testZeroExitShortAndOversizedTransfersCannotPublish() throws {
    let recording = try take()
    for size in [4, 2048] {
      try writeExecutable(
        """
        #!/usr/bin/python3
        import hashlib, json, shlex, sys
        action = shlex.split(sys.argv[-1])[2]
        payload = b'x' * \(size)
        if action == 'hash':
            print(json.dumps({'sha256': hashlib.sha256(payload).hexdigest()}))
        else:
            sys.stdout.buffer.write(payload)
        """)
      XCTAssertThrowsError(
        try repository.download(
          recording: recording, file: recording.files[0], name: "take", destination: destination,
          connection: connection, token: CancellationToken(), progress: { _, _ in }))
      XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path), [])
    }
  }

  func testCancelTerminatesSignalResistantProcess() throws {
    let recording = try take()
    try writeExecutable(
      """
      #!/usr/bin/python3
      import signal, sys, time
      signal.signal(signal.SIGTERM, signal.SIG_IGN)
      sys.stdout.buffer.write(b'RIFF')
      sys.stdout.buffer.flush()
      time.sleep(30)
      """)
    let token = CancellationToken()
    let start = Date()
    XCTAssertThrowsError(
      try repository.download(
        recording: recording, file: recording.files[0], name: "take", destination: destination,
        connection: connection, token: token
      ) { bytes, _ in
        if bytes > 0 { token.cancel() }
      })
    XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path), [])
  }

  func testWorksWithMinimalAppliancePython() throws {
    try writeExecutable(
      """
      #!/usr/bin/python3
      import builtins, shlex, sys
      command = shlex.split(sys.argv[-1])
      original_import = builtins.__import__
      def appliance_import(name, *args, **kwargs):
          if name in ('json', 'hashlib'):
              raise ImportError('Module not shipped by appliance: ' + name)
          return original_import(name, *args, **kwargs)
      builtins.__import__ = appliance_import
      sys.argv = ['-'] + command[2:]
      exec(compile(sys.stdin.read(), '<appliance>', 'exec'), {'__name__': '__main__'})
      """)
    let recording = try take()
    let result = try repository.download(
      recording: recording, file: recording.files[0], name: "Minimal Python",
      destination: destination, connection: connection, token: CancellationToken(),
      progress: { _, _ in })
    XCTAssertEqual(result.lastPathComponent, "Minimal Python.wav")
    XCTAssertEqual(try Data(contentsOf: result).count, 172)
  }

  // MARK: Live set

  private var takeFolder: URL { root.appendingPathComponent("a 'quoted' take") }

  /// Writes a Live set that refers to `references`, gzipped as Live and the
  /// console write it, plus a loop and a wet stem for it to use.
  private func writeLiveSet(
    _ references: [String] = ["master.wav", "loops/track0-lane0.wav", "stems/wet/track0.wav"],
    plugin: Bool = true, storeName: Bool = false
  ) throws {
    let master = try Data(contentsOf: takeFolder.appendingPathComponent("master.wav"))
    for path in ["loops/track0-lane0.wav", "stems/wet/track0.wav", "stems/dry/track0.wav"] {
      let url = takeFolder.appendingPathComponent(path)
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try master.write(to: url)
    }
    try Data("chains".utf8).write(to: takeFolder.appendingPathComponent("fx-chains.txt"))
    let clips = references.map {
      "<AudioClip><SampleRef><FileRef><RelativePathType Value=\"1\" /><RelativePath Value=\"\($0)\" /><Path Value=\"\($0)\" /></FileRef></SampleRef></AudioClip>"
    }
    let device =
      plugin
      ? "<PluginDevice><PluginDesc><Vst3PluginInfo Id=\"0\" /></PluginDesc></PluginDevice>" : ""
    let xml = root.appendingPathComponent("project.als")
    let head =
      #"<?xml version="1.0" encoding="UTF-8"?><Ableton><LiveSet><OriginalFileRef/><RelativePath Value="not-a-file-ref.wav" />"#
    let body: String = clips.joined() + device + "</LiveSet></Ableton>"
    try Data((head + body).utf8).write(to: xml)
    let gzip = Process()
    gzip.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
    gzip.arguments = (storeName ? ["-c"] : ["-c", "-n"]) + [xml.path]
    let output = takeFolder.appendingPathComponent("project.als")
    FileManager.default.createFile(atPath: output.path, contents: nil)
    gzip.standardOutput = try FileHandle(forWritingTo: output)
    try gzip.run()
    gzip.waitUntilExit()
    XCTAssertEqual(gzip.terminationStatus, 0)
    try FileManager.default.removeItem(at: xml)
  }

  private func files(in folder: URL) throws -> [String] {
    let enumerator = try XCTUnwrap(
      FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey]))
    return enumerator.compactMap { item in
      let url = item as! URL
      guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
      else { return nil }
      return String(
        url.standardizedFileURL.path.dropFirst(folder.standardizedFileURL.path.count + 1))
    }.sorted()
  }

  private func downloadLiveSet(
    _ recording: Recording, token: CancellationToken = CancellationToken(),
    progress: @escaping (Double, String) -> Void = { _, _ in }
  ) throws -> LiveSetCopy {
    try repository.downloadLiveSet(
      recording: recording, destination: destination, connection: connection, token: token,
      progress: progress)
  }

  func testLiveSetDownloadsExactlyWhatTheSetUses() throws {
    try writeLiveSet()
    let recording = try take()
    XCTAssertEqual(recording.liveSet?.path, "project.als")
    let copy = try downloadLiveSet(recording)
    XCTAssertEqual(copy.folder.lastPathComponent, "a 'quoted' take")
    XCTAssertTrue(copy.usesPlugins)
    XCTAssertFalse(copy.reused)
    XCTAssertEqual(
      try files(in: copy.folder),
      [
        ".segno-transfer.json", "loops/track0-lane0.wav", "master.wav", "project.als",
        "stems/wet/track0.wav",
      ])
    for path in ["project.als", "master.wav", "loops/track0-lane0.wav", "stems/wet/track0.wav"] {
      XCTAssertEqual(
        try Data(contentsOf: copy.folder.appendingPathComponent(path)),
        try Data(contentsOf: takeFolder.appendingPathComponent(path)), path)
    }
    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(atPath: destination.path), ["a 'quoted' take"])
    XCTAssertEqual(
      try LiveSet.read(copy.project).references,
      ["master.wav", "loops/track0-lane0.wav", "stems/wet/track0.wav"])
    // The folder is a Live Project, so Live saves the set in place (#1837).
    XCTAssertEqual(try projectInfo(in: copy.folder), [])
  }

  /// What the `Ableton Project Info` folder in `folder` holds.
  private func projectInfo(in folder: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(
      atPath: folder.appendingPathComponent(LiveSet.projectInfoName).path)
  }

  func testAVerifiedCopyWithoutAProjectFolderGetsOne() throws {
    try writeLiveSet(plugin: false)
    let recording = try take()
    let first = try downloadLiveSet(recording)
    // As a copy downloaded before #1837 left it.
    try FileManager.default.removeItem(
      at: first.folder.appendingPathComponent(LiveSet.projectInfoName))
    let second = try downloadLiveSet(recording)
    XCTAssertEqual(second, LiveSetCopy(folder: first.folder, usesPlugins: false, reused: true))
    XCTAssertEqual(try projectInfo(in: second.folder), [])
  }

  /// Makes the fake appliance log the path of every file it is asked to
  /// download, one per line, and returns the log.
  private func logDownloads() throws -> URL {
    let log = root.appendingPathComponent("downloads.log")
    try writeExecutable(
      """
      #!/usr/bin/python3
      import os, shlex, sys
      command = shlex.split(sys.argv[-1])
      if command[2] == 'download':
          with open(\(String(reflecting: log.path)), 'a') as log:
              log.write(command[5] + '\\n')
      os.execv('/usr/bin/python3', ['/usr/bin/python3'] + command[1:])
      """)
    return log
  }

  private func downloads(_ log: URL) -> [String] {
    ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
  }

  /// Replaces the copy's set with one that refers to `references`, as Live
  /// writes it on save, and returns its bytes.
  private func edit(_ copy: LiveSetCopy, references: [String]) throws -> Data {
    let console = try Data(contentsOf: takeFolder.appendingPathComponent("project.als"))
    try writeLiveSet(references, plugin: false)
    let edited = try Data(contentsOf: takeFolder.appendingPathComponent("project.als"))
    try console.write(to: takeFolder.appendingPathComponent("project.als"))
    XCTAssertNotEqual(edited, console)
    try edited.write(to: copy.project)
    return edited
  }

  func testAnEditedSetReopensAsItIs() throws {
    try writeLiveSet()
    let recording = try take()
    let first = try downloadLiveSet(recording)
    // Saved in Live: its own audio, a file outside the take, a file
    // collected into the project, and no plugins any more.
    let edited = try edit(
      first,
      references: ["master.wav", "stems/wet/track0.wav", "Samples/Imported/new.wav", "../out.wav"]
    )
    let log = try logDownloads()
    let second = try downloadLiveSet(recording)
    XCTAssertEqual(second, LiveSetCopy(folder: first.folder, usesPlugins: false, reused: true))
    XCTAssertEqual(try Data(contentsOf: second.project), edited)
    XCTAssertEqual(downloads(log), [])
    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(atPath: destination.path), ["a 'quoted' take"])
    // A set changed on the console since does not replace the user's.
    try writeLiveSet(["master.wav"])
    XCTAssertEqual(try downloadLiveSet(try take()).folder, first.folder)
    XCTAssertEqual(try Data(contentsOf: first.project), edited)
  }

  func testAMissingOrChangedAudioFileIsFetchedAgainAndTheSetIsKept() throws {
    try writeLiveSet()
    let copy = try downloadLiveSet(try take())
    let edited = try edit(copy, references: ["master.wav", "stems/wet/track0.wav"])
    try FileManager.default.removeItem(
      at: copy.folder.appendingPathComponent("stems/wet/track0.wav"))
    // Changed without changing its length.
    let master = copy.folder.appendingPathComponent("master.wav")
    var bytes = try Data(contentsOf: master)
    bytes[bytes.count - 1] ^= 1
    try bytes.write(to: master)
    // Broken too, but the edited set no longer uses it.
    try Data("x".utf8).write(to: copy.folder.appendingPathComponent("loops/track0-lane0.wav"))
    let log = try logDownloads()

    // The catalog read again: writing the edit touched the take's files.
    let reopened = try downloadLiveSet(try take())

    XCTAssertEqual(reopened, LiveSetCopy(folder: copy.folder, usesPlugins: false, reused: true))
    XCTAssertEqual(downloads(log), ["master.wav", "stems/wet/track0.wav"])
    XCTAssertEqual(try Data(contentsOf: reopened.project), edited)
    for path in ["master.wav", "stems/wet/track0.wav"] {
      XCTAssertEqual(
        try Data(contentsOf: copy.folder.appendingPathComponent(path)),
        try Data(contentsOf: takeFolder.appendingPathComponent(path)), path)
    }
    XCTAssertEqual(
      try files(in: copy.folder),
      [
        ".segno-transfer.json", "loops/track0-lane0.wav", "master.wav", "project.als",
        "stems/wet/track0.wav",
      ])
    // The record holds the files fetched again: the next open fetches
    // nothing.
    _ = try downloadLiveSet(try take())
    XCTAssertEqual(downloads(log), ["master.wav", "stems/wet/track0.wav"])
  }

  func testAFileMissingHereAndOnTheApplianceIsReported() throws {
    try writeLiveSet()
    let copy = try downloadLiveSet(try take())
    for folder in [copy.folder, takeFolder] {
      try FileManager.default.removeItem(at: folder.appendingPathComponent("stems/wet/track0.wav"))
    }
    let project = try Data(contentsOf: copy.project)
    XCTAssertThrowsError(try downloadLiveSet(try take())) { error in
      XCTAssertTrue(
        error.localizedDescription.contains(
          "missing from the downloaded copy and from the appliance"),
        error.localizedDescription)
    }
    XCTAssertEqual(try Data(contentsOf: copy.project), project)
  }

  func testWithNoLocalCopyAFreshOneIsDownloaded() throws {
    try writeLiveSet()
    let recording = try take()
    // A folder of the take's name that no download left is not a copy.
    let other = destination.appendingPathComponent("a 'quoted' take", isDirectory: true)
    try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
    let first = try downloadLiveSet(recording)
    XCTAssertEqual(first.folder.lastPathComponent, "a 'quoted' take (2)")
    XCTAssertFalse(first.reused)
    // Nor is one whose set no longer reads.
    try Data("not a set".utf8).write(to: first.project)
    let second = try downloadLiveSet(recording)
    XCTAssertEqual(second.folder.lastPathComponent, "a 'quoted' take (3)")
    XCTAssertFalse(second.reused)
    // Once that copy is gone, the next open downloads a fresh one.
    try FileManager.default.removeItem(at: second.folder)
    let third = try downloadLiveSet(recording)
    XCTAssertEqual(third.folder.lastPathComponent, "a 'quoted' take (3)")
    XCTAssertFalse(third.reused)
    XCTAssertEqual(try projectInfo(in: third.folder), [])
  }

  func testALiveSetThatFailsVerificationPublishesNothing() throws {
    try writeLiveSet()
    let recording = try take()
    try writeExecutable(
      """
      #!/usr/bin/python3
      import json, os, shlex, sys
      command = shlex.split(sys.argv[-1])
      if command[2] == 'hash' and command[5] != 'project.als':
          print(json.dumps({'sha256': 'incorrect'}))
      else:
          os.execv('/usr/bin/python3', ['/usr/bin/python3'] + command[1:])
      """)
    XCTAssertThrowsError(try downloadLiveSet(recording)) { error in
      XCTAssertTrue(error.localizedDescription.contains("did not match"))
    }
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path), [])
  }

  func testCancellingALiveSetPublishesNothing() throws {
    try writeLiveSet()
    let recording = try take()
    let token = CancellationToken()
    XCTAssertThrowsError(
      try downloadLiveSet(recording, token: token) { _, phase in
        if phase.contains(" of ") { token.cancel() }
      }
    ) { error in
      guard case .cancelled = error as? TransferError else { return XCTFail("\(error)") }
    }
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path), [])
  }

  func testALiveSetUsingAFileTheTakeDoesNotOfferIsRefused() throws {
    for (references, message) in [
      (["master.wav", "loops/missing.wav"], "missing or still being saved"),
      (["../outside.wav"], "outside its take"),
      (["fx-chains.txt"], "missing or still being saved"),
      ([], "has no audio"),
    ] {
      try writeLiveSet(references)
      XCTAssertThrowsError(try downloadLiveSet(try take()), "\(references)") { error in
        XCTAssertTrue(error.localizedDescription.contains(message), error.localizedDescription)
      }
      XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path), [])
    }
  }

  func testLiveSetReadsAGzipHeaderThatNamesTheFile() throws {
    try writeLiveSet(["master.wav"], plugin: false, storeName: true)
    let contents = try LiveSet.read(takeFolder.appendingPathComponent("project.als"))
    XCTAssertEqual(contents, LiveSet.Contents(references: ["master.wav"], usesPlugins: false))
    try Data("not gzip".utf8).write(to: takeFolder.appendingPathComponent("project.als"))
    XCTAssertThrowsError(try LiveSet.read(takeFolder.appendingPathComponent("project.als")))
  }

  func testATakeWithoutALiveSetHasNone() throws {
    XCTAssertNil(try take().liveSet)
    XCTAssertThrowsError(try downloadLiveSet(try take())) { error in
      XCTAssertEqual(error.localizedDescription, LiveSet.missing)
    }
  }
}
