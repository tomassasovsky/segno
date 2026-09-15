import AppKit
import SwiftUI
import TransferCore

@main
struct SegnoTransferApp: App {
  @StateObject private var model: AppModel
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

  init() {
    do {
      let repository = TransferRepository(ssh: try SSHClient())
      _model = StateObject(wrappedValue: AppModel(repository: repository))
    } catch {
      let alert = NSAlert()
      alert.messageText = "Segno Transfer could not start"
      alert.informativeText = error.localizedDescription
      alert.runModal()
      exit(1)
    }
  }

  var body: some Scene {
    WindowGroup("Segno Transfer") {
      ContentView(model: model)
        .frame(minWidth: 920, minHeight: 600)
        .onAppear {
          delegate.model = model
          if !model.connection.host.isEmpty && !model.connected && !model.busy { model.connect() }
        }
    }
    .defaultSize(width: 1100, height: 730)
    .commands { CommandGroup(replacing: .newItem) {} }
  }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  weak var model: AppModel?
  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApplication.shared.setActivationPolicy(.regular)
    NSApplication.shared.activate(ignoringOtherApps: true)
  }
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
  func applicationWillTerminate(_ notification: Notification) { model?.closePreview() }
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard let model else { return .terminateNow }
    if model.busy {
      let alert = NSAlert()
      alert.messageText = "A transfer is in progress"
      alert.informativeText =
        "Keep Segno Transfer open until it finishes, or cancel the transfer and quit."
      alert.addButton(withTitle: "Keep Open")
      alert.addButton(withTitle: "Cancel and Quit")
      guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
      model.cancel()
    }
    Task {
      while model.busy { try? await Task.sleep(for: .milliseconds(100)) }
      await model.finishForTermination()
      sender.reply(toApplicationShouldTerminate: true)
    }
    return .terminateLater
  }
}
