import Foundation
import LauncherCore

/// What the starter shows after a session operation: the settings and the dependency state.
package struct NFS2015Snapshot: Codable, Equatable, Sendable {
  /// Why the game cannot be started yet, already worded for the player; nil when it can.
  package var blocker: String?
  /// The EA client version found in the referenced Windows folder, for the About panel.
  package var clientVersion: String?
  /// The referenced Windows folder, so the starter can show what it is running.
  package var installedAt: String?
  /// Whether the game's own options file exists yet; settings cannot be changed before it does.
  package var hasOptionsFile: Bool
  package var settings: NFS2015Settings
  /// Fingerprint of the options file the settings were read from. A request to change it must
  /// quote this, so a change the game made since is detected rather than overwritten.
  package var optionsDigest: String?
  /// Why the options file is shown but cannot be edited, worded for the player; nil when it can.
  package var optionsProblem: String?
  /// Which saved copies of the options file exist, for the restore buttons.
  package var backups: NFS2015BackupState?
  /// What the last settings request did; nil for any other operation.
  package var outcome: NFS2015SettingsOutcome?
  /// Set when this app created its own Windows folder and carries the game in it, so the
  /// starter offers to install the EA app and sign in instead of choosing a folder.
  package var ownsWindowsFolder: Bool?
  /// The next step in an owned Windows folder; nil once the EA app is installed and signed in.
  package var setup: NFS2015Setup?
  /// What the last Play ended with when it did not start the game and nothing is wrong: the EA
  /// app is running and needs the player, or has not finished starting.
  package var notice: String?

  package init(
    blocker: String? = nil, clientVersion: String? = nil, installedAt: String? = nil,
    hasOptionsFile: Bool = false, settings: NFS2015Settings = NFS2015Settings(),
    optionsDigest: String? = nil, optionsProblem: String? = nil,
    backups: NFS2015BackupState? = nil, outcome: NFS2015SettingsOutcome? = nil,
    ownsWindowsFolder: Bool? = nil, setup: NFS2015Setup? = nil, notice: String? = nil
  ) {
    self.blocker = blocker
    self.clientVersion = clientVersion
    self.installedAt = installedAt
    self.hasOptionsFile = hasOptionsFile
    self.settings = settings
    self.optionsDigest = optionsDigest
    self.optionsProblem = optionsProblem
    self.backups = backups
    self.outcome = outcome
    self.ownsWindowsFolder = ownsWindowsFolder
    self.setup = setup
    self.notice = notice
  }

  package static func read(from url: URL) throws(LauncherError) -> Self {
    do {
      let snapshot = try JSONDecoder().decode(
        Self.self, from: BoundedFile.read(url, limit: 262_144))
      try snapshot.settings.validate()
      return snapshot
    } catch let error as LauncherError { throw error } catch {
      throw .operation("Could not read the launcher state: \(error.localizedDescription)")
    }
  }

  package func write(to url: URL) throws(LauncherError) {
    do { try JSONEncoder().encode(self).write(to: url, options: .atomic) } catch {
      throw .operation("Could not record the launcher state: \(error.localizedDescription)")
    }
  }
}
