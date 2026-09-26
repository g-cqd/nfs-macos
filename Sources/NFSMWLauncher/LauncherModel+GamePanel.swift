import AppKit
import Foundation

extension LauncherModel {
  func readGameDataFolder() async -> URL? {
    let panel = NSOpenPanel()
    panel.title = "Import Most Wanted game data"
    panel.message =
      "Choose your installed Most Wanted (2005) PC 1.3 folder containing speed.exe. The app verifies and copies the game files. Your saves stay in their current location."
    panel.prompt = "Import"
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    guard await panel.begin() == .OK else { return nil }
    return panel.url
  }
}
