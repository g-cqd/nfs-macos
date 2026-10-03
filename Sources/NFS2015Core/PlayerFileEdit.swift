import Foundation
import LauncherCore

/// Changes one file the player owns, outside this app's folder, recoverably.
///
/// `FileTransaction` deliberately refuses a target outside the player-data folder, and that
/// rule should stay. This app still has to edit exactly one file it does not own: the game's
/// own options file, which lives beside the player's saves. The journal that makes the edit
/// recoverable is kept inside this app's folder, records the file's absolute path and its
/// previous bytes, and is replayed before any later operation reads the file.
///
/// The file is replaced atomically: the new bytes are written beside it and renamed over it, so
/// a reader sees the old file or the new one and never a half-written one. The path handed in is
/// already resolved through any link on the way to it, so a linked player folder keeps its file;
/// a link at the file itself is refused.
package struct PlayerFileEdit {
  private struct Record: Codable {
    let path: String
    let bytes: Data?
  }

  /// The options file is a few hundred short lines; a larger file is not this file.
  static let byteLimit = ProfileOptionsDocument.byteLimit
  /// Writes bytes over an existing file. A different one can stand in under test.
  package typealias Writer = @Sendable (Data, URL) throws -> Void

  private let journal: URL
  private let files = FileManager.default

  package init(support: URL) {
    journal = support.appendingPathComponent("player-file-edit.json")
  }

  package static let atomicWrite: Writer = { bytes, url in
    try bytes.write(to: url, options: .atomic)
  }

  /// Restores an interrupted edit. Safe to call when no edit is outstanding.
  /// - Precondition: The caller holds the session lock and the game is not running.
  package func recover() throws(LauncherError) {
    guard files.fileExists(atPath: journal.path) else { return }
    do {
      let record = try JSONDecoder().decode(
        Record.self, from: BoundedFile.read(journal, limit: Self.byteLimit + 65_536))
      guard record.path.hasPrefix("/"), record.path.utf8.count <= 1024,
        record.bytes?.count ?? 0 <= Self.byteLimit
      else {
        throw LauncherError.operation("The recorded player-file edit is invalid.")
      }
      let url = URL(fileURLWithPath: record.path)
      if let bytes = record.bytes, files.fileExists(atPath: url.path) {
        try Self.atomicWrite(bytes, url)
      }
      try files.removeItem(at: journal)
    } catch let error as LauncherError { throw error } catch {
      throw .operation("Could not restore the game's options file: \(error.localizedDescription)")
    }
  }

  /// Replaces an existing regular file's contents, keeping a restorable copy of the originals.
  /// - Precondition: The caller holds the session lock and the game is not running.
  package func replace(
    _ url: URL, with bytes: Data, write: Writer = PlayerFileEdit.atomicWrite
  ) throws(LauncherError) {
    try recover()
    do {
      let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
      guard values.isRegularFile == true, values.isSymbolicLink != true,
        bytes.count <= Self.byteLimit
      else {
        throw LauncherError.operation("The game's options file is missing or unsupported.")
      }
      let original = try BoundedFile.read(url, limit: Self.byteLimit)
      guard original != bytes else { return }
      try JSONEncoder().encode(Record(path: url.path, bytes: original)).write(
        to: journal, options: .atomic)
      do {
        try write(bytes, url)
        try files.removeItem(at: journal)
      } catch {
        let failure = error.localizedDescription
        try recover()
        throw LauncherError.operation("The options change was rolled back: \(failure)")
      }
    } catch let error as LauncherError { throw error } catch {
      throw .operation("Could not change the game's options file: \(error.localizedDescription)")
    }
  }
}
