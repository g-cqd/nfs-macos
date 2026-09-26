import AppKit
import Foundation
import LauncherCore

extension LauncherModel {
  func importRequest() async throws -> SaveRequest? {
    let panel = NSOpenPanel()
    panel.title = "Import a Most Wanted profile"
    panel.message =
      "Choose the save file inside the player's folder. Existing progress is backed up before replacement."
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    guard await panel.begin() == .OK, let url = panel.url else { return nil }
    let save = try CareerSave(BoundedFile.read(url, limit: CareerSave.size))
    return .replace(
      profile: save.alias, data: save.data,
      expected: saveEditor.fingerprintForReplacement(of: save.alias))
  }

  func exportProfile(paths: AppPaths) async throws {
    guard let profile = saveEditor.profile else {
      throw LauncherError.operation("Select a profile to export.")
    }
    let source = try SaveStore(paths: paths).profileURL(profile.id)
    let bytes = try BoundedFile.read(source, limit: CareerSave.size)
    _ = try CareerSave(bytes)
    let panel = NSSavePanel()
    panel.title = "Export profile"
    panel.nameFieldStringValue = profile.id + ".save"
    guard await panel.begin() == .OK, let url = panel.url else { return }
    guard !url.resolvingSymlinksInPath().path.hasPrefix(paths.support.path + "/") else {
      throw LauncherError.operation("Choose an export location outside the player data folder.")
    }
    try bytes.write(to: url, options: .atomic)
  }
}
