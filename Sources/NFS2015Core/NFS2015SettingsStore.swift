import Foundation
import LauncherCore

/// Reads and writes the game's own options file, and this app's copy of the chosen values.
///
/// The options file lives beside the player's saves, below the Windows user profile. The
/// installed game wrote `Documents/Need For Speed/settings/PROFILEOPTIONS_profile` with one
/// `Key Value` line per option; `PROFILEOPTIONS` beside it is a packed binary blob this app
/// never touches. A real Windows profile often links `Documents` at the player's own folder,
/// so that link is followed deliberately: these are the player's settings, in the player's
/// place, and the app changes nothing else there.
package struct NFS2015SettingsStore {
  /// The options file, relative to the Windows user profile.
  package static let optionsPath = "Documents/Need For Speed/settings/PROFILEOPTIONS_profile"

  private let support: URL
  private let install: NFS2015Install?

  package init(support: URL, install: NFS2015Install?) {
    self.support = support
    self.install = install
  }

  /// This app's record of the values the player chose, kept outside the game's folder.
  package var preferences: URL { support.appendingPathComponent("settings.json") }

  /// The game's options file, or nil until the game has written one.
  package func optionsFile() throws(LauncherError) -> URL? {
    guard let install else { return nil }
    guard
      let url = try GuestPath.resolve(
        Self.optionsPath, in: install.userProfile, followingLinks: true)
    else { return nil }
    let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
    return values?.isRegularFile == true ? url : nil
  }

  /// Prefers this app's record, then whatever the game last wrote, then the catalog defaults.
  package func load() throws(LauncherError) -> NFS2015Settings {
    if FileManager.default.fileExists(atPath: preferences.path) {
      do {
        let settings = try JSONDecoder().decode(
          NFS2015Settings.self, from: BoundedFile.read(preferences, limit: 65_536))
        try settings.validate()
        return settings
      } catch let error as LauncherError { throw error } catch {
        throw .operation("Could not read saved launcher settings: \(error.localizedDescription)")
      }
    }
    guard let url = try optionsFile() else { return NFS2015Settings() }
    let document = try ProfileOptionsDocument(
      text: try BoundedFile.text(url, limit: ProfileOptionsDocument.byteLimit))
    return NFS2015Settings(document: document)
  }

  /// Applies settings to the game's own options file and records them in this app's folder.
  ///
  /// The two files are journalled separately because only one of them is inside this app's
  /// folder. Each journal is replayed before the next operation reads either file.
  /// - Precondition: The caller holds the session lock and the game is not running.
  package func apply(_ settings: NFS2015Settings) throws(LauncherError) {
    try settings.validate()
    let edit = PlayerFileEdit(support: support)
    try edit.recover()
    if let url = try optionsFile() {
      let text = try settings.applying(
        to: try BoundedFile.text(url, limit: ProfileOptionsDocument.byteLimit))
      try edit.replace(url, with: Data(text.utf8))
    }
    do {
      try FileTransaction(root: support).apply([
        FileChange(url: preferences, bytes: try JSONEncoder().encode(settings))
      ])
    } catch let error as LauncherError {
      try edit.recover()
      throw error
    } catch {
      try edit.recover()
      throw .operation("Could not record launcher settings: \(error.localizedDescription)")
    }
  }
}
