import AppKit
import Foundation
import LauncherCore
import UniformTypeIdentifiers

extension LauncherModel {
  func readSetupProfile() async throws -> GameSettings? {
    let panel = NSOpenPanel()
    panel.title = "Import graphics and controller setup"
    panel.message =
      "Review the imported settings before saving or playing. Your careers and cheats stay unchanged."
    panel.allowedContentTypes = [.json]
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    guard await panel.begin() == .OK, let url = panel.url else { return nil }
    return try SetupProfile.read(BoundedFile.read(url, limit: 65_536)).applying(to: settings)
  }

  func writeSetupProfile(paths: AppPaths) async throws {
    let data = try SetupProfile(settings: settings).encoded()
    let panel = NSSavePanel()
    panel.title = "Export graphics and controller setup"
    panel.message = "Includes the current graphics settings and selected controller mappings."
    panel.allowedContentTypes = [.json]
    panel.nameFieldStringValue = "Most Wanted Setup.json"
    guard await panel.begin() == .OK, let url = panel.url else { return }
    guard !url.resolvingSymlinksInPath().path.hasPrefix(paths.support.path + "/") else {
      throw LauncherError.operation("Choose an export location outside the player data folder.")
    }
    try data.write(to: url, options: .atomic)
  }
}
