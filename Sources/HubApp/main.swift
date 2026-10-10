import AppKit
import HubCore
import SwiftUI

final class GameHubAppDelegate: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApplication.shared.setActivationPolicy(.regular)
    NSApp.activate()
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    true
  }
}

@main
struct GameHubApp: App {
  @NSApplicationDelegateAdaptor(GameHubAppDelegate.self) private var delegate
  @State private var model = HubModel()

  var body: some Scene {
    WindowGroup("Game Hub", id: "main") {
      HubView(model: model)
    }
    .defaultSize(width: 1200, height: 700)
  }
}
