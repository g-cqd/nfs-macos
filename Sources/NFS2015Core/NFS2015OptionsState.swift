import CryptoKit
import Foundation

/// Which saved copies of the options file exist.
package struct NFS2015BackupState: Codable, Equatable, Sendable {
  package let original: Bool
  package let previous: Bool

  package init(original: Bool = false, previous: Bool = false) {
    self.original = original
    self.previous = previous
  }
}

/// What the game's options file holds right now, and whether this app may change it.
package struct NFS2015OptionsState: Equatable, Sendable {
  package var settings: NFS2015Settings
  /// Fingerprint of the file's bytes; nil until the game has written the file.
  package var digest: String?
  /// Why the file is shown but not editable, worded for the player; nil when it can be edited.
  package var problem: String?
  package var backups: NFS2015BackupState

  package init(
    settings: NFS2015Settings = NFS2015Settings(), digest: String? = nil, problem: String? = nil,
    backups: NFS2015BackupState = NFS2015BackupState()
  ) {
    self.settings = settings
    self.digest = digest
    self.problem = problem
    self.backups = backups
  }

  /// SHA-256 of a file's bytes as lowercase hexadecimal.
  package static func digest(of data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}
