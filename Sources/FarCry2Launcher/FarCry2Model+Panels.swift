import AppKit
import FarCry2Core
import Foundation
import LauncherCore
import UniformTypeIdentifiers

extension FarCry2Model {
  func importGameFolder() async throws {
    guard
      let source = await chooseFolder(
        title: "Import Far Cry 2",
        message:
          "Select your installed Windows Far Cry 2 folder, the one that contains bin and Data_Win32. A private copy is created; your folder is not changed."
      )
    else { return }
    try Task.checkCancellation()
    finishGameImport(try await service.perform(.importGame(source)))
  }

  func importSetupFile() async throws {
    let panel = NSOpenPanel()
    panel.title = "Import Far Cry 2 setup"
    panel.message = "Review the imported graphics settings before applying them."
    panel.allowedContentTypes = [.json]
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    guard await panel.begin() == .OK, let url = panel.url else { return }
    let imported = try await service.readSetup(url)
    try Task.checkCancellation()
    settings = imported
  }

  func exportSetupFile() async throws {
    try settings.validate()
    let panel = NSSavePanel()
    panel.title = "Export Far Cry 2 setup"
    panel.message = "Exports graphics and renderer settings. Saves are backed up separately."
    panel.allowedContentTypes = [.json]
    panel.nameFieldStringValue = "Far Cry 2 Setup.json"
    guard await panel.begin() == .OK, let url = panel.url else { return }
    try Task.checkCancellation()
    try await service.writeSetup(settings, to: url)
  }

  private func chooseFolder(title: String, message: String) async -> URL? {
    let panel = NSOpenPanel()
    panel.title = title
    panel.message = message
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    guard await panel.begin() == .OK else { return nil }
    return panel.url
  }
}
