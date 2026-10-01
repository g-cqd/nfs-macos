import Foundation
import LauncherCore

/// Reads and writes the game's own options file, which is the only record of these settings.
///
/// The options file lives beside the player's saves, below the Windows user profile. The
/// installed game wrote `Documents/Need For Speed/settings/PROFILEOPTIONS_profile` with one
/// `Key Value` line per option; `PROFILEOPTIONS` beside it is a packed binary blob this app
/// never touches. A real Windows profile often links `Documents` at the player's own folder, so
/// that link is followed deliberately: these are the player's settings, in the player's place,
/// and the app changes nothing else there.
///
/// This app keeps no copy of its own. Every value is read back from the game's file and written
/// straight to it, so a change the player makes in the game's own Video menu is what the starter
/// shows, and the starter can never overwrite it with a stale cache.
package struct NFS2015SettingsStore {
  /// The options file, relative to the Windows user profile.
  package static let optionsPath = "Documents/Need For Speed/settings/PROFILEOPTIONS_profile"

  private let support: URL
  private let install: NFS2015Install?

  package init(support: URL, install: NFS2015Install?) {
    self.support = support
    self.install = install
  }

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

  /// Reads what the game last wrote; catalog defaults only when it has written nothing.
  package func load() throws(LauncherError) -> NFS2015Settings {
    guard let url = try optionsFile() else { return NFS2015Settings() }
    return NFS2015Settings(
      document: try ProfileOptionsDocument(
        text: try BoundedFile.text(url, limit: ProfileOptionsDocument.byteLimit)))
  }

  /// Writes the chosen values into the game's own options file and reads the result back.
  /// - Returns: The settings as the game's file now records them.
  /// - Precondition: The caller holds the session lock and the game is not running.
  /// - Throws: A failure that leaves the file exactly as it was.
  @discardableResult
  package func apply(_ settings: NFS2015Settings) throws(LauncherError) -> NFS2015Settings {
    try settings.validate()
    let edit = PlayerFileEdit(support: support)
    try edit.recover()
    guard let url = try optionsFile() else {
      throw .operation(
        """
        Start Need for Speed once and quit it, so it writes its own options file. This app \
        changes only the values you choose in a file the game already owns.
        """)
    }
    let text = try settings.applying(
      to: try BoundedFile.text(url, limit: ProfileOptionsDocument.byteLimit))
    try edit.replace(url, with: Data(text.utf8))
    return try load()
  }
}
