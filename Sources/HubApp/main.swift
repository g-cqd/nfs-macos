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
    let reason: String
    if model?.locations.isBusy == true {
      reason =
        "The data store is being moved, copied or saved. "
        + "Wait for it to finish, or cancel it in Settings."
    } else if model?.isCreatingInstance == true {
      reason = "An internal instance is being created. Wait for it to finish."
    } else {
      return .terminateNow
    }
    let alert = NSAlert()
    alert.messageText = "Game Hub is busy"
    alert.informativeText = reason
    alert.addButton(withTitle: "OK")
    alert.runModal()
    return .terminateCancel
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

    Settings {
      SettingsView(locations: model.locations)
    }
  }
}
