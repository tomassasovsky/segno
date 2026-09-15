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
      if command[3] == 'hash':
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
        action = shlex.split(sys.argv[-1])[3]
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
      sys.argv = ['-c'] + command[3:]
      exec(compile(command[2], '<appliance>', 'exec'), {'__name__': '__main__'})
      """)
    let recording = try take()
    let result = try repository.download(
      recording: recording, file: recording.files[0], name: "Minimal Python",
      destination: destination, connection: connection, token: CancellationToken(),
      progress: { _, _ in })
    XCTAssertEqual(result.lastPathComponent, "Minimal Python.wav")
    XCTAssertEqual(try Data(contentsOf: result).count, 172)
  }
}
