import AppKit
import LauncherCore
import SwiftUI

struct BF3View: View {
  @Bindable var model: BF3Model

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Battlefield 3").font(.largeTitle.bold())
      Text(model.message).font(.callout).foregroundStyle(.secondary).lineLimit(4)
        .frame(maxWidth: .infinity, alignment: .leading)
      if model.rosetta.state == .missing {
        Button("Install Rosetta") { Task { await model.rosetta.install() } }
      }
      GroupBox("1. EA app") {
        HStack {
          Button("Open EA App") { Task { await model.openClient() } }
            .disabled(model.busy || !model.status.prepared)
          Text(clientLine).font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
      }
      GroupBox("2. Battlelog (press Play there)") {
        HStack {
          Button("Campaign") { Task { await model.openStore(page: "singleplayer") } }
          Button("Multiplayer") { Task { await model.openStore(page: "multiplayer") } }
          Text(
            model.status.browser.map { "in \($0)" }
              ?? "needs Chrome, Chromium, Edge, Brave or Vivaldi"
          )
          .font(.caption).foregroundStyle(.secondary)
        }.disabled(model.busy || !model.status.prepared)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      GroupBox("Game settings") {
        HStack {
          Text("Full screen at the display's size, set at every start")
            .font(.caption).foregroundStyle(.secondary)
          Toggle(
            "x87 sidecar",
            isOn: Binding(
              get: { model.status.sidecar }, set: { on in Task { await model.setSidecar(on) } }))
        }.disabled(model.busy || !model.status.profile || model.status.running.contains("bf3.exe"))
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      HStack {
        Button("Stop") { Task { await model.stop() } }.disabled(model.busy || !model.status.server)
        Button("Show Logs") { model.openLogs() }
        Spacer()
        if model.busy { ProgressView().controlSize(.small) }
      }
    }
    .padding(20)
    .frame(minWidth: 560, minHeight: 380)
  }

  private var clientLine: String {
    if !model.status.prepared { return "the Windows folder is not ready" }
    switch model.status.client {
    case "ready": return "signed in, Battlefield 3 ready"
    case "notReady": return "running, not signed in (sign in in the EA window)"
    case "starting": return "starting"
    default: return "not running"
    }
  }
}

final class BF3AppDelegate: NSObject, NSApplicationDelegate {
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

  /// Quitting stops the Windows side, which ends a running game, so that is confirmed first.
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard !PrefixActivity.running(["bf3.exe"]).isEmpty else { return .terminateNow }
    let alert = NSAlert()
    alert.messageText = "Quit and stop Battlefield 3?"
    alert.informativeText =
      "Quitting stops the EA app and the game, so PunkBuster does not keep running."
    alert.addButton(withTitle: "Quit")
    alert.addButton(withTitle: "Cancel")
    return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
  }

  func applicationWillTerminate(_ notification: Notification) {
    let bundle = Bundle.main.bundleURL
    BF3Model.stopOnQuit(
      helper: bundle.appendingPathComponent("Contents/Helpers/BF3Session"), bundle: bundle,
      support: BF3Model.supportFolder())
  }
}

@main
struct BF3App: App {
  @NSApplicationDelegateAdaptor(BF3AppDelegate.self) private var delegate
  @State private var model = BF3Model()

  var body: some Scene {
    Window("Battlefield 3", id: "launcher") {
      BF3View(model: model)
        .task { await model.start() }
        .task { await model.supervise() }
    }
    .defaultSize(width: 600, height: 420)
  }
}
