import AppKit
import CoD4Core
import Foundation
import LauncherCore
import UniformTypeIdentifiers

extension CoD4Model {
  func importGameFolder() async throws {
    guard
      let source = await chooseFolder(
        title: "Import Call of Duty 4",
        message:
          "Select your Windows game folder containing iw3sp.exe, main, and zone. A private copy will be created."
      )
    else { return }
    try Task.checkCancellation()
    let operation = CoD4Operation.importGame(source, mode)
    let snapshot = try await service.perform(operation)
    try Task.checkCancellation()
    finishGameImport(snapshot, operation: operation)
  }

  func importSetupFile() async throws {
    let panel = NSOpenPanel()
    panel.title = "Import Call of Duty 4 setup"
    panel.message =
      "Review the imported graphics, audio, and keyboard settings before applying them."
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
    panel.title = "Export Call of Duty 4 setup"
    panel.message =
      "Exports settings and explicit keyboard bindings. Profiles and saves are exported separately."
    panel.allowedContentTypes = [.json]
    panel.nameFieldStringValue = "Call of Duty 4 Setup.json"
    guard await panel.begin() == .OK, let url = panel.url else { return }
    try Task.checkCancellation()
    try await service.writeSetup(settings, to: url)
  }

  func importProfileFolder() async throws {
    guard CoD4ProfileStore.validName(newProfileName) else {
      throw LauncherError.operation(
        "Enter a profile name using 1–16 letters, digits, spaces, underscores, or hyphens.")
    }
    guard
      let source = await chooseFolder(
        title: "Import player profile",
        message: "Select the player profile folder containing config.cfg and its save folder.")
    else { return }
    try Task.checkCancellation()
    let operation = CoD4Operation.profile(
      .init(action: .importProfile, name: newProfileName, sourcePath: source.path), mode: mode)
    let snapshot = try await service.perform(operation)
    try Task.checkCancellation()
    load(snapshot, operation: operation)
    newProfileName = ""
  }

  func exportProfileFolder() async throws {
    guard currentProfile?.isInstalled == true else { return }
    let panel = NSSavePanel()
    panel.title = "Export player profile"
    panel.message =
      "Choose a new folder name for the copied profile, configuration, and campaign saves."
    panel.nameFieldStringValue = profileSelection
    panel.canCreateDirectories = true
    guard await panel.begin() == .OK, let destination = panel.url else { return }
    try Task.checkCancellation()
    let operation = CoD4Operation.profile(
      .init(action: .exportProfile, name: profileSelection, destinationPath: destination.path),
      mode: mode)
    load(try await service.perform(operation), operation: operation)
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
