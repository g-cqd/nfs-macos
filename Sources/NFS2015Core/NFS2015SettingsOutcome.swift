import Foundation

/// One line of the game's options file as a save changed it, read back after the write.
package struct NFS2015OptionLine: Codable, Equatable, Sendable {
  package let key: String
  package let before: String
  /// What the file holds now, read back from disk and not taken from the request.
  package let now: String

  package init(key: String, before: String, now: String) {
    self.key = key
    self.before = before
    self.now = now
  }
}

/// Which saved copy of the options file a restore used.
package enum NFS2015BackupKind: String, Codable, Sendable {
  /// The file as it was before this app first changed it.
  case original
  /// The file as it was before the latest change this app made.
  case previous
}

/// What the last settings request did, for the starter to show.
package enum NFS2015SettingsOutcome: Codable, Equatable, Sendable {
  /// The lines that now hold new values, as read back from the file.
  case saved([NFS2015OptionLine])
  /// The file already held every requested value; nothing was written.
  case unchanged
  /// The file was replaced by a saved copy; these lines now differ from before.
  case restored(NFS2015BackupKind, [NFS2015OptionLine])
  /// Nothing was written, for this reason.
  case refused(String)

  package var refusal: String? {
    if case .refused(let reason) = self { return reason }
    return nil
  }
}
