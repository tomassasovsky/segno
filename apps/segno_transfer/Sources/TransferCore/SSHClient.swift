import Darwin
import Foundation

public final class SSHClient {
  private let executable: URL
  private let helper: String

  public init(executable: URL = URL(fileURLWithPath: "/usr/bin/ssh")) throws {
    self.executable = executable
    let resources: Bundle
    if Bundle.main.bundleURL.pathExtension == "app" {
      guard
        let url = Bundle.main.resourceURL?.appendingPathComponent(
          "SegnoTransfer_TransferCore.bundle"),
        let bundle = Bundle(url: url)
      else {
        throw TransferError.message(
          "The app is missing its resources. Rebuild or reinstall Segno Transfer.")
      }
      resources = bundle
    } else {
      resources = Bundle.module
    }
    guard let resource = resources.url(forResource: "appliance", withExtension: "py") else {
      throw TransferError.message(
        "The app is missing its appliance helper. Rebuild or reinstall Segno Transfer.")
    }
    helper = try String(contentsOf: resource, encoding: .utf8)
  }

  public static func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
  }

  public func request(
    _ request: [String: String], connection: Connection, to output: URL,
    token: CancellationToken, maximumBytes: Int64,
    progress: @escaping (Int64) -> Void = { _ in }
  ) throws {
    try connection.validate()
    try token.check()
    let fields = ["action", "root", "recording", "file", "version"].map { request[$0] ?? "" }
    let command = (["python3", "-c", helper] + fields).map(Self.shellQuote).joined(separator: " ")
    let process = Process()
    process.executableURL = executable
    var arguments = [
      "-T", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes",
      "-o", "ConnectTimeout=10", "-o", "ServerAliveInterval=10",
      "-o", "ServerAliveCountMax=3", "-o", "LogLevel=ERROR",
    ]
    if !connection.identityFile.isEmpty { arguments += ["-i", connection.identityFile] }
    arguments += ["-l", connection.user, connection.host, command]
    process.arguments = arguments
    process.standardInput = FileHandle.nullDevice
    let outputHandle = try FileHandle(forWritingTo: output)
    let errors = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    FileManager.default.createFile(
      atPath: errors.path, contents: nil, attributes: [.posixPermissions: 0o600])
    let errorHandle = try FileHandle(forWritingTo: errors)
    defer {
      try? outputHandle.close()
      try? errorHandle.close()
      try? FileManager.default.removeItem(at: errors)
    }
    process.standardOutput = outputHandle
    process.standardError = errorHandle
    try process.run()
    var lastSize: Int64 = -1
    var lastChange = Date()
    var failure: Error?
    while process.isRunning {
      let size =
        ((try? FileManager.default.attributesOfItem(atPath: output.path)[.size]) as? NSNumber)?
        .int64Value ?? 0
      if size != lastSize {
        lastSize = size
        lastChange = Date()
        progress(size)
      }
      if token.isCancelled { failure = TransferError.cancelled }
      if size > maximumBytes {
        failure = TransferError.message(
          "The appliance returned more data than expected. Refresh and try again.")
      }
      if Date().timeIntervalSince(lastChange) > 120 {
        failure = TransferError.message(
          "The appliance stopped responding. Check its connection and try again.")
      }
      if failure != nil {
        process.terminate()
        for _ in 0..<20 where process.isRunning { Thread.sleep(forTimeInterval: 0.05) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        break
      }
      Thread.sleep(forTimeInterval: 0.08)
    }
    process.waitUntilExit()
    if let failure { throw failure }
    try token.check()
    guard process.terminationStatus == 0 else {
      let detail = (try? String(contentsOf: errors, encoding: .utf8)) ?? ""
      if detail.contains("Permission denied") {
        throw TransferError.message(
          "The appliance rejected the connection. Check the username and SSH key in Connection settings, or unlock your existing SSH key."
        )
      }
      if detail.contains("Host key verification failed")
        || detail.contains("REMOTE HOST IDENTIFICATION HAS CHANGED")
      {
        throw TransferError.message(
          "This appliance's identity is not trusted by your Mac. Connect once with SSH to verify its identity, then try again."
        )
      }
      if let range = detail.range(of: "Segno Transfer: ") {
        throw TransferError.message(
          String(detail[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines))
      }
      throw TransferError.message(
        detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          ? "Could not connect to the appliance."
          : String(detail.suffix(2000)).trimmingCharacters(in: .whitespacesAndNewlines))
    }
    let size =
      (try FileManager.default.attributesOfItem(atPath: output.path)[.size] as? NSNumber)?
      .int64Value ?? 0
    guard size <= maximumBytes else {
      throw TransferError.message("The appliance returned too much data.")
    }
    progress(size)
  }
}
