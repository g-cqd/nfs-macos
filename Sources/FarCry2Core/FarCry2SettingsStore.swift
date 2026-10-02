import Foundation
import LauncherCore

/// Reads and applies settings under the caller's exclusive session lock.
package struct FarCry2SettingsStore {
  private let paths: AppPaths
  private let data: FarCry2UserData
  private let files = FileManager.default

  package init(paths: AppPaths) {
    self.paths = paths
    data = FarCry2UserData(paths: paths)
  }

  private var rendererFile: URL {
    paths.currentGame.appendingPathComponent(GameKind.farcry2.rendererConfiguration)
  }
  private var registryFile: URL { paths.prefix.appendingPathComponent("user.reg") }
  /// The launcher-owned options; kept beside the player data so they survive a rebuilt prefix.
  package var optionsFile: URL { paths.support.appendingPathComponent("farcry2-options.json") }

  /// The profile and renderer values currently on disk, with defaults for anything absent.
  package func load() throws(LauncherError) -> (
    settings: FarCry2Settings, state: FarCry2ProfileState
  ) {
    let renderer = try rendererText()
    let registry = try optionalText(registryFile)
    let launcher = try optionalData(optionsFile)
    func settings(_ profile: GamerProfileDocument?) throws(LauncherError) -> FarCry2Settings {
      try FarCry2Settings(
        profile: profile, renderer: renderer, registry: registry, launcher: launcher)
    }
    guard files.fileExists(atPath: data.profileFile.path) else {
      return (try settings(nil), .missing)
    }
    do {
      let document = try GamerProfileDocument(BoundedFile.read(data.profileFile))
      guard document.hasElement(["RenderProfile"]) else {
        return (try settings(nil), .unrecognized)
      }
      return (try settings(document), .ready)
    } catch {
      return (try settings(nil), .unrecognized)
    }
  }

  /// Writes the game profile and renderer file as one recoverable transaction.
  /// A missing or unrecognised profile is left alone; the renderer file is still updated.
  @discardableResult
  package func apply(_ settings: FarCry2Settings) throws(LauncherError) -> FarCry2ProfileState {
    try settings.validate()
    var changes: [FileChange] = []
    var state = FarCry2ProfileState.missing
    if files.fileExists(atPath: data.profileFile.path) {
      let original = try BoundedFile.read(data.profileFile)
      var edited: Data?
      do {
        var document = try GamerProfileDocument(original)
        _ = try settings.applying(to: &document)
        edited = document.data
      } catch { state = .unrecognized }
      if let edited {
        try keepOriginal(original)
        changes.append(FileChange(url: data.profileFile, bytes: edited))
        state = .ready
      }
    }
    changes.append(
      FileChange(
        url: rendererFile,
        bytes: Data(try settings.rendererConfig(original: rendererText() ?? "").utf8)))
    if let registry = try optionalText(registryFile),
      let edited = try settings.registryConfig(original: registry)
    {
      changes.append(FileChange(url: registryFile, bytes: Data(edited.utf8)))
    }
    changes.append(FileChange(url: optionsFile, bytes: try settings.launcherData()))
    try FileTransaction(root: paths.support).apply(changes)
    return state
  }

  private func rendererText() throws(LauncherError) -> String? {
    try optionalText(rendererFile)
  }

  private func optionalText(_ url: URL) throws(LauncherError) -> String? {
    files.fileExists(atPath: url.path) ? try BoundedFile.text(url) : nil
  }

  private func optionalData(_ url: URL) throws(LauncherError) -> Data? {
    files.fileExists(atPath: url.path) ? try BoundedFile.read(url, limit: 65_536) : nil
  }

  /// Saves the game's untouched profile once, so the starter's first edit is always reversible.
  private func keepOriginal(_ bytes: Data) throws(LauncherError) {
    let backups = FarCry2Backups(paths: paths)
    guard !files.fileExists(atPath: backups.originalProfile.path) else { return }
    do {
      try files.createDirectory(at: backups.root, withIntermediateDirectories: true)
      try bytes.write(to: backups.originalProfile, options: .withoutOverwriting)
    } catch {
      throw .operation("Could not keep the game's original profile: \(error.localizedDescription)")
    }
  }
}
