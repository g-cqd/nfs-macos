import Foundation
import LauncherCore

/// Whether the game's own `GamerProfile.xml` can be edited by the starter.
package enum FarCry2ProfileState: String, Codable, Sendable {
  /// The game has not written its profile yet; start it once, then settings become editable.
  case missing
  case ready
  /// The file exists but is not a layout the starter understands; it is never modified.
  case unrecognized
}

/// A validated configuration applied before play.
package struct FarCry2LaunchRequest: Codable, Equatable, Sendable {
  package let settings: FarCry2Settings
  package init(settings: FarCry2Settings) { self.settings = settings }
}

/// Last committed launcher state, published after preparation or session completion.
package struct FarCry2Snapshot: Codable, Equatable, Sendable {
  package let settings: FarCry2Settings
  package let profile: FarCry2ProfileState
  /// What the import recognised: build, version and store hints. Nil until a game is imported.
  package let installation: InstalledGame?
  package let backups: [FarCry2Backup]
  /// Folders from an earlier setup that conflicted with saved data and were kept in `Saves/FarCry2/Conflicts`.
  package let keptAside: Int
  package init(
    settings: FarCry2Settings, profile: FarCry2ProfileState, installation: InstalledGame?,
    backups: [FarCry2Backup], keptAside: Int = 0
  ) {
    self.settings = settings
    self.profile = profile
    self.installation = installation
    self.backups = backups
    self.keptAside = keptAside
  }
}
