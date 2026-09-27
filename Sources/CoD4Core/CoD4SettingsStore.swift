import Foundation
import LauncherCore

/// Applies campaign or multiplayer settings under the caller's exclusive session lock.
package struct CoD4SettingsStore {
  private let paths: AppPaths
  private let files = FileManager.default
  package init(paths: AppPaths) { self.paths = paths }

  package func load(profile: String, mode: CoD4Mode) throws -> CoD4Settings {
    let url = try CoD4ProfileStore(paths: paths).profileURL(profile).appendingPathComponent(
      mode.configuration)
    let source =
      files.fileExists(atPath: url.path)
      ? url : paths.resources.appendingPathComponent("Defaults/" + mode.configuration)
    var settings = try CoD4Settings(config: BoundedFile.text(source))
    let renderer = try ConfigText(
      BoundedFile.text(paths.currentGame.appendingPathComponent("mtld3d.conf")))
    for definition in CoD4Catalog.settings where definition.isRenderer {
      if let value = renderer.value(section: "", key: definition.id), definition.accepts(value) {
        settings.values[definition.id] = value
      }
    }
    return settings
  }

  package func apply(_ request: CoD4LaunchRequest) throws {
    try request.settings.validate()
    let profile = try CoD4ProfileStore(paths: paths).profileURL(request.profile)
    guard files.fileExists(atPath: profile.path) else {
      throw LauncherError.operation("Select an installed profile.")
    }
    let config = profile.appendingPathComponent(request.mode.configuration)
    let source =
      files.fileExists(atPath: config.path)
      ? config : paths.resources.appendingPathComponent("Defaults/" + request.mode.configuration)
    let renderer = paths.currentGame.appendingPathComponent("mtld3d.conf")
    let text = try request.settings.applying(to: BoundedFile.text(source), mode: request.mode)
    let rendererText = try request.settings.rendererConfig(original: BoundedFile.text(renderer))
    try FileTransaction(root: paths.support).apply([
      FileChange(url: config, bytes: Data(text.utf8)),
      FileChange(url: renderer, bytes: Data(rendererText.utf8)),
      FileChange(
        url: paths.saves.appendingPathComponent("profiles/active.txt"),
        bytes: Data(request.profile.utf8)),
    ])
  }

  package func selectedProfile(preferred: String? = nil) throws -> String {
    let installed = try CoD4ProfileStore(paths: paths).list().filter(\.isInstalled)
    if let preferred {
      guard installed.contains(where: { $0.name == preferred }) else {
        throw LauncherError.operation("The selected profile is not installed.")
      }
      return preferred
    }
    let active = paths.saves.appendingPathComponent("profiles/active.txt")
    if files.fileExists(atPath: active.path) {
      let value = String(decoding: try BoundedFile.read(active, limit: 64), as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      if installed.contains(where: { $0.name == value }) { return value }
    }
    return installed.first?.name ?? ""
  }
}
