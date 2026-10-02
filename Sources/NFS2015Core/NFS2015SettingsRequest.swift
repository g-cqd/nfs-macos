import Foundation
import LauncherCore

/// One change to the game's options file, as the starter asks the session helper to make it.
///
/// A request carries only what the player chose and the fingerprint of the file the player was
/// looking at. The helper refuses a request whose fingerprint no longer matches the file, so a
/// change the game made in the meantime is never overwritten with something older.
package struct NFS2015SettingsRequest: Codable, Equatable, Sendable {
  package enum Action: String, Codable, Sendable {
    /// Write `changes`, and nothing else.
    case save
    /// Put back the file as it was before this app first changed it.
    case restoreOriginal
    /// Put back the file as it was before the latest change this app made.
    case restorePrevious
  }

  package let action: Action
  /// Setting identifier to chosen value, only for the settings that differ from the file.
  package let changes: [String: String]
  /// SHA-256 of the options file the player saw, as lowercase hexadecimal.
  package let expectedDigest: String

  package init(action: Action, changes: [String: String] = [:], expectedDigest: String) {
    self.action = action
    self.changes = changes
    self.expectedDigest = expectedDigest
  }

  package func validate() throws(LauncherError) {
    guard expectedDigest.utf8.count == 64,
      expectedDigest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
    else {
      throw .operation("The request does not identify the options file it was made for.")
    }
    switch action {
    case .save:
      _ = try NFS2015Settings.replacements(for: changes)
    case .restoreOriginal, .restorePrevious:
      guard changes.isEmpty else {
        throw .operation("A restore request cannot also change settings.")
      }
    }
  }
}
