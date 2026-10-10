import AppKit
import HubCore
import SwiftUI

final class GameHubAppDelegate: NSObject, NSApplicationDelegate {
  weak var model: HubModel?

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApplication.shared.setActivationPolicy(.regular)
    NSApp.activate()
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    true
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    if model?.isCreatingInstance == true {
      return .terminateCancel
    }
    return .terminateNow
  }
}

@main
struct GameHubApp: App {
  @NSApplicationDelegateAdaptor(GameHubAppDelegate.self) private var delegate
  @State private var model = HubModel()

  var body: some Scene {
    WindowGroup("Game Hub", id: "main") {
      HubView(model: model)
        .onAppear {
          delegate.model = model
        }
    }
    .defaultSize(width: 1200, height: 700)
  }
}
